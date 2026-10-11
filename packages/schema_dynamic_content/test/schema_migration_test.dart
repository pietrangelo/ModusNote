import 'package:schema_dynamic_content/schema_dynamic_content.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

void main() {
  final v1 = schemaOf([
    field('title', TextFieldType(), required: true),
    field('notes', TextFieldType()),
    field('mood', TextFieldType()),
  ], id: 'dream_log');

  final migration = SchemaMigration(
    from: v1,
    steps: [
      RenameField(from: key('notes'), to: key('transcription')),
      RemoveField(key('mood')),
      AddField(
        field('lucidity', RatingFieldType(min: 1, max: 5), required: true),
        defaultValue: const RatingValue(1),
      ),
    ],
  );

  final entryV1 = valueOf(
    DynamicEntry.create(
      schema: v1,
      id: EntryId('d1'),
      attributes: {
        key('title'): const TextValue('Volo'),
        key('notes'): const TextValue('sopra il mare'),
        key('mood'): const TextValue('sereno'),
      },
      at: at,
    ),
  );

  test('the target schema is the next version of the same schema', () {
    expect(migration.target.id, SchemaId('dream_log', 2));
    expect(migration.target.fields.map((f) => f.key.value), [
      'title',
      'transcription',
      'lucidity',
    ]);
  });

  test('migrating an entry renames, drops and fills in defaults', () {
    final migrated = valueOf(migration.migrate(entryV1, at: later));

    expect(migrated.schemaId, SchemaId('dream_log', 2));
    expect(
      migrated.valueOf(key('transcription')),
      const TextValue('sopra il mare'),
    );
    expect(migrated.valueOf(key('notes')), isNull);
    expect(migrated.valueOf(key('mood')), isNull);
    expect(migrated.valueOf(key('lucidity')), const RatingValue(1));
    expect(migrated.audit.revision, 2);
    expect(migrated.audit.createdAt, at);
  });

  test('a migrated entry is valid against the target schema', () {
    final migrated = valueOf(migration.migrate(entryV1, at: later));

    expect(
      codesOf(
        migrated.update(schema: migration.target, changes: {}, at: later),
      ),
      isEmpty,
    );
  });

  test('only entries of the source schema can be migrated', () {
    final stranger = valueOf(
      DynamicEntry.create(
        schema: song,
        id: EntryId('s1'),
        attributes: {key('title'): const TextValue('t')},
        at: at,
      ),
    );

    expect(codesOf(migration.migrate(stranger, at: later)), [
      ViolationCode.schemaMismatch,
    ]);
  });

  test('a required field cannot be added without a default', () {
    expect(
      () => SchemaMigration(
        from: v1,
        steps: [AddField(field('extra', TextFieldType(), required: true))],
      ),
      throwsA(
        isA<InvalidSchemaException>().having(
          (e) => e.invariant,
          'invariant',
          SchemaInvariant.requiredFieldWithoutDefault,
        ),
      ),
    );
  });

  test('a default must itself satisfy the new field', () {
    expect(
      () => SchemaMigration(
        from: v1,
        steps: [
          AddField(
            field('stars', RatingFieldType(min: 1, max: 5)),
            defaultValue: const RatingValue(9),
          ),
        ],
      ),
      throwsA(
        isA<InvalidSchemaException>().having(
          (e) => e.invariant,
          'invariant',
          SchemaInvariant.invalidDefault,
        ),
      ),
    );
  });

  test('steps that reference missing fields are rejected', () {
    expect(
      () => SchemaMigration(from: v1, steps: [RemoveField(key('ghost'))]),
      throwsA(isA<InvalidSchemaException>()),
    );
    expect(
      () => SchemaMigration(
        from: v1,
        steps: [RenameField(from: key('title'), to: key('notes'))],
      ),
      throwsA(isA<InvalidSchemaException>()),
    );
  });
}
