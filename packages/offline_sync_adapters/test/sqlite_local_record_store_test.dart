import 'dart:io';
import 'dart:typed_data';

import 'package:collaboration_access_control/collaboration_access_control.dart';
import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:offline_sync/offline_sync.dart';
import 'package:offline_sync_adapters/offline_sync_adapters.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

final workspace = WorkspaceId.parse('00112233445566778899aabbccddeeff');
final otherWorkspace = WorkspaceId.parse('ffeeddccbbaa99887766554433221100');
final note = RecordId.parse('0123456789abcdef0123456789abcdef');
final other = RecordId.parse('fedcba9876543210fedcba9876543210');

EncryptedEnvelope envelope(int marker, [int length = 20]) => EncryptedEnvelope(
  nonce: Nonce.fromBytes(List.filled(Nonce.length, marker)),
  ciphertext: List.filled(length, marker),
);

SealedRow row(RecordId id, int marker) => SealedRow(
  record: id,
  ciphertext: WorkspaceCiphertext(
    epoch: KeyEpoch(marker),
    envelope: envelope(marker),
  ),
);

void main() {
  late Directory directory;
  late String path;
  late Database database;
  late SqliteLocalRecordStore store;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('modusnote-db');
    path = '${directory.path}/vault.db';
    database = sqlite3.open(path);
    store = SqliteLocalRecordStore(database, workspace: workspace);
  });

  tearDown(() {
    database.close();
    directory.deleteSync(recursive: true);
  });

  SqliteLocalRecordStore reopen() {
    database.close();
    database = sqlite3.open(path);
    return SqliteLocalRecordStore(database, workspace: workspace);
  }

  group('records', () {
    test('an unknown record is absent', () async {
      expect(await store.load(note), isNull);
    });

    test('saves, replaces and survives reopening the database', () async {
      await store.save(note, envelope(1));
      await store.save(note, envelope(2));
      await store.save(other, envelope(3));

      final reopened = reopen();

      expect(await reopened.load(note), envelope(2));
      expect(await reopened.load(other), envelope(3));
    });

    test('lists the ids of its own workspace only', () async {
      await store.save(note, envelope(1));
      await store.save(other, envelope(2));
      await SqliteLocalRecordStore(
        database,
        workspace: otherWorkspace,
      ).save(note, envelope(3));

      expect(await store.recordIds(), unorderedEquals([note, other]));
    });

    test(
      'workspaces sharing a database never see each other\'s records',
      () async {
        await store.save(note, envelope(1));
        final neighbour = SqliteLocalRecordStore(
          database,
          workspace: otherWorkspace,
        );

        expect(await neighbour.load(note), isNull);
      },
    );
  });

  group('outbox', () {
    test('starts empty', () async {
      expect((await store.loadOutbox()).pending, isEmpty);
    });

    test('keeps the order and the exact rows across reopening', () async {
      final outbox = Outbox.empty.enqueue(row(other, 1)).enqueue(row(note, 2));
      await store.saveOutbox(outbox);

      final reopened = reopen();

      expect((await reopened.loadOutbox()).pending, outbox.pending);
    });

    test('saving replaces the previous outbox entirely', () async {
      await store.saveOutbox(Outbox.empty.enqueue(row(note, 1)));
      await store.saveOutbox(Outbox.empty.enqueue(row(other, 2)));

      expect((await store.loadOutbox()).pending, [row(other, 2)]);
    });
  });

  group('cursors', () {
    test('start at zero and are kept per stream', () async {
      expect(await store.loadCursor(SyncStream.rows), 0);
      await store.saveCursor(SyncStream.rows, 7);
      await store.saveCursor(SyncStream.keyBundles, 3);

      final reopened = reopen();

      expect(await reopened.loadCursor(SyncStream.rows), 7);
      expect(await reopened.loadCursor(SyncStream.keyBundles), 3);
    });
  });

  group('schema', () {
    test(
      'is versioned, and opening it again does not reset anything',
      () async {
        await store.save(note, envelope(1));

        final reopened = reopen();

        expect(database.userVersion, SqliteLocalRecordStore.schemaVersion);
        expect(await reopened.load(note), envelope(1));
      },
    );

    test('refuses a database written by a newer app version', () {
      database.userVersion = SqliteLocalRecordStore.schemaVersion + 1;

      expect(
        () => SqliteLocalRecordStore(database, workspace: workspace),
        throwsA(isA<UnsupportedLocalSchemaException>()),
      );
    });
  });

  group('adversary', () {
    test(
      'a corrupted stored envelope surfaces as malformed, not a crash',
      () async {
        await store.save(note, envelope(1));
        database.execute('UPDATE records SET envelope = ? WHERE record = ?', [
          Uint8List.fromList([9, 9, 9]),
          note.hex,
        ]);

        await expectLater(
          store.load(note),
          throwsA(isA<MalformedEnvelopeException>()),
        );
      },
    );

    test('a corrupted outbox row surfaces as malformed, not a crash', () async {
      await store.saveOutbox(Outbox.empty.enqueue(row(note, 1)));
      database.execute('UPDATE outbox SET record = ?', ['not-an-id']);

      await expectLater(
        store.loadOutbox(),
        throwsA(isA<MalformedSyncDataException>()),
      );
    });

    test('deleted data is overwritten on disk (secure_delete)', () {
      expect(database.select('PRAGMA secure_delete').first.values.first, 1);
    });
  });
}
