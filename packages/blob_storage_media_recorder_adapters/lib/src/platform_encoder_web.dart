import 'package:blob_storage_media_adapters/audio_encoding.dart';

/// Uncompressed until the WebCodecs Opus encoder lands (Fase 7): browsers
/// cannot load the FFI build of libopus.
AudioStreamEncoder platformEncoder() =>
    const WavStreamEncoder(sampleRate: 48000);
