/// Microphone adapter for the Blob Storage & Media bounded context.
library;

import 'package:blob_storage_media/blob_storage_media.dart';
import 'package:blob_storage_media_adapters/audio_encoding.dart';

import 'src/platform_encoder_stub.dart'
    if (dart.library.ffi) 'src/platform_encoder_native.dart'
    if (dart.library.js_interop) 'src/platform_encoder_web.dart';
import 'src/record_pcm_microphone.dart';

export 'src/record_pcm_microphone.dart';

/// The [AudioCapture] for the running platform: Ogg Opus via libopus on
/// Android and iOS, streaming WAV in the browser (see `platformEncoder`).
AudioCapture createPlatformAudioCapture() => StreamingAudioCapture(
  microphone: RecordPcmMicrophone(),
  encoder: platformEncoder(),
);
