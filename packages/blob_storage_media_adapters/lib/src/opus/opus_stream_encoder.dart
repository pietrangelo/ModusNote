import 'dart:ffi';
import 'dart:math';
import 'dart:typed_data';

import 'package:blob_storage_media/blob_storage_media.dart';
import 'package:ffi/ffi.dart';

import '../ogg_opus_muxer.dart';
import '../streaming_audio_capture.dart';
import 'opus_bindings.dart';

/// [AudioStreamEncoder] on libopus: 48 kHz mono PCM16 in, Ogg Opus out,
/// one 20 ms packet at a time.
final class OpusStreamEncoder implements AudioStreamEncoder {
  OpusStreamEncoder({this.bitrate = 32000, Random? random})
    : _random = random ?? Random.secure();

  /// 32 kbit/s is transparent for speech and fine for a guide track,
  /// about 14 MB per hour.
  final int bitrate;
  final Random _random;

  static const sampleRate = 48000;
  static const frameSamples = 960;
  static const _frameBytes = frameSamples * 2;

  /// libopus's own recommendation for the output buffer of one packet.
  static const _maxPacketBytes = 4000;

  @override
  AudioFormat get format => AudioFormat.opusOgg;

  @override
  Stream<Uint8List> encode(Stream<Uint8List> pcm) async* {
    final error = calloc<Int>();
    final lookahead = calloc<Int32>();
    final input = calloc<Int16>(frameSamples);
    final output = calloc<Uint8>(_maxPacketBytes);
    final encoder = opusEncoderCreate(
      sampleRate,
      1,
      opusApplicationVoip,
      error,
    );
    try {
      _check(error.value, 'opus_encoder_create');
      _check(modusnoteOpusSetBitrate(encoder, bitrate), 'set bitrate');
      _check(modusnoteOpusSetSignalVoice(encoder), 'set signal');
      _check(modusnoteOpusGetLookahead(encoder, lookahead), 'lookahead');
      final preSkip = lookahead.value;
      final muxer = OggOpusMuxer(
        serial: _random.nextInt(1 << 32),
        channels: 1,
        preSkip: preSkip,
        inputSampleRate: sampleRate,
      );
      final frame = Uint8List(_frameBytes);
      var filled = 0;
      var totalBytes = 0;
      var encodedSamples = 0;

      Uint8List? encodeFrame() {
        input
            .asTypedList(frameSamples)
            .setAll(0, Int16List.view(frame.buffer, 0, frameSamples));
        final length = opusEncode(
          encoder,
          input,
          frameSamples,
          output,
          _maxPacketBytes,
        );
        _check(length < 0 ? length : opusOk, 'opus_encode');
        encodedSamples += frameSamples;
        return muxer.addPacket(
          Uint8List.fromList(output.asTypedList(length)),
          samples: frameSamples,
        );
      }

      yield muxer.header();
      await for (final piece in pcm) {
        totalBytes += piece.length;
        var offset = 0;
        while (offset < piece.length) {
          final take = min(_frameBytes - filled, piece.length - offset);
          frame.setRange(filled, filled + take, piece, offset);
          filled += take;
          offset += take;
          if (filled == _frameBytes) {
            if (encodeFrame() case final page?) yield page;
            filled = 0;
          }
        }
      }

      // A trailing odd byte is half a sample: it cannot be audio.
      final originalSamples = totalBytes ~/ 2;
      if (originalSamples > 0) {
        // Pad with silence until the decoder has emitted every real sample
        // past the encoder's lookahead; the final granule trims it again.
        frame.fillRange(filled - filled % 2, _frameBytes, 0);
        while (encodedSamples < originalSamples + preSkip) {
          if (encodeFrame() case final page?) yield page;
          frame.fillRange(0, _frameBytes, 0);
        }
      }
      yield muxer.finish(originalSamples: originalSamples);
    } finally {
      if (encoder != nullptr) opusEncoderDestroy(encoder);
      input.asTypedList(frameSamples).fillRange(0, frameSamples, 0);
      calloc
        ..free(error)
        ..free(lookahead)
        ..free(input)
        ..free(output);
    }
  }
}

/// Decodes single Opus packets to 48 kHz mono PCM, for playback and for
/// checking what the encoder produced.
final class OpusPacketDecoder {
  OpusPacketDecoder() {
    final error = calloc<Int>();
    try {
      _decoder = opusDecoderCreate(OpusStreamEncoder.sampleRate, 1, error);
      _check(error.value, 'opus_decoder_create');
    } finally {
      calloc.free(error);
    }
  }

  /// 120 ms, the longest frame Opus allows.
  static const _maxFrameSamples = 5760;

  late final Pointer<OpusDecoderHandle> _decoder;
  final _input = calloc<Uint8>(OggOpusMuxer.maxPacketBytes);
  final _output = calloc<Int16>(_maxFrameSamples);
  var _disposed = false;

  /// Throws [FormatException] for anything that is not a valid packet.
  Int16List decode(Uint8List packet) {
    if (_disposed) throw StateError('decoder disposed');
    if (packet.isEmpty || packet.length > OggOpusMuxer.maxPacketBytes) {
      throw const FormatException('not an Opus packet');
    }
    _input.asTypedList(packet.length).setAll(0, packet);
    final samples = opusDecode(
      _decoder,
      _input,
      packet.length,
      _output,
      _maxFrameSamples,
      0,
    );
    if (samples < 0) throw const FormatException('not an Opus packet');
    return Int16List.fromList(_output.asTypedList(samples));
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    opusDecoderDestroy(_decoder);
    calloc
      ..free(_input)
      ..free(_output);
  }
}

void _check(int status, String operation) {
  if (status != opusOk) throw StateError('$operation failed ($status)');
}
