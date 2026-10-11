import 'dart:typed_data';

import 'package:blob_storage_media/blob_storage_media.dart';

import 'streaming_audio_capture.dart';

/// [AudioDecoder] for the 16-bit mono WAV the web recorder writes
/// ([WavStreamEncoder], length unknown) and for canonical WAV with its
/// real length. Nothing else: no extra chunks, no other sample formats.
final class WavAudioDecoder implements AudioDecoder {
  const WavAudioDecoder();

  static const _unknown = 0xFFFFFFFF;

  @override
  bool canDecode(AudioFormat format) => format == AudioFormat.pcm16Wav;

  @override
  Future<DecodedAudio> decode(Stream<Uint8List> encoded) async {
    final buffer = BytesBuilder(copy: false);
    int? rate;
    var maxBytes = WavStreamEncoder.headerBytes;
    await for (final piece in encoded) {
      buffer.add(piece);
      if (rate == null && buffer.length >= WavStreamEncoder.headerBytes) {
        rate = _sampleRate(buffer.toBytes());
        maxBytes += DecodedAudio.maxSamplesAt(rate) * 2 + 1;
      }
      if (rate != null && buffer.length > maxBytes) {
        throw const RecordingTooLongException();
      }
    }
    final bytes = buffer.takeBytes();
    if (rate == null) throw const MalformedBlobException('WAV truncated');

    final header = ByteData.sublistView(bytes);
    final riffSize = header.getUint32(4, Endian.little);
    final dataSize = header.getUint32(40, Endian.little);
    final body = bytes.length - WavStreamEncoder.headerBytes;
    final int sampleBytes;
    if (riffSize == _unknown && dataSize == _unknown) {
      // A stream that ends mid-sample loses the half sample, as the Opus
      // encoder does.
      sampleBytes = body - body % 2;
    } else if (dataSize == body && dataSize.isEven && riffSize == 36 + body) {
      sampleBytes = body;
    } else {
      throw const MalformedBlobException('WAV length mismatch');
    }

    final samples = Int16List(sampleBytes ~/ 2);
    final data = ByteData.sublistView(bytes, WavStreamEncoder.headerBytes);
    for (var i = 0; i < samples.length; i++) {
      samples[i] = data.getInt16(i * 2, Endian.little);
    }
    return DecodedAudio(samples: samples, sampleRate: rate);
  }

  /// Checks the fixed part of the header and returns its sample rate.
  static int _sampleRate(Uint8List bytes) {
    final header = ByteData.sublistView(bytes);
    bool tag(int offset, String text) {
      for (var i = 0; i < text.length; i++) {
        if (bytes[offset + i] != text.codeUnitAt(i)) return false;
      }
      return true;
    }

    final rate = header.getUint32(24, Endian.little);
    if (!tag(0, 'RIFF') ||
        !tag(8, 'WAVEfmt ') ||
        !tag(36, 'data') ||
        header.getUint32(16, Endian.little) != 16 ||
        header.getUint16(20, Endian.little) != 1 ||
        header.getUint16(22, Endian.little) != 1 ||
        rate < DecodedAudio.minSampleRate ||
        rate > DecodedAudio.maxSampleRate ||
        header.getUint32(28, Endian.little) != rate * 2 ||
        header.getUint16(32, Endian.little) != 2 ||
        header.getUint16(34, Endian.little) != 16) {
      throw const MalformedBlobException('not 16-bit mono PCM WAV');
    }
    return rate;
  }
}
