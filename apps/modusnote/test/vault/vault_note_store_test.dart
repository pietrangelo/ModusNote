import 'dart:convert';

import 'package:blob_storage_media/blob_storage_media.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modusnote/attachments/note_images.dart';
import 'package:modusnote/vault/vault_note_store.dart';
import 'package:offline_sync/offline_sync.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import '../audio/fake_capture.dart';
import '../notes/image_support.dart';
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

  group('categories', () {
    late UnlockedVault vault;
    late VaultNoteStore store;
    const shelf = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    const crime = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

    NoteCategory category(String id, String name, {String? parent}) =>
        NoteCategory(
          id: CategoryId(id),
          name: CategoryName(name),
          parent: parent == null ? null : CategoryId(parent),
          tint: NoteTint.rose,
        );

    setUp(() async {
      final database = memoryDatabase();
      addTearDown(database.close);
      vault = await keeperOn(database).create(passphrase('frase lunga'));
      addTearDown(vault.lock);
      store = await VaultNoteStore.open(
        vault.engine,
        catalog: SeedSchemas.catalog,
        clock: () => DateTime.utc(2026, 10, 13, 15),
      );
      await store.saveCategory(category(shelf, 'Romanzi'));
      await store.saveCategory(category(crime, 'Gialli', parent: shelf));
      await store.save(
        quickNote(first, 'uno', DateTime.utc(2026, 10, 11)),
        newIn: CategoryId(crime),
      );
      await store.save(quickNote(second, 'due', DateTime.utc(2026, 10, 12)));
    });

    Future<VaultNoteStore> reopen() =>
        VaultNoteStore.open(vault.engine, catalog: SeedSchemas.catalog);

    test('the tree and where each note is filed survive a reopen', () async {
      final reopened = await reopen();

      expect(reopened.categories.ordered.map((c) => c.name.value), [
        'Romanzi',
        'Gialli',
      ]);
      expect(reopened.categories[CategoryId(crime)]!.tint, NoteTint.rose);
      expect(reopened.categoryOf(EntryId(first)), CategoryId(crime));
      expect(reopened.categoryOf(EntryId(second)), isNull);
      expect(reopened.entries, hasLength(2));
      expect(reopened.unreadable, 0);
    });

    test('a category is a sealed record, like a note', () async {
      final stored = await vault.engine.read(RecordId.parse(crime));

      expect(stored, isA<RevisionContents>());
      expect(
        CategoryCodec.decode((stored! as RevisionContents).bytes).name.value,
        'Gialli',
      );
    });

    test('saving an existing note keeps its category', () async {
      await store.save(quickNote(first, 'uno bis', DateTime.utc(2026, 10, 13)));

      expect(store.categoryOf(EntryId(first)), CategoryId(crime));
    });

    test('filing moves a note, in the trash too', () async {
      await store.file(EntryId(second), CategoryId(shelf));
      await store.moveToTrash(EntryId(first));
      await store.file(EntryId(first), null);
      await store.restore(EntryId(first));

      final reopened = await reopen();
      expect(reopened.categoryOf(EntryId(second)), CategoryId(shelf));
      expect(reopened.categoryOf(EntryId(first)), isNull);
    });

    test('deleting a category moves its notes and children up', () async {
      await store.deleteCategory(CategoryId(shelf));

      expect(
        await vault.engine.read(RecordId.parse(shelf)),
        isA<RevisionDeleted>(),
      );
      final reopened = await reopen();
      expect(reopened.categories.roots.single.id, CategoryId(crime));
      expect(reopened.categoryOf(EntryId(first)), CategoryId(crime));

      await reopened.deleteCategory(CategoryId(crime));
      final again = await reopen();
      expect(again.categories.isEmpty, isTrue);
      expect(again.categoryOf(EntryId(first)), isNull);
      expect(again.entries, hasLength(2));
      expect(again.unreadable, 0);
    });

    test('a loop or a fifth level is refused', () async {
      await expectLater(
        store.saveCategory(category(shelf, 'Romanzi', parent: crime)),
        throwsArgumentError,
      );
      var parent = crime;
      for (final id in ['c' * 32, 'd' * 32]) {
        await store.saveCategory(category(id, id, parent: parent));
        parent = id;
      }
      await expectLater(
        store.saveCategory(category('e' * 32, 'troppo', parent: parent)),
        throwsArgumentError,
      );
    });

    test('each change is queued for the server', () async {
      var writes = 0;
      store.onWrite = () => writes++;

      await store.saveCategory(category(shelf, 'Libri'));
      await store.file(EntryId(second), CategoryId(shelf));

      expect(writes, 2);
    });

    test('a category stored under another record id is refused', () async {
      await vault.engine.write(
        RecordId.parse('f' * 32),
        (await vault.engine.read(RecordId.parse(crime)))!,
      );

      final reopened = await reopen();

      expect(reopened.categories.length, 2);
      expect(reopened.unreadable, 1);
    });

    test('a category deleted on another device leaves on reload', () async {
      await vault.engine.write(RecordId.parse(crime), const RevisionDeleted());

      await store.reload();

      expect(store.categories.length, 1);
      expect(store.categoryOf(EntryId(first)), isNull);
    });
  });

  group('pictures', () {
    DynamicEntry page(List<BlobId> images) => switch (DynamicEntry.create(
      schema: SeedSchemas.documentV1,
      id: EntryId(first),
      attributes: {
        FieldKey('title'): const TextValue('Pagina'),
        if (images.isNotEmpty)
          FieldKey('attachments'): AttachmentsValue([
            for (final image in images) ImageAttachment(image),
          ]),
      },
      at: DateTime.utc(2026, 10, 13),
    )) {
      Valid(:final value) => value,
      Invalid(:final violations) => throw StateError('$violations'),
    };

    test('come back with the page after locking, and go when it goes '
        'for good', () async {
      final database = memoryDatabase();
      addTearDown(database.close);
      final storage = memoryBlobs();
      final created = await keeperOn(database)
          .create(passphrase('frase lunga'));
      NoteImages imagesOf(UnlockedVault vault) => NoteImages(
        blobs: storage.blobs,
        engine: vault.engine,
        chooser: FakeChooser(),
      );
      final store = await VaultNoteStore.open(
        created.engine,
        catalog: SeedSchemas.catalog,
        images: imagesOf(created),
      );
      final image = (await store.images!.choose())!;
      await store.save(page([image.id]), pictures: [image]);
      created.lock();

      final unlocked = await keeperOn(database)
          .unlock(passphrase('frase lunga'));
      addTearDown(unlocked.lock);
      final reopened = await VaultNoteStore.open(
        unlocked.engine,
        catalog: SeedSchemas.catalog,
        images: imagesOf(unlocked),
      );
      expect(reopened.imageOf(image.id), image);
      expect(await reopened.images!.open(image), pixel);

      await reopened.moveToTrash(EntryId(first));
      expect(
        storage.files.file('/blobs/${image.id.value}.enc').existsSync(),
        isTrue,
      );
      await reopened.deleteForever(EntryId(first));
      expect(
        storage.files.file('/blobs/${image.id.value}.enc').existsSync(),
        isFalse,
      );
    });

    test('a picture pasted into the text of another note is kept while either '
        'shows it', () async {
      final database = memoryDatabase();
      addTearDown(database.close);
      final storage = memoryBlobs();
      final vault = await keeperOn(database).create(passphrase('frase lunga'));
      addTearDown(vault.lock);
      final released = <BlobId>{};
      final store =
          await VaultNoteStore.open(
              vault.engine,
              catalog: SeedSchemas.catalog,
              images: NoteImages(
                blobs: storage.blobs,
                engine: vault.engine,
                chooser: FakeChooser(),
              ),
            )
            ..onRelease = (ids) async => released.addAll(ids);
      final image = (await store.images!.choose())!;
      DynamicEntry text(String id, String body) => switch (DynamicEntry.create(
        schema: SeedSchemas.documentV1,
        id: EntryId(id),
        attributes: {
          FieldKey('title'): const TextValue('Pagina'),
          FieldKey('body'): TextValue(body),
        },
        at: DateTime.utc(2026, 10, 14),
      )) {
        Valid(:final value) => value,
        Invalid(:final violations) => throw StateError('$violations'),
      };
      final shown = InlineImages.markdown('Il palco', image.id);
      final other = 'b' * 32;
      bool stored() =>
          storage.files.file('/blobs/${image.id.value}.enc').existsSync();

      await store.save(text(first, 'Prima $shown'), pictures: [image]);
      await store.save(
        text(other, 'Copia $shown'),
        pictures: [store.imageOf(image.id)!],
      );
      await store.save(text(first, 'Prima, senza foto'));

      expect(stored(), isTrue, reason: 'the other note still shows it');
      expect(released, isEmpty);

      await store.save(text(other, 'Copia, senza foto'));
      expect(stored(), isFalse);
      expect(released, {image.id});
    });

    test('a picture added and left out of the save is deleted', () async {
      final database = memoryDatabase();
      addTearDown(database.close);
      final storage = memoryBlobs();
      final vault = await keeperOn(database).create(passphrase('frase lunga'));
      addTearDown(vault.lock);
      final store = await VaultNoteStore.open(
        vault.engine,
        catalog: SeedSchemas.catalog,
        images: NoteImages(
          blobs: storage.blobs,
          engine: vault.engine,
          chooser: FakeChooser(),
        ),
      );
      final image = (await store.images!.choose())!;

      await store.save(page([]), pictures: [image]);

      expect(
        storage.files.file('/blobs/${image.id.value}.enc').existsSync(),
        isFalse,
      );
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

  group('conflict copies', () {
    late VaultNoteStore store;

    DynamicEntry page(String title) => switch (DynamicEntry.create(
      schema: SeedSchemas.documentV1,
      id: EntryId(first),
      attributes: {
        FieldKey('title'): TextValue(title),
        FieldKey('body'): const TextValue('Testo'),
      },
      at: DateTime.utc(2026, 10, 23),
    )) {
      Valid(:final value) => value,
      Invalid(:final violations) => throw StateError('$violations'),
    };

    LostEdit lost(DynamicEntry entry, {String record = first}) => LostEdit(
      record: RecordId.parse(record),
      contents: RevisionContents(
        RecordedNoteCodec.encode(RecordedNote.of(entry)),
      ),
      writtenAt: DateTime.utc(2026, 10, 23),
    );

    setUp(() async {
      final database = memoryDatabase();
      addTearDown(database.close);
      final vault = await keeperOn(database).create(passphrase('frase lunga'));
      addTearDown(vault.lock);
      store = await VaultNoteStore.open(
        vault.engine,
        catalog: SeedSchemas.catalog,
        copyTitle: (title) => '$title (copia)',
      );
    });

    test('an edit that lost is kept as a note of its own', () async {
      await store.save(page('Vinta'));

      final kept = await store.keepLost([lost(page('Persa'))]);

      expect(kept, 1);
      final copy = store.entries.singleWhere((e) => e.id.value != first);
      expect(copy.valueOf(FieldKey('title')), const TextValue('Persa (copia)'));
      expect(copy.valueOf(FieldKey('body')), const TextValue('Testo'));
      expect(copy.id.value, matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(
        store.entryOf(EntryId(first))!.valueOf(FieldKey('title')),
        const TextValue('Vinta'),
      );
    });

    test('a title too long for a suffix stays as it was', () async {
      final long = 'x' * 200;

      await store.keepLost([lost(page(long))]);

      expect(store.entries.single.valueOf(FieldKey('title')), TextValue(long));
    });

    test(
      'bytes under another record\'s id, or not a note, keep nothing',
      () async {
        final kept = await store.keepLost([
          lost(page('Altrove'), record: second),
          LostEdit(
            record: RecordId.parse(first),
            contents: RevisionContents(utf8.encode('rumore')),
            writtenAt: DateTime.utc(2026, 10, 23),
          ),
        ]);

        expect(kept, 0);
        expect(store.entries, isEmpty);
      },
    );
  });
}
