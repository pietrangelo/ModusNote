import 'dart:math';

import 'package:blob_storage_media/blob_storage_media.dart';
import 'package:collaboration_access_control/collaboration_access_control.dart';
import 'package:offline_sync/offline_sync.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

/// Records takes for the audio fields of notes, straight from the
/// microphone into blobs sealed under the vault's current GroupKey.
final class NoteRecorder {
  NoteRecorder({
    required this._capture,
    required this.blobs,
    required this._engine,
    this._clock = DateTime.now,
    Random? random,
  }) : _random = random ?? Random.secure();

  final AudioCapture Function() _capture;
  final SyncEngine _engine;
  final DateTime Function() _clock;
  final Random _random;

  /// Where takes land; also used to delete takes nobody kept.
  final EncryptedBlobStorage blobs;

  /// Throws [MicrophonePermissionDeniedException] when access is refused.
  Future<RecordingTake> start() async {
    final epoch = _engine.currentEpoch;
    final session = AudioRecordingSession(
      capture: _capture(),
      storage: blobs,
      clock: _clock,
    );
    await session.start(
      id: _newBlobId(),
      contentKey: _engine.contentKeyFor(epoch),
    );
    return RecordingTake._(session, epoch)..limit;
  }

  /// Opaque and random, like note ids: blob ids reach R2 in clear.
  BlobId _newBlobId() => BlobId(
    List.generate(
      16,
      (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join(),
  );
}

/// One take in progress.
final class RecordingTake {
  RecordingTake._(this._session, this._epoch);

  final AudioRecordingSession _session;
  final KeyEpoch _epoch;

  DateTime get startedAt => switch (_session.state) {
    RecordingActive(:final startedAt) => startedAt,
    _ => throw StateError('take is not recording'),
  };

  /// When the take stops by itself: see [AudioFormat.longestTake].
  late final Duration limit = switch (_session.state) {
    RecordingActive(:final format) => format.longestTake,
    _ => throw StateError('take is not recording'),
  };

  Future<KeyedRecording> stop() async =>
      KeyedRecording(epoch: _epoch, metadata: await _session.stop());

  /// Nothing of the take is kept.
  Future<void> cancel() => _session.cancel();
}
