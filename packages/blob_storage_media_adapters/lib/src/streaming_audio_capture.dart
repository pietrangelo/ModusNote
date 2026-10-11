import 'dart:typed_data';

import 'package:blob_storage_media/blob_storage_media.dart';

/// The platform microphone, reduced to what capture needs: permission and
/// a stream of 16-bit little-endian PCM. The Flutter `record` binding
/// implements it; keeping it this small leaves the logic testable here.
abstract interface class PcmMicrophone {
  Future<bool> requestPermission();

  Future<Stream<Uint8List>> start({
    required int sampleRate,
    required int channels,
  });

  /// Stops recording; the PCM stream closes after its last buffer.
  Future<void> stop();
}

/// Turns PCM into the bytes of one audio file, incrementally.
abstract interface class AudioStreamEncoder {
  AudioFormat get format;

  /// Closes after [pcm] closes and the encoder has flushed its tail.
  Stream<Uint8List> encode(Stream<Uint8List> pcm);
}

/// [AudioCapture] that pipes a [PcmMicrophone] through an
/// [AudioStreamEncoder], entirely in memory: no platform writes a file.
final class StreamingAudioCapture implements AudioCapture {
  StreamingAudioCapture({
    required this._microphone,
    required this._encoder,
    this.sampleRate = 48000,
  });

  /// Opus works natively at 48 kHz; other encoders accept it as well.
  final int sampleRate;

  final PcmMicrophone _microphone;
  final AudioStreamEncoder _encoder;

  static const _channels = 1;

  @override
  Future<CapturedAudio> start() async {
    if (!await _microphone.requestPermission()) {
      throw const MicrophonePermissionDeniedException();
    }
    final pcm = await _microphone.start(
      sampleRate: sampleRate,
      channels: _channels,
    );
    return CapturedAudio(format: _encoder.format, bytes: _encoder.encode(pcm));
  }

  @override
  Future<void> stop() => _microphone.stop();
}

/// Uncompressed fallback for platforms without an Opus encoder: a
/// streaming WAV whose header leaves the length unknown (0xFFFFFFFF), as
/// it cannot be known until the take ends and nothing is ever rewritten.
final class WavStreamEncoder implements AudioStreamEncoder {
  const WavStreamEncoder({required this.sampleRate});

  static const headerBytes = 44;

  final int sampleRate;

  @override
  AudioFormat get format => AudioFormat.pcm16Wav;

  @override
  Stream<Uint8List> encode(Stream<Uint8List> pcm) async* {
    yield _header();
    yield* pcm;
  }

  Uint8List _header() {
    const unknown = 0xFFFFFFFF;
    const bytesPerSample = 2;
    final header = Uint8List(headerBytes);
    final view = ByteData.sublistView(header);
    header
      ..setAll(0, 'RIFF'.codeUnits)
      ..setAll(8, 'WAVEfmt '.codeUnits)
      ..setAll(36, 'data'.codeUnits);
    view
      ..setUint32(4, unknown, Endian.little)
      ..setUint32(16, 16, Endian.little)
      ..setUint16(20, 1, Endian.little)
      ..setUint16(22, 1, Endian.little)
      ..setUint32(24, sampleRate, Endian.little)
      ..setUint32(28, sampleRate * bytesPerSample, Endian.little)
      ..setUint16(32, bytesPerSample, Endian.little)
      ..setUint16(34, 16, Endian.little)
      ..setUint32(40, unknown, Endian.little);
    return header;
  }
}
