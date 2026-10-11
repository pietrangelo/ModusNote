import 'dart:convert';

import 'package:blob_storage_media/blob_storage_media.dart';
import 'package:collaboration_access_control/collaboration_access_control.dart';
import 'package:file/memory.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modusnote/audio/note_recorder.dart';
import 'package:modusnote/vault/vault_note_store.dart';
import 'package:offline_sync/offline_sync.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import '../vault/support.dart';
import 'fake_capture.dart';

const songId = '0123456789abcdef0123456789abcdef';
final guideTrack = FieldKey('guide_track');
final at = DateTime.utc(2026, 10, 11, 9);

DynamicEntry song({BlobId? track, int minute = 0}) =>
    switch (DynamicEntry.create(
      schema: SeedSchemas.songSketchV1,
      id: EntryId(songId),
      attributes: {
        FieldKey('title'): const TextValue('Riff'),
        if (track != null) guideTrack: AudioBlobValue(track),
      },
      at: at.add(Duration(minutes: minute)),
    )) {
      Valid(:final value) => value,
      Invalid(:final violations) => throw StateError('$violations'),
    };

List<String> encFiles(MemoryFileSystem files) => [
  if (files.directory('/blobs').existsSync())
    for (final f in files.directory('/blobs').listSync()) f.basename,
];

void main() {
  setUpAll(loadSodium);

  late UnlockedVault vault;
  late ({EncryptedBlobStorage blobs, MemoryFileSystem files}) storage;
  late NoteRecorder recorder;

  setUp(() async {
    final database = memoryDatabase();
    addTearDown(database.close);
    vault = await keeperOn(database).create(passphrase('frase lunga'));
    addTearDown(vault.lock);
    storage = memoryBlobs();
    recorder = NoteRecorder(
      capture: () => FakeCapture(voice()),
      blobs: storage.blobs,
      engine: vault.engine,
      clock: () => at,
    );
  });

  Future<KeyedRecording> recordTake() async => (await recorder.start()).stop();

  test('a take is sealed under the current GroupKey and reads back', () async {
    final take = await recordTake();

    final played = await storage.blobs
        .read(
          take.metadata.blob,
          contentKey: vault.engine.contentKeyFor(take.epoch),
        )
        .expand((chunk) => chunk)
        .toList();

    expect(take.epoch, KeyEpoch.initial);
    expect(take.metadata.format, AudioFormat.opusOgg);
    expect(played, voice());
  });

  test('a saved note keeps its recording across lock and unlock', () async {
    final store = await VaultNoteStore.open(
      vault.engine,
      schemas: SeedSchemas.all,
      recorder: recorder,
    );
    final take = await recordTake();

    await store.save(song(track: take.id), takes: [take]);
    final reopened = await VaultNoteStore.open(
      vault.engine,
      schemas: SeedSchemas.all,
    );

    expect(reopened.recordingOf(take.id), take);
    expect(
      reopened.entries.single.valueOf(guideTrack),
      AudioBlobValue(take.id),
    );
  });

  test('replacing a take deletes the old one once the note is saved', () async {
    final store = await VaultNoteStore.open(
      vault.engine,
      schemas: SeedSchemas.all,
      recorder: recorder,
    );
    final first = await recordTake();
    await store.save(song(track: first.id), takes: [first]);
    final second = await recordTake();

    await store.save(song(track: second.id, minute: 1), takes: [second]);

    expect(encFiles(storage.files), ['${second.id.value}.enc']);
    expect(store.recordingOf(first.id), isNull);
  });

  test('takes of an abandoned edit are deleted', () async {
    final store = await VaultNoteStore.open(
      vault.engine,
      schemas: SeedSchemas.all,
      recorder: recorder,
    );
    final take = await recordTake();

    await store.discardTakes([take]);

    expect(encFiles(storage.files), isEmpty);
  });

  group('adversary', () {
    test('neither the take nor its metadata reach storage in clear', () async {
      final store = await VaultNoteStore.open(
        vault.engine,
        schemas: SeedSchemas.all,
        recorder: recorder,
      );
      final take = await recordTake();
      await store.save(song(track: take.id), takes: [take]);

      final onDisk = latin1.decode([
        for (final name in encFiles(storage.files))
          ...storage.files.file('/blobs/$name').readAsBytesSync(),
      ]);
      expect(onDisk, isNot(contains('ABCDEFGHIJ')));
      final record = await vault.engine.read(RecordId.parse(songId));
      expect(record, isA<RevisionContents>());
    });

    test('a cancelled take leaves nothing behind', () async {
      final active = await recorder.start();

      await active.cancel();

      expect(encFiles(storage.files), isEmpty);
    });

    test('a refused microphone records nothing', () async {
      final denied = NoteRecorder(
        capture: () => FakeCapture(voice(), denied: true),
        blobs: storage.blobs,
        engine: vault.engine,
      );

      await expectLater(
        denied.start(),
        throwsA(isA<MicrophonePermissionDeniedException>()),
      );
      expect(encFiles(storage.files), isEmpty);
    });
  });
}
