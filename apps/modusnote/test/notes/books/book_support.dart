import 'package:modusnote/notes/note_store.dart';
import 'package:modusnote/notes/note_title.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

final novel = CategoryId('b' * 32);
final partTwo = CategoryId('p' * 32);

DynamicEntry note(
  SchemaDefinition schema,
  String id,
  Map<String, FieldValue> values, {
  int minute = 0,
}) => switch (DynamicEntry.create(
  schema: schema,
  id: EntryId(id),
  attributes: {
    for (final MapEntry(:key, :value) in values.entries) FieldKey(key): value,
  },
  at: DateTime.utc(2026, 10, 13, 10, minute),
)) {
  Valid(:final value) => value,
  Invalid(:final violations) => throw StateError('$violations'),
};

SchemaDefinition? schemaOf(DynamicEntry entry) {
  for (final schema in SeedSchemas.all) {
    if (schema.id == entry.schemaId) return schema;
  }
  return null;
}

String titleOf(DynamicEntry entry) => NoteTitle.of(entry, schemaOf(entry));

final bookId = EntryId('bk' * 16);

/// A novel: the book, three chapters (one in a part of its own, one with
/// no number), two characters, a place, and a quick note filed with it.
Future<InMemoryNoteStore> bookStore() async {
  final store = InMemoryNoteStore();
  await store.saveCategory(
    NoteCategory(id: novel, name: CategoryName('Il faro')),
  );
  await store.saveCategory(
    NoteCategory(id: partTwo, name: CategoryName('Parte due'), parent: novel),
  );
  await store.save(
    note(SeedSchemas.bookV1, bookId.value, {
      'title': const TextValue('Il faro'),
      'word_goal': NumberValue(80000),
    }),
    newIn: novel,
  );
  await store.save(
    note(SeedSchemas.bookChapterV1, 'c3' * 16, {
      'title': const TextValue('Appunti sparsi'),
    }),
    newIn: novel,
  );
  await store.save(
    note(SeedSchemas.bookChapterV1, 'c2' * 16, {
      'title': const TextValue('La tempesta'),
      'number': NumberValue(2),
      'body': const TextValue('**Pioveva** forte.'),
    }),
    newIn: partTwo,
  );
  await store.save(
    note(SeedSchemas.bookChapterV1, 'c1' * 16, {
      'title': const TextValue("L'arrivo"),
      'number': NumberValue(1),
      'body': const TextValue('# Uno\n\nArrivò di notte.'),
    }),
    newIn: novel,
  );
  for (final (id, name) in [('a2', 'Bruno'), ('a1', 'Ada')]) {
    await store.save(
      note(SeedSchemas.bookCharacterV1, id * 16, {'name': TextValue(name)}),
      newIn: novel,
    );
  }
  await store.save(
    note(SeedSchemas.bookPlaceV1, 'f1' * 16, {'name': const TextValue('Faro')}),
    newIn: partTwo,
  );
  await store.save(
    note(SeedSchemas.quickNoteV1, 'q1' * 16, {
      'content': const TextValue('Idee'),
    }),
    newIn: novel,
  );
  return store;
}
