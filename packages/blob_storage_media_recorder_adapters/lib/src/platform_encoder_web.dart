import 'package:blob_storage_media_adapters/audio_encoding.dart';

/// Streaming WAV: works in every browser. The web app picks Opus through
/// WebCodecs itself when the browser has it (`lib/bootstrap/home_web.dart`),
/// because finding out is asynchronous.
AudioStreamEncoder platformEncoder() =>
    const WavStreamEncoder(sampleRate: 48000);
