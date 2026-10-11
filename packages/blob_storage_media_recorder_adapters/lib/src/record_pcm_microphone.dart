import 'dart:typed_data';

import 'package:blob_storage_media_adapters/audio_encoding.dart';
import 'package:record/record.dart';

/// [PcmMicrophone] on the `record` plugin, in streaming mode only: the
/// plugin hands over PCM buffers and never writes a recording file.
final class RecordPcmMicrophone implements PcmMicrophone {
  AudioRecorder? _recorder;

  @override
  Future<bool> requestPermission() async {
    final recorder = _recorder ??= AudioRecorder();
    return recorder.hasPermission();
  }

  @override
  Future<Stream<Uint8List>> start({
    required int sampleRate,
    required int channels,
  }) {
    final recorder = _recorder ??= AudioRecorder();
    return recorder.startStream(
      RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: sampleRate,
        numChannels: channels,
      ),
    );
  }

  @override
  Future<void> stop() async {
    final recorder = _recorder;
    if (recorder == null) return;
    _recorder = null;
    await recorder.stop();
    await recorder.dispose();
  }
}
