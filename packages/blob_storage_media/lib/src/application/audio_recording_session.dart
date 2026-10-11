import 'dart:async';
import 'dart:typed_data';

import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import '../core/blob_metadata.dart';
import '../core/recording_state.dart';
import 'audio_capture.dart';
import 'encrypted_blob_storage.dart';

/// Use case: one take from the microphone to an encrypted blob.
///
/// Audio flows from [AudioCapture] straight into [EncryptedBlobStorage],
/// chunk by chunk, so the recording is encrypted while it is being made.
/// Cancelling or any failure aborts the write: nothing partial is kept.
final class AudioRecordingSession {
  AudioRecordingSession({
    required this._capture,
    required this._storage,
    required this._clock,
  });

  final AudioCapture _capture;
  final EncryptedBlobStorage _storage;
  final DateTime Function() _clock;

  RecordingState _state = const RecordingIdle();
  bool _transitioning = false;
  StreamController<Uint8List>? _audio;
  StreamSubscription<Uint8List>? _microphone;
  Future<SealedBlob>? _write;

  RecordingState get state => _state;

  /// [contentKey] stays owned by the caller and must outlive the session.
  Future<void> start({required BlobId id, required SymmetricKey contentKey}) =>
      _transition<RecordingIdle, void>(() async {
        final CapturedAudio captured;
        try {
          captured = await _capture.start();
        } catch (error) {
          _state = RecordingFailed(error);
          rethrow;
        }
        final audio = _audio = StreamController<Uint8List>();
        _microphone = captured.bytes.listen(
          audio.add,
          onError: audio.addError,
          onDone: audio.close,
        );
        final write = _write = _storage.write(
          audio.stream,
          id: id,
          contentKey: contentKey,
        );
        // Observed later by stop() or cancel(); this only keeps an early
        // failure from surfacing as an unhandled error in the meantime.
        write.ignore();
        _state = RecordingActive(
          startedAt: _clock().toUtc(),
          format: captured.format,
        );
      });

  Future<BlobMetadata> stop() =>
      _transition<RecordingActive, BlobMetadata>(() async {
        final active = _state as RecordingActive;
        try {
          await _capture.stop();
          final blob = await _write!;
          final metadata = BlobMetadata(
            blob: blob,
            format: active.format,
            duration: _clock().toUtc().difference(active.startedAt),
            recordedAt: active.startedAt,
          );
          _state = RecordingFinished(metadata);
          return metadata;
        } catch (error) {
          _state = RecordingFailed(error);
          rethrow;
        }
      });

  Future<void> cancel() => _transition<RecordingActive, void>(() async {
    await _microphone!.cancel();
    final audio = _audio!;
    if (!audio.isClosed) {
      audio.addError(const _Cancelled());
      await audio.close();
    }
    await _capture.stop();
    SealedBlob? committed;
    try {
      committed = await _write!;
    } on Object {
      // Aborted, which is the point of cancelling: nothing was kept.
    }
    // The microphone may have ended on its own before the cancel arrived,
    // so the take was already committed; discarding it is the user's call.
    if (committed != null) await _storage.delete(committed.id);
    _state = const RecordingCancelled();
  });

  /// Serialises transitions: a second call while one is in flight, or from
  /// the wrong state, is a programming error rather than a race.
  Future<R> _transition<S extends RecordingState, R>(
    Future<R> Function() body,
  ) async {
    if (_transitioning || _state is! S) {
      throw StateError('cannot do that while ${_state.runtimeType}');
    }
    _transitioning = true;
    try {
      return await body();
    } finally {
      _transitioning = false;
    }
  }
}

final class _Cancelled implements Exception {
  const _Cancelled();
}
