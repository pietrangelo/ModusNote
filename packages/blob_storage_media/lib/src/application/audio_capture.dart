import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../core/audio_format.dart';

/// Port: the microphone, delivering encoded audio as an in-memory stream.
///
/// Deliberately no file path anywhere: adapters hand over buffers as they
/// are encoded, so no platform ever has an unencrypted recording on disk.
abstract interface class AudioCapture {
  /// Requests permission and starts capturing. Throws
  /// `MicrophonePermissionDeniedException` if access is refused.
  Future<CapturedAudio> start();

  /// Stops capturing; [CapturedAudio.bytes] closes after its last buffer.
  Future<void> stop();
}

@immutable
final class CapturedAudio {
  const CapturedAudio({required this.format, required this.bytes});

  /// What the platform actually negotiated (e.g. AAC on Safari).
  final AudioFormat format;
  final Stream<Uint8List> bytes;
}
