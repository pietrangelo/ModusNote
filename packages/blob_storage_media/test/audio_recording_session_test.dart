import 'dart:async';
import 'dart:typed_data';

import 'package:blob_storage_media/blob_storage_media.dart';
import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';
import 'package:test/test.dart';

import 'support.dart';

/// Microphone double: the test pushes buffers and decides when it fails.
final class FakeCapture implements AudioCapture {
  FakeCapture({this.denyPermission = false});

  final bool denyPermission;
  final buffers = StreamController<Uint8List>();
  var stopped = false;

  @override
  Future<CapturedAudio> start() async {
    if (denyPermission) throw const MicrophonePermissionDeniedException();
    return CapturedAudio(format: AudioFormat.opusOgg, bytes: buffers.stream);
  }

  @override
  Future<void> stop() async {
    stopped = true;
    if (!buffers.isClosed) await buffers.close();
  }
}

void main() {
  late InMemoryBlobStore store;
  late EncryptedBlobStorage storage;
  late SymmetricKey contentKey;
  late FakeCapture capture;
  late DateTime now;
  final id = BlobId('rec-1');
  final t0 = DateTime.utc(2026, 10, 11, 12);

  setUpAll(initSodium);
  setUp(() {
    store = InMemoryBlobStore();
    storage = EncryptedBlobStorage(
      store: store,
      encryptor: newEncryptor(),
      subkeys: newSubkeys(),
    );
    contentKey = newEncryptor().generateKey();
    capture = FakeCapture();
    now = t0;
  });
  tearDown(() => contentKey.dispose());

  AudioRecordingSession session([AudioCapture? source]) =>
      AudioRecordingSession(
        capture: source ?? capture,
        storage: storage,
        clock: () => now,
      );

  test('a new session is idle', () {
    expect(session().state, isA<RecordingIdle>());
  });

  test('start, speak, stop yields metadata for an encrypted blob', () async {
    final recording = session();
    await recording.start(id: id, contentKey: contentKey);
    expect(recording.state, isA<RecordingActive>());

    final spoken = audio(70000);
    capture.buffers
      ..add(Uint8List.sublistView(spoken, 0, 30000))
      ..add(Uint8List.sublistView(spoken, 30000));
    now = t0.add(const Duration(seconds: 4));
    final metadata = await recording.stop();

    expect(metadata.id, id);
    expect(metadata.format, AudioFormat.opusOgg);
    expect(metadata.duration, const Duration(seconds: 4));
    expect(metadata.recordedAt, t0);
    expect(metadata.blob.plaintextLength, 70000);
    expect(recording.state, isA<RecordingFinished>());
    expect((recording.state as RecordingFinished).metadata, metadata);
    expect(
      await collect(storage.read(metadata.blob, contentKey: contentKey)),
      spoken,
    );
  });

  test('stop() stops the microphone', () async {
    final recording = session();
    await recording.start(id: id, contentKey: contentKey);
    await recording.stop();

    expect(capture.stopped, isTrue);
  });

  test('cancel() stops the microphone and keeps nothing', () async {
    final recording = session();
    await recording.start(id: id, contentKey: contentKey);
    capture.buffers.add(audio(100000));
    await recording.cancel();

    expect(recording.state, isA<RecordingCancelled>());
    expect(capture.stopped, isTrue);
    expect(store.committed, isEmpty);
    expect(store.pending, isEmpty);
  });

  test(
    'a denied microphone fails the session before anything is written',
    () async {
      final recording = session(FakeCapture(denyPermission: true));

      await expectLater(
        recording.start(id: id, contentKey: contentKey),
        throwsA(isA<MicrophonePermissionDeniedException>()),
      );
      expect(recording.state, isA<RecordingFailed>());
      expect(store.pending, isEmpty);
    },
  );

  group('illegal transitions are programming errors', () {
    test('stop or cancel before start', () async {
      await expectLater(session().stop(), throwsStateError);
      await expectLater(session().cancel(), throwsStateError);
    });

    test('starting twice', () async {
      final recording = session();
      await recording.start(id: id, contentKey: contentKey);

      await expectLater(
        recording.start(id: BlobId('rec-2'), contentKey: contentKey),
        throwsStateError,
      );
    });

    test('a finished session cannot be reused', () async {
      final recording = session();
      await recording.start(id: id, contentKey: contentKey);
      await recording.stop();

      await expectLater(
        recording.start(id: BlobId('rec-2'), contentKey: contentKey),
        throwsStateError,
      );
      await expectLater(recording.stop(), throwsStateError);
    });

    test('a second start while the first is still starting', () async {
      final recording = session();
      final first = recording.start(id: id, contentKey: contentKey);

      await expectLater(
        recording.start(id: BlobId('rec-2'), contentKey: contentKey),
        throwsStateError,
      );
      await first;
    });
  });

  group('adversary', () {
    test(
      'cancelling after the microphone already ended keeps nothing',
      () async {
        final recording = session();
        await recording.start(id: id, contentKey: contentKey);
        capture.buffers.add(audio(500));
        await capture.buffers.close();
        while (store.committed.isEmpty) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
        await recording.cancel();

        expect(store.committed, isEmpty);
      },
    );

    test('microphone failure mid-recording leaves no partial file', () async {
      final recording = session();
      await recording.start(id: id, contentKey: contentKey);
      capture.buffers
        ..add(audio(100000))
        ..addError(StateError('device unplugged'));

      await expectLater(recording.stop(), throwsStateError);
      expect(recording.state, isA<RecordingFailed>());
      expect(store.committed, isEmpty);
      expect(store.pending, isEmpty);
    });

    test('the store only ever sees ciphertext while recording', () async {
      final recording = session();
      await recording.start(id: id, contentKey: contentKey);
      final spoken = audio(3 * ChunkLayout.plaintextChunkBytes);
      for (var offset = 0; offset < spoken.length; offset += 4000) {
        final end = offset + 4000 < spoken.length
            ? offset + 4000
            : spoken.length;
        capture.buffers.add(Uint8List.sublistView(spoken, offset, end));
      }
      await recording.stop();

      expect(leaks(store.everWritten.toBytes(), spoken), isFalse);
    });

    test(
      'cancelling after the app was backgrounded mid-chunk keeps nothing',
      () async {
        final recording = session();
        await recording.start(id: id, contentKey: contentKey);
        capture.buffers.add(audio(ChunkLayout.plaintextChunkBytes + 10));
        await Future<void>.delayed(Duration.zero);
        await recording.cancel();

        expect(store.committed, isEmpty);
        expect(store.pending, isEmpty);
      },
    );
  });
}
