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
        schemas: SeedSchemas.all,
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
        schemas: SeedSchemas.all,
      );

      expect(reopened.entries.map((e) => e.id.value), [second, first]);
      expect(
        reopened.entries.last.valueOf(FieldKey('content')),
        const TextValue('Idea per il ritornello'),
      );
    },
  );

  test('saving notifies the screens', () async {
    final database = memoryDatabase();
    addTearDown(database.close);
    final vault = await keeperOn(database).create(passphrase('frase lunga'));
    addTearDown(vault.lock);
    final store = await VaultNoteStore.open(
      vault.engine,
      schemas: SeedSchemas.all,
    );
    var notified = 0;
    store.addListener(() => notified++);

    await store.save(quickNote(first, 'x', DateTime.utc(2026, 10, 11)));

    expect(notified, 1);
    expect(store.entries, hasLength(1));
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
          schemas: SeedSchemas.all,
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
        schemas: SeedSchemas.all,
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
        schemas: SeedSchemas.all,
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
        schemas: SeedSchemas.all,
      );

      await expectLater(
        store.save(quickNote('short', 'x', DateTime.utc(2026, 10, 11))),
        throwsArgumentError,
      );
    });
  });
}
