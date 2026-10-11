import 'package:schema_dynamic_content/schema_dynamic_content.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

void main() {
  final id = EntryId('e1');

  Validated<DynamicEntry> create(Map<String, FieldValue> attributes) =>
      DynamicEntry.create(
        schema: song,
        id: id,
        attributes: {for (final e in attributes.entries) key(e.key): e.value},
        at: at,
      );

  test('a valid entry starts at revision 1 with both timestamps set', () {
    final entry = valueOf(create({'title': const TextValue('Notturno')}));

    expect(entry.schemaId, song.id);
    expect(entry.audit.revision, 1);
    expect(entry.audit.createdAt, at);
    expect(entry.audit.updatedAt, at);
    expect(entry.valueOf(key('title')), const TextValue('Notturno'));
  });

  test('accepts every field type with a well-formed value', () {
    final result = create({
      'title': const TextValue('Notturno'),
      'bpm': NumberValue(96),
      'key': const ChoiceValue('a_minor'),
      'lucidity': const RatingValue(4),
      'tags': TagListValue({'piano', 'demo'}),
      'recorded_on': DateValue(2026, 2, 28),
      'due': DateTimeValue(DateTime.utc(2026, 10, 12)),
      'done': const BooleanValue(false),
      'guide_track': AudioBlobValue(BlobId('blob-1')),
    });

    expect(codesOf(result), isEmpty);
  });

  test('a missing required field is reported', () {
    expect(codesOf(create({})), [ViolationCode.missingRequired]);
  });

  test('every violation is reported at once, with its field', () {
    final result = create({
      'title': TextValue('x' * 21),
      'bpm': NumberValue(400),
    });

    expect(result, isA<Invalid<DynamicEntry>>());
    final violations = (result as Invalid<DynamicEntry>).violations;
    expect(
      {for (final v in violations) v.field?.value: v.code},
      {'title': ViolationCode.tooLong, 'bpm': ViolationCode.outOfRange},
    );
  });

  test('constraint violations per type', () {
    expect(
      codesOf(
        create({'title': const TextValue('t'), 'bpm': NumberValue(96.5)}),
      ),
      [ViolationCode.notAnInteger],
    );
    expect(
      codesOf(
        create({
          'title': const TextValue('t'),
          'key': const ChoiceValue('b_flat'),
        }),
      ),
      [ViolationCode.invalidChoice],
    );
    expect(
      codesOf(
        create({
          'title': const TextValue('t'),
          'lucidity': const RatingValue(6),
        }),
      ),
      [ViolationCode.outOfRange],
    );
    expect(
      codesOf(
        create({
          'title': const TextValue('t'),
          'tags': TagListValue({'a', 'b', 'c', 'd'}),
        }),
      ),
      [ViolationCode.tooManyTags],
    );
  });

  test('tags may not carry bidi overrides or control characters', () {
    expect(
      codesOf(
        create({
          'title': const TextValue('t'),
          'tags': TagListValue({'ok', 'evil\u202Etxt'}),
        }),
      ),
      [ViolationCode.invalidCharacters],
    );
  });

  test('a value of the wrong type is a type mismatch', () {
    expect(codesOf(create({'title': NumberValue(1)})), [
      ViolationCode.typeMismatch,
    ]);
  });

  test('an attribute the schema does not declare is rejected', () {
    expect(
      codesOf(
        create({
          'title': const TextValue('t'),
          'mood': const TextValue('calm'),
        }),
      ),
      [ViolationCode.unknownField],
    );
  });

  group('update', () {
    final original = valueOf(create({'title': const TextValue('Notturno')}));

    test('produces a new instance and leaves the original untouched', () {
      final updated = valueOf(
        original.update(
          schema: song,
          changes: {key('bpm'): NumberValue(72)},
          at: later,
        ),
      );

      expect(identical(updated, original), isFalse);
      expect(original.valueOf(key('bpm')), isNull);
      expect(updated.valueOf(key('bpm')), NumberValue(72));
      expect(updated.audit.revision, 2);
      expect(updated.audit.createdAt, at);
      expect(updated.audit.updatedAt, later);
    });

    test('null clears an optional attribute', () {
      final withBpm = valueOf(
        original.update(
          schema: song,
          changes: {key('bpm'): NumberValue(72)},
          at: later,
        ),
      );
      final cleared = valueOf(
        withBpm.update(schema: song, changes: {key('bpm'): null}, at: later),
      );

      expect(cleared.valueOf(key('bpm')), isNull);
    });

    test('clearing a required attribute is rejected', () {
      expect(
        codesOf(
          original.update(
            schema: song,
            changes: {key('title'): null},
            at: later,
          ),
        ),
        [ViolationCode.missingRequired],
      );
    });

    test('validating against a different schema is rejected', () {
      final other = schemaOf([field('title', TextFieldType())]);

      expect(codesOf(original.update(schema: other, changes: {}, at: later)), [
        ViolationCode.schemaMismatch,
      ]);
    });
  });

  group('values', () {
    test('a calendar date must exist', () {
      expect(
        () => DateValue(2026, 2, 30),
        throwsA(isA<InvalidValueException>()),
      );
      expect(DateValue(2028, 2, 29).day, 29);
    });

    test('a date-time must be UTC so devices agree on it', () {
      expect(
        () => DateTimeValue(DateTime(2026)),
        throwsA(isA<InvalidValueException>()),
      );
    });

    test('numbers must be finite', () {
      for (final n in [double.nan, double.infinity, double.negativeInfinity]) {
        expect(() => NumberValue(n), throwsA(isA<InvalidValueException>()));
      }
    });

    test('tag lists are immutable', () {
      final tags = TagListValue({'a'});
      expect(() => tags.tags.add('b'), throwsUnsupportedError);
    });

    test('entry attributes are immutable', () {
      final entry = valueOf(create({'title': const TextValue('t')}));
      expect(
        () => entry.attributes[key('bpm')] = NumberValue(1),
        throwsUnsupportedError,
      );
    });
  });
}
