import 'dart:async';
import 'dart:js_interop';
import 'dart:math';
import 'dart:typed_data';

import 'package:blob_storage_media/blob_storage_media.dart';

import '../ogg_opus_demuxer.dart';
import '../ogg_opus_muxer.dart';
import '../streaming_audio_capture.dart';
import 'webcodecs.dart';

const _sampleRate = 48000;
const _codec = 'opus';

/// [AudioStreamEncoder] on the browser's WebCodecs `AudioEncoder`: 48 kHz
/// mono PCM16 in, Ogg Opus out through our own [OggOpusMuxer], so a take
/// recorded in the browser is the same kind of file a phone records and
/// plays on every device of the vault.
///
/// The PCM never leaves memory: the encoder works on buffers and the pages
/// it yields are sealed by the blob storage as they come.
final class WebCodecsOpusEncoder implements AudioStreamEncoder {
  WebCodecsOpusEncoder({this.bitrate = 32000, Random? random})
    : _random = random ?? Random.secure();

  /// The same bitrate as the phones: about 14 MB per hour of speech.
  final int bitrate;
  final Random _random;

  /// More silence than any encoder lookahead (80 ms, the largest pre-skip
  /// RFC 7845 suggests), so the last real samples are always encoded. The
  /// final granule trims it away again.
  static const _tailSamples = 3840;

  static const _frameMicroseconds = 20000;

  /// Whether this browser can encode Opus as we configure it.
  static Future<bool> isSupported() async {
    if (!hasWebCodecsAudio) return false;
    try {
      final support = await JSAudioEncoder.isConfigSupported(_config(32000))
          .toDart;
      return support.supported;
    } on Object {
      return false;
    }
  }

  @override
  AudioFormat get format => AudioFormat.opusOgg;

  @override
  Stream<Uint8List> encode(Stream<Uint8List> pcm) {
    late final StreamController<Uint8List> pages;
    var cancelled = false;
    pages = StreamController<Uint8List>(
      onListen: () => _run(pcm, pages, () => cancelled),
      onCancel: () => cancelled = true,
    );
    return pages.stream;
  }

  Future<void> _run(
    Stream<Uint8List> pcm,
    StreamController<Uint8List> pages,
    bool Function() cancelled,
  ) async {
    OggOpusMuxer? muxer;
    Object? failure;
    var encodedSamples = 0;
    var preSkip = 0;

    OggOpusMuxer open(int lookahead) {
      preSkip = lookahead;
      final opened = OggOpusMuxer(
        serial: _random.nextInt(0x100000000),
        channels: 1,
        preSkip: lookahead,
        inputSampleRate: _sampleRate,
      );
      pages.add(opened.header());
      return opened;
    }

    final encoder = JSAudioEncoder(
      JSAudioEncoderInit(
        output:
            ((JSEncodedAudioChunk chunk, JSEncodedAudioChunkMetadata? meta) {
              if (failure != null) return;
              try {
                final muxing = muxer ??= open(_preSkipOf(meta));
                // A JS buffer for the browser to fill: under WebAssembly a
                // Dart list passed with `toJS` would be filled as a copy.
                final buffer = JSUint8Array.withLength(chunk.byteLength);
                chunk.copyTo(buffer);
                final packet = buffer.toDart;
                final samples =
                    (chunk.duration ?? _frameMicroseconds) *
                    _sampleRate ~/
                    Duration.microsecondsPerSecond;
                encodedSamples += samples;
                if (muxing.addPacket(packet, samples: samples)
                    case final page?) {
                  pages.add(page);
                }
              } on Object catch (error) {
                failure = error;
              }
            }).toJS,
        error: ((JSObject _) {
          failure ??= StateError('WebCodecs Opus encoder failed');
        }).toJS,
      ),
    );
    final samples = _SampleFeeder(encoder);
    try {
      encoder.configure(_config(bitrate));
      await for (final piece in pcm) {
        if (cancelled()) break;
        samples.add(piece);
        if (failure != null) throw failure!;
      }
      final original = samples.total;
      if (original > 0) samples.addSilence(_tailSamples);
      await encoder.flush().toDart;
      if (failure != null) throw failure!;
      if (cancelled()) return;
      final muxing = muxer ??= open(0);
      if (original > 0 && encodedSamples < original + preSkip) {
        throw StateError('WebCodecs Opus encoder dropped audio');
      }
      pages.add(muxing.finish(originalSamples: original));
    } on Object catch (error, stack) {
      if (!cancelled()) pages.addError(error, stack);
    } finally {
      samples.wipe();
      if (encoder.state != 'closed') encoder.close();
      await pages.close();
    }
  }

  static JSAudioEncoderConfig _config(int bitrate) => JSAudioEncoderConfig(
    codec: _codec,
    sampleRate: _sampleRate,
    numberOfChannels: 1,
    bitrate: bitrate,
    opus: JSOpusEncoderConfig(
      frameDuration: _frameMicroseconds,
      application: 'voip',
      signal: 'voice',
    ),
  );

  /// The pre-skip from the OpusHead the browser hands out with its first
  /// packet. Chrome includes it; without one, nothing is skipped, which
  /// keeps every real sample at the cost of a few milliseconds of lead-in.
  static int _preSkipOf(JSEncodedAudioChunkMetadata? meta) {
    final description = meta?.decoderConfig?.description;
    if (description == null) return 0;
    final head = JSBytesOf(description).toDart;
    if (head.length < 19 || String.fromCharCodes(head, 0, 8) != 'OpusHead') {
      return 0;
    }
    return ByteData.sublistView(head).getUint16(10, Endian.little);
  }
}

/// Hands PCM16 bytes to the encoder as whole samples, carrying a byte
/// split between two pieces over to the next one.
final class _SampleFeeder {
  _SampleFeeder(this._encoder);

  final JSAudioEncoder _encoder;
  final _carry = Uint8List(1);
  var _carried = false;

  /// Samples handed over so far; their timestamps follow from it.
  var total = 0;

  void add(Uint8List piece) {
    if (piece.isEmpty) return;
    final bytes = Uint8List((_carried ? 1 : 0) + piece.length);
    if (_carried) bytes[0] = _carry[0];
    bytes.setAll(_carried ? 1 : 0, piece);
    final whole = bytes.length & ~1;
    _carried = whole != bytes.length;
    if (_carried) _carry[0] = bytes.last;
    // PCM16 is little-endian, like every platform Flutter runs on, and a
    // fresh buffer starts aligned for 16-bit access.
    if (whole > 0) _send(Int16List.view(bytes.buffer, 0, whole ~/ 2));
    bytes.fillRange(0, bytes.length, 0);
  }

  void addSilence(int count) => _send(Int16List(count));

  void wipe() => _carry[0] = 0;

  void _send(Int16List samples) {
    final data = JSAudioData(
      JSAudioDataInit(
        format: 's16',
        sampleRate: _sampleRate,
        numberOfFrames: samples.length,
        numberOfChannels: 1,
        timestamp: total * Duration.microsecondsPerSecond ~/ _sampleRate,
        data: samples.toJS,
      ),
    );
    total += samples.length;
    try {
      _encoder.encode(data);
    } finally {
      data.close();
    }
  }
}

/// [AudioDecoder] for Ogg Opus on the browser's WebCodecs `AudioDecoder`.
///
/// The container is parsed and its length capped by our own strict
/// [OggOpusDemuxer] before the browser sees a packet; pre-skip and final
/// granule are applied here, as the libopus decoder does on the phones.
final class WebCodecsOpusDecoder implements AudioDecoder {
  const WebCodecsOpusDecoder({this.demuxer = const OggOpusDemuxer()});

  final OggOpusDemuxer demuxer;

  /// Packets waiting in the browser's queue before we wait for it.
  static const _queueLimit = 64;

  static Future<bool> isSupported() async {
    if (!hasWebCodecsAudio) return false;
    try {
      final support = await JSAudioDecoder.isConfigSupported(
        JSAudioDecoderConfig(
          codec: _codec,
          sampleRate: _sampleRate,
          numberOfChannels: 1,
        ),
      ).toDart;
      return support.supported;
    } on Object {
      return false;
    }
  }

  @override
  bool canDecode(AudioFormat format) => format == AudioFormat.opusOgg;

  @override
  Future<DecodedAudio> decode(Stream<Uint8List> encoded) async {
    final recording = await demuxer.read(encoded);
    if (recording.finalGranule - recording.preSkip >
        DecodedAudio.maxSamplesAt(_sampleRate)) {
      throw const RecordingTooLongException();
    }
    if (recording.packets.isEmpty) {
      return DecodedAudio(samples: Int16List(0), sampleRate: _sampleRate);
    }
    final wanted = recording.finalGranule;
    final decoded = Int16List(wanted);
    var filled = 0;
    var failed = false;
    Completer<void>? dequeued;

    final decoder = JSAudioDecoder(
      JSAudioDecoderInit(
        output: ((JSAudioData frame) {
          try {
            if (failed || filled == wanted) return;
            if (frame.numberOfChannels < 1) {
              failed = true;
              return;
            }
            final options = JSAudioDataCopyToOptions(
              planeIndex: 0,
              format: 'f32-planar',
            );
            final buffer = JSFloat32Array.withLength(frame.numberOfFrames);
            frame.copyTo(buffer, options);
            final floats = buffer.toDart;
            final take = min(floats.length, wanted - filled);
            for (var i = 0; i < take; i++) {
              decoded[filled + i] = (floats[i].clamp(-1.0, 1.0) * 32767)
                  .round();
            }
            filled += take;
          } on Object {
            failed = true;
          } finally {
            frame.close();
          }
        }).toJS,
        error: ((JSObject _) {
          failed = true;
          dequeued?.complete();
        }).toJS,
      ),
    );
    decoder.ondequeue = (() {
      final waiting = dequeued;
      dequeued = null;
      waiting?.complete();
    }).toJS;
    try {
      decoder.configure(
        JSAudioDecoderConfig(
          codec: _codec,
          sampleRate: _sampleRate,
          numberOfChannels: recording.channels,
        ),
      );
      var timestamp = 0;
      for (final packet in recording.packets) {
        if (failed || filled == wanted) break;
        while (decoder.decodeQueueSize >= _queueLimit && !failed) {
          await (dequeued ??= Completer<void>()).future;
        }
        if (failed) break;
        decoder.decode(
          JSEncodedAudioChunk(
            JSEncodedAudioChunkInit(
              type: 'key',
              timestamp: timestamp,
              data: packet.toJS,
            ),
          ),
        );
        // Only orders the chunks; the browser decodes each packet whole.
        timestamp += 20000;
      }
      if (!failed) await decoder.flush().toDart;
    } on Object {
      failed = true;
    } finally {
      if (decoder.state != 'closed') decoder.close();
    }
    if (failed) throw const MalformedBlobException('not an Opus packet');
    if (filled < wanted) {
      throw const MalformedBlobException(
        'Opus stream shorter than its granule',
      );
    }
    return DecodedAudio(
      samples: Int16List.sublistView(decoded, recording.preSkip),
      sampleRate: _sampleRate,
    );
  }
}
