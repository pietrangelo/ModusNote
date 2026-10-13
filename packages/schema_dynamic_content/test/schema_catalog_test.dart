import 'package:schema_dynamic_content/schema_dynamic_content.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

DynamicEntry oldTask({required String description, bool completed = false}) =>
    valueOf(
      DynamicEntry.create(
        schema: SeedSchemas.taskV1,
        id: EntryId('t1'),
        attributes: {
          key('description'): TextValue(description),
          key('priority'): const ChoiceValue('high'),
          key('completed'): BooleanValue(completed),
        },
        at: at,
      ),
    );

void main() {
  test('task_v2 is a titled list of tasks', () {
    final s = SeedSchemas.taskV2;

    expect(s.id, SchemaId('task', 2));
    expect(s.fields.map((f) => f.key.value).toSet(), {
      'title',
      'items',
      'due',
      'priority',
    });
    expect(s.fieldFor(key('items'))!.type, isA<ChecklistFieldType>());
    expect(s.fieldFor(key('items'))!.required, isTrue);
    expect(s.fieldFor(key('title'))!.required, isFalse);
    expect(s.uiHints.map((h) => h.field.value).take(2), ['title', 'items']);
  });

  test('the library offers the current version of each type', () {
    expect(SeedSchemas.all.map((s) => s.id), [
      SchemaId('song_sketch', 1),
      SchemaId('dream_log', 1),
      SchemaId('task', 2),
      SchemaId('document', 1),
      SchemaId('quick_note', 1),
    ]);
  });

  test('every type has its own icon and tint', () {
    final icons = SeedSchemas.all.map((s) => s.icon).toList();
    final tints = SeedSchemas.all.map((s) => s.tint).toList();

    expect(icons, everyElement(isNotNull));
    expect(tints, everyElement(isNotNull));
    expect(icons.toSet(), hasLength(icons.length));
    expect(tints.toSet(), hasLength(tints.length));
    expect(SeedSchemas.taskV2.icon, NoteIcon.checklist);
    expect(SeedSchemas.taskV2.tint, NoteTint.cyan);
  });

  test('appearance survives the schema codec', () {
    for (final schema in SeedSchemas.all) {
      final back = SchemaCodec.decode(SchemaCodec.encode(schema));
      expect((back.icon, back.tint), (schema.icon, schema.tint));
    }
    final plain = schemaOf([field('a', TextFieldType())]);
    expect(SchemaCodec.decode(SchemaCodec.encode(plain)).icon, isNull);
  });

  test('an old task becomes a one-item list, keeping text and state', () {
    final task = oldTask(description: 'Accordare la chitarra', completed: true);

    final upgraded = SeedSchemas.catalog.upgrade(task)!;

    expect(upgraded.schemaId, SchemaId('task', 2));
    expect(
      upgraded.valueOf(key('items')),
      ChecklistValue([
        const ChecklistItem('Accordare la chitarra', done: true),
      ]),
    );
    expect(upgraded.valueOf(key('priority')), const ChoiceValue('high'));
    expect(upgraded.valueOf(key('description')), isNull);
    expect(upgraded.valueOf(key('completed')), isNull);
    // Read as the new version, saved as such only when next edited.
    expect(upgraded.audit, task.audit);
    expect(upgraded.id, task.id);
  });

  test('a task not completed is still to do', () {
    final upgraded = SeedSchemas.catalog.upgrade(
      oldTask(description: 'Cambiare le corde'),
    )!;

    expect(
      upgraded.valueOf(key('items')),
      ChecklistValue([const ChecklistItem('Cambiare le corde', done: false)]),
    );
  });

  test('the catalog resolves old and current versions', () {
    final catalog = SeedSchemas.catalog;

    expect(catalog.schemaFor(SchemaId('task', 1)), SeedSchemas.taskV1);
    expect(catalog.schemaFor(SchemaId('task', 2)), SeedSchemas.taskV2);
    expect(catalog.schemaFor(SchemaId('task', 3)), isNull);
    expect(catalog.current, SeedSchemas.all);
  });

  test('current entries come back unchanged', () {
    final note = valueOf(
      DynamicEntry.create(
        schema: SeedSchemas.quickNoteV1,
        id: EntryId('n1'),
        attributes: {key('content'): const TextValue('idea')},
        at: at,
      ),
    );

    expect(SeedSchemas.catalog.upgrade(note), same(note));
  });

  group('adversary', () {
    test('an old description is made safe as a task, never dropped', () {
      // Text was fine as a description; a task is one line with nothing
      // that renders differently from what it holds.
      final upgraded = SeedSchemas.catalog.upgrade(
        oldTask(description: 'riga uno\nriga due \u202Eexe'),
      )!;

      expect(
        upgraded.valueOf(key('items')),
        ChecklistValue([
          const ChecklistItem('riga uno riga due exe', done: false),
        ]),
      );
    });

    test('an entry of an unknown version is not upgraded', () {
      final stranger = valueOf(
        DynamicEntry.create(
          schema: schemaOf(
            [field('a', TextFieldType())],
            id: 'task',
            version: 9,
          ),
          id: EntryId('x'),
          attributes: const {},
          at: at,
        ),
      );

      expect(SeedSchemas.catalog.upgrade(stranger), isNull);
    });

    test('an appearance name this device does not know is ignored', () {
      final encoded = SchemaCodec.encode(SeedSchemas.taskV2)
          .replaceFirst('"icon":"checklist"', '"icon":"from_the_future"');

      final back = SchemaCodec.decode(encoded);

      expect(back.icon, isNull);
      expect(back.tint, NoteTint.cyan);
    });

    test('appearance takes no other properties', () {
      final encoded = SchemaCodec.encode(SeedSchemas.taskV2)
          .replaceFirst('"tint":"cyan"', '"tint":"cyan","script":"x"');

      expect(
        () => SchemaCodec.decode(encoded),
        throwsA(isA<SchemaFormatException>()),
      );
    });
  });
}
