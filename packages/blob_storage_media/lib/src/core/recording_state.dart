import 'package:meta/meta.dart';

import 'audio_format.dart';
import 'blob_metadata.dart';

/// Where one recording is in its single-use lifecycle:
/// idle → active → finished | cancelled | failed.
@immutable
sealed class RecordingState {
  const RecordingState();
}

final class RecordingIdle extends RecordingState {
  const RecordingIdle();
}

final class RecordingActive extends RecordingState {
  const RecordingActive({required this.startedAt, required this.format});

  final DateTime startedAt;
  final AudioFormat format;
}

final class RecordingFinished extends RecordingState {
  const RecordingFinished(this.metadata);

  final BlobMetadata metadata;
}

/// The user discarded the take; no ciphertext was kept.
final class RecordingCancelled extends RecordingState {
  const RecordingCancelled();
}

/// The microphone or the store failed; no ciphertext was kept.
final class RecordingFailed extends RecordingState {
  const RecordingFailed(this.error);

  final Object error;
}
