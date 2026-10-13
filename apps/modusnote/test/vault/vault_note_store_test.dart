import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:modusnote/vault/vault_note_store.dart';
import 'package:offline_sync/offline_sync.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import 'support.dart';

DynamicEntry quickNote(String id, String content, DateTime at) =>
    switch (DynamicEntry.create(
      schema: SeedSchemas.quickNoteV1,
      id: EntryId(id),
      attributes: {FieldKey('content'): TextValue(content)},
      at: at,
    )) {
      Valid(:final value) => value,
      Invalid(:final violations) => throw StateError('$violations'),
    };

const first = '0123456789abcdef0123456789abcdef';
const second = 'fedcba9876543210fedcba9876543210';

void main() {
  setUpAll(loadSodium);
  test(
    'notes saved in the vault come back after locking and unlocking',
    () async {
      final database = memoryDatabase();
      addTearDown(database.close);
      final created = await keeperOn(database)
          .create(passphrase('frase lunga'));
      final store = await VaultNoteStore.open(
        created.engine,
        catalog: SeedSchemas.catalog,
      );
      await store.save(
        quickNote(
          first,
          'Idea per il ritornello',
          DateTime.utc(2026, 10, 11, 9),
        ),
      );
      await store.save(
        quickNote(second, 'Comprare corde', DateTime.utc(2026, 10, 11, 10)),
      );
      created.lock();

      final unlocked = await keeperOn(database)
          .unlock(passphrase('frase lunga'));
      addTearDown(unlocked.lock);
      final reopened = await VaultNoteStore.open(
        unlocked.engine,
        catalog: SeedSchemas.catalog,
      );

      expect(reopened.entries.map((e) => e.id.value), [second, first]);
      expect(
        reopened.entries.last.valueOf(FieldKey('content')),
        const TextValue('Idea per il ritornello'),
      );
    },
  );

  test('a to-do saved by an older app opens as a list of tasks', () async {
    final database = memoryDatabase();
    addTearDown(database.close);
    final vault = await keeperOn(database).create(passphrase('frase lunga'));
    addTearDown(vault.lock);
    final old = switch (DynamicEntry.create(
      schema: SeedSchemas.taskV1,
      id: EntryId(first),
      attributes: {
        FieldKey('description'): const TextValue('Accordare la chitarra'),
        FieldKey('completed'): const BooleanValue(true),
      },
      at: DateTime.utc(2026, 10, 1),
    )) {
      Valid(:final value) => value,
      Invalid(:final violations) => throw StateError('$violations'),
    };
    // Written as version 1, the way the previous app wrote it.
    await (await VaultNoteStore.open(
      vault.engine,
      catalog: SchemaCatalog(current: [SeedSchemas.taskV1]),
    )).save(old);

    final store = await VaultNoteStore.open(
      vault.engine,
      catalog: SeedSchemas.catalog,
    );

    final entry = store.entries.single;
    expect(entry.schemaId, SeedSchemas.taskV2.id);
    expect(
      entry.valueOf(FieldKey('items')),
      ChecklistValue([
        const ChecklistItem('Accordare la chitarra', done: true),
      ]),
    );
    expect(entry.audit, old.audit);
    expect(store.unreadable, 0);
  });

  test('saving notifies the screens', () async {
    final database = memoryDatabase();
    addTearDown(database.close);
    final vault = await keeperOn(database).create(passphrase('frase lunga'));
    addTearDown(vault.lock);
    final store = await VaultNoteStore.open(
      vault.engine,
      catalog: SeedSchemas.catalog,
    );
    var notified = 0;
    store.addListener(() => notified++);

    await store.save(quickNote(first, 'x', DateTime.utc(2026, 10, 11)));

    expect(notified, 1);
    expect(store.entries, hasLength(1));
  });

  group('trash', () {
    late UnlockedVault vault;
    late VaultNoteStore store;
    final trashedAt = DateTime.utc(2026, 10, 13, 15);

    setUp(() async {
      final database = memoryDatabase();
      addTearDown(database.close);
      vault = await keeperOn(database).create(passphrase('frase lunga'));
      addTearDown(vault.lock);
      store = await VaultNoteStore.open(
        vault.engine,
        catalog: SeedSchemas.catalog,
        clock: () => trashedAt,
      );
      await store.save(quickNote(first, 'uno', DateTime.utc(2026, 10, 11)));
      await store.save(quickNote(second, 'due', DateTime.utc(2026, 10, 12)));
    });

    Future<VaultNoteStore> reopen() =>
        VaultNoteStore.open(vault.engine, catalog: SeedSchemas.catalog);

    test('a trashed note leaves the library and waits in the trash', () async {
      var notified = 0;
      store.addListener(() => notified++);

      await store.moveToTrash(EntryId(first));

      expect(notified, 1);
      expect(store.entries.map((e) => e.id.value), [second]);
      expect(store.trash.single.entry.id.value, first);
      expect(store.trash.single.trashedAt, trashedAt);
      final reopened = await reopen();
      expect(reopened.entries.map((e) => e.id.value), [second]);
      expect(reopened.trash.single.trashedAt, trashedAt);
      expect(reopened.unreadable, 0);
    });

    test('restoring brings the note back as it was', () async {
      await store.moveToTrash(EntryId(first));

      await store.restore(EntryId(first));

      expect(store.trash, isEmpty);
      final reopened = await reopen();
      expect(reopened.entries.map((e) => e.id.value), [second, first]);
      expect(
        reopened.entries.last.valueOf(FieldKey('content')),
        const TextValue('uno'),
      );
    });

    test('deleting for good leaves a tombstone, not the note', () async {
      await store.moveToTrash(EntryId(first));

      await store.deleteForever(EntryId(first));

      expect(store.trash, isEmpty);
      expect(
        await vault.engine.read(RecordId.parse(first)),
        isA<RevisionDeleted>(),
      );
      final reopened = await reopen();
      expect(reopened.entries.map((e) => e.id.value), [second]);
      expect(reopened.trash, isEmpty);
      expect(reopened.unreadable, 0);
    });

    test('emptying the trash deletes every note in it', () async {
      await store.moveToTrash(EntryId(first));
      await store.moveToTrash(EntryId(second));

      await store.emptyTrash();

      expect(store.trash, isEmpty);
      expect(store.entries, isEmpty);
      for (final id in [first, second]) {
        expect(
          await vault.engine.read(RecordId.parse(id)),
          isA<RevisionDeleted>(),
        );
      }
    });

    test('each change is queued for the server', () async {
      var writes = 0;
      store.onWrite = () => writes++;

      await store.moveToTrash(EntryId(first));
      await store.restore(EntryId(first));
      await store.moveToTrash(EntryId(first));
      await store.deleteForever(EntryId(first));

      expect(writes, 4);
    });

    test('saving an edit takes the note out of the trash', () async {
      // Another device may have trashed it while it was being edited here:
      // what the person just saved is what they want to keep.
      await store.moveToTrash(EntryId(first));

      await store.save(quickNote(first, 'uno bis', DateTime.utc(2026, 10, 13)));

      expect(store.trash, isEmpty);
      expect(store.entries.map((e) => e.id.value), [first, second]);
    });

    test('a note outside the trash cannot be deleted for good', () async {
      await expectLater(store.deleteForever(EntryId(first)), throwsStateError);
      expect(store.entries, hasLength(2));
    });

    test('a note deleted on another device leaves on reload', () async {
      // What a merged tombstone from the server looks like locally.
      await vault.engine.write(RecordId.parse(first), const RevisionDeleted());

      await store.reload();

      expect(store.entries.map((e) => e.id.value), [second]);
      expect(store.unreadable, 0);
    });
  });

  group('adversary', () {
    test(
      'a record that is not a readable note is counted, never shown',
      () async {
        final database = memoryDatabase();
        addTearDown(database.close);
        final vault = await keeperOn(database)
            .create(passphrase('frase lunga'));
        addTearDown(vault.lock);
        await vault.engine.write(
          RecordId.parse(first),
          RevisionContents(utf8.encode('{"not": "an entry"}')),
        );

        final store = await VaultNoteStore.open(
          vault.engine,
          catalog: SeedSchemas.catalog,
        );

        expect(store.entries, isEmpty);
        expect(store.unreadable, 1);
      },
    );

    test('a note stored under another record id is refused', () async {
      final database = memoryDatabase();
      addTearDown(database.close);
      final vault = await keeperOn(database).create(passphrase('frase lunga'));
      addTearDown(vault.lock);
      final store = await VaultNoteStore.open(
        vault.engine,
        catalog: SeedSchemas.catalog,
      );
      await store.save(quickNote(first, 'mia', DateTime.utc(2026, 10, 11)));
      // A writer copying a note's bytes under another record id must not
      // make one note appear twice, or overwrite another in the library.
      await vault.engine.write(
        RecordId.parse(second),
        (await vault.engine.read(RecordId.parse(first)))!,
      );

      final reopened = await VaultNoteStore.open(
        vault.engine,
        catalog: SeedSchemas.catalog,
      );

      expect(reopened.entries.map((e) => e.id.value), [first]);
      expect(reopened.unreadable, 1);
    });

    test('an entry id that is not a record id cannot be saved', () async {
      final database = memoryDatabase();
      addTearDown(database.close);
      final vault = await keeperOn(database).create(passphrase('frase lunga'));
      addTearDown(vault.lock);
      final store = await VaultNoteStore.open(
        vault.engine,
        catalog: SeedSchemas.catalog,
      );

      await expectLater(
        store.save(quickNote('short', 'x', DateTime.utc(2026, 10, 11))),
        throwsArgumentError,
      );
    });
  });
}
