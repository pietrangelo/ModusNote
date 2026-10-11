import 'package:schema_dynamic_content/schema_dynamic_content.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

Matcher breaks(SchemaInvariant invariant) => throwsA(
  isA<InvalidSchemaException>().having(
    (e) => e.invariant,
    'invariant',
    invariant,
  ),
);

void main() {
  group('identifiers', () {
    test('field keys are lowercase snake_case', () {
      expect(FieldKey('guide_track').value, 'guide_track');
      for (final bad in ['', 'Title', 'with space', '1st', 'a-b', 'é']) {
        expect(
          () => FieldKey(bad),
          breaks(SchemaInvariant.invalidIdentifier),
          reason: bad,
        );
      }
    });

    test('field keys are at most 64 characters', () {
      expect(
        () => FieldKey('a' * 65),
        breaks(SchemaInvariant.invalidIdentifier),
      );
    });

    test('schema ids accept seed slugs and lowercase UUIDs', () {
      expect(SchemaId('song_sketch', 1).name, 'song_sketch');
      expect(SchemaId('3f2b6a1e-9c4d-4e8f-a1b2-c3d4e5f60718', 2).version, 2);
    });

    test('schema versions start at 1', () {
      expect(
        () => SchemaId('song_sketch', 0),
        breaks(SchemaInvariant.invalidVersion),
      );
    });
  });

  group('labels', () {
    test('a localized label carries a key, never display text', () {
      expect(
        Label.localized('schema.song_sketch.field.bpm'),
        isA<LocalizedLabel>(),
      );
      expect(
        () => Label.localized('Battiti per minuto'),
        breaks(SchemaInvariant.invalidLabel),
      );
    });

    test('a literal label is what the user typed, trimmed and non-empty', () {
      expect((Label.literal('  Ricetta ') as LiteralLabel).text, 'Ricetta');
      expect(() => Label.literal('   '), breaks(SchemaInvariant.invalidLabel));
    });
  });

  group('SchemaDefinition', () {
    test('keeps fields in declaration order', () {
      expect(song.fields.map((f) => f.key.value).take(3), [
        'title',
        'bpm',
        'key',
      ]);
    });

    test('looks fields up by key', () {
      expect(song.fieldFor(key('bpm'))?.type, isA<NumberFieldType>());
      expect(song.fieldFor(key('missing')), isNull);
    });

    test('is immutable', () {
      expect(() => song.fields.add(song.fields.first), throwsUnsupportedError);
    });

    test('needs at least one field', () {
      expect(() => schemaOf([]), breaks(SchemaInvariant.noFields));
    });

    test('rejects duplicate field keys', () {
      expect(
        () => schemaOf([
          field('title', TextFieldType()),
          field('title', const BooleanFieldType()),
        ]),
        breaks(SchemaInvariant.duplicateFieldKey),
      );
    });

    test('caps the number of fields', () {
      expect(
        () => schemaOf([
          for (var i = 0; i <= SchemaDefinition.maxFields; i++)
            field('f$i', const BooleanFieldType()),
        ]),
        breaks(SchemaInvariant.tooManyFields),
      );
    });

    test('ui hints must point at declared fields', () {
      expect(
        () => schemaOf(
          [field('title', TextFieldType())],
          uiHints: [
            WidgetPlacement(field: key('ghost'), section: 'main', order: 0),
          ],
        ),
        breaks(SchemaInvariant.hintForUnknownField),
      );
    });

    test('has value equality', () {
      SchemaDefinition build() => schemaOf([
        field('title', TextFieldType(maxLength: 10), required: true),
        field('key', ChoiceFieldType(['a', 'b'])),
      ]);
      expect(build(), build());
      expect(build().hashCode, build().hashCode);
    });
  });

  group('field type constraints', () {
    test('a range must not be inverted', () {
      expect(
        () => NumberFieldType(min: 10, max: 1),
        breaks(SchemaInvariant.invalidRange),
      );
      expect(
        () => RatingFieldType(min: 5, max: 1),
        breaks(SchemaInvariant.invalidRange),
      );
    });

    test('a rating scale stays between 0 and 10', () {
      expect(
        () => RatingFieldType(min: 0, max: 11),
        breaks(SchemaInvariant.invalidRange),
      );
    });

    test('text limits are positive', () {
      expect(
        () => TextFieldType(maxLength: 0),
        breaks(SchemaInvariant.invalidRange),
      );
    });

    test('a choice needs distinct, valid options', () {
      expect(
        () => ChoiceFieldType([]),
        breaks(SchemaInvariant.invalidChoiceOptions),
      );
      expect(
        () => ChoiceFieldType(['a', 'a']),
        breaks(SchemaInvariant.invalidChoiceOptions),
      );
      expect(
        () => ChoiceFieldType(['Not A Key']),
        breaks(SchemaInvariant.invalidChoiceOptions),
      );
    });
  });
}
