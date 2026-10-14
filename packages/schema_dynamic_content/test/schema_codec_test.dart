import 'dart:convert';

import 'package:glados/glados.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import 'fixtures.dart';

/// Builds a random but valid schema, so the round-trip property covers every
/// field type and constraint combination rather than a handful of fixtures.
SchemaDefinition randomSchema(Random random) {
  FieldType randomType() => switch (random.nextInt(14)) {
    0 => TextFieldType(maxLength: 1 + random.nextInt(5000)),
    1 => const RichTextFieldType(),
    2 => const MarkdownFieldType(),
    3 => NumberFieldType(
      min: random.nextBool() ? -random.nextInt(100) : null,
      max: random.nextBool() ? 100 + random.nextInt(100) : null,
      integerOnly: random.nextBool(),
    ),
    4 => const DateFieldType(),
    5 => const DateTimeFieldType(),
    6 => const BooleanFieldType(),
    7 => RatingFieldType(min: random.nextInt(2), max: 2 + random.nextInt(9)),
    8 => ChoiceFieldType([
      for (var i = 0; i <= random.nextInt(5); i++) 'option_$i',
    ]),
    9 => TagListFieldType(maxTags: 1 + random.nextInt(64)),
    10 => const AudioBlobFieldType(),
    11 => PasswordFieldType(maxLength: 1 + random.nextInt(1024)),
    12 => const UrlFieldType(),
    _ => const BooleanFieldType(),
  };

  Label randomLabel(String name) => random.nextBool()
      ? Label.localized('schema.random.field.$name')
      : Label.literal('Campo «$name» ✓');

  final fields = [
    for (var i = 0; i <= random.nextInt(10); i++)
      FieldDefinition(
        key: FieldKey('field_$i'),
        label: randomLabel('field_$i'),
        type: randomType(),
        required: random.nextBool(),
      ),
  ];
  return SchemaDefinition(
    id: SchemaId('random_${random.nextInt(1000)}', 1 + random.nextInt(50)),
    label: randomLabel('schema'),
    fields: fields,
    uiHints: [
      for (final (i, f) in fields.indexed)
        if (random.nextBool())
          WidgetPlacement(field: f.key, section: 'section_${i % 3}', order: i),
    ],
  );
}

Matcher rejected() => throwsA(isA<SchemaFormatException>());

void main() {
  test('round-trips a hand-built schema', () {
    expect(SchemaCodec.decode(SchemaCodec.encode(song)), song);
  });

  Glados(any.positiveIntOrZero)
      .test('decode(encode(s)) == s for any valid schema', (seed) {
        final schema = randomSchema(Random(seed));

        expect(SchemaCodec.decode(SchemaCodec.encode(schema)), schema);
      });

  test('the encoded form names field kinds explicitly', () {
    final json = jsonDecode(SchemaCodec.encode(song)) as Map<String, Object?>;
    final first = (json['fields']! as List).first as Map<String, Object?>;

    expect((first['type']! as Map)['kind'], 'text');
  });

  group('adversary', () {
    final valid = SchemaCodec.encode(song);

    void decodesOrRejects(String input) {
      try {
        SchemaCodec.decode(input);
      } on SchemaFormatException {
        // The only acceptable failure.
      }
    }

    Glados(any.list(any.intInRange(0, 0x7F))).test(
      'arbitrary text never throws anything but SchemaFormatException',
      (codes) => decodesOrRejects(String.fromCharCodes(codes)),
    );

    Glados(any.positiveIntOrZero)
        .test('a corrupted valid document never throws anything else', (seed) {
          final random = Random(seed);
          final chars = valid.split('');
          for (var i = 0; i <= random.nextInt(4); i++) {
            chars[random.nextInt(chars.length)] = String.fromCharCode(
              32 + random.nextInt(95),
            );
          }
          decodesOrRejects(chars.join());
        });

    Glados(any.positiveIntOrZero)
        .test('a truncated valid document is rejected', (seed) {
          final cut = Random(seed).nextInt(valid.length);

          expect(() => SchemaCodec.decode(valid.substring(0, cut)), rejected());
        });

    test('deep nesting is refused before it can exhaust the stack', () {
      final bomb = '${'[' * 100000}${']' * 100000}';

      expect(() => SchemaCodec.decode(bomb), rejected());
    });

    test('nesting hidden in a string literal does not count', () {
      final json = jsonDecode(valid) as Map<String, Object?>;
      json['label'] = {'text': '[[[[[[[[[[[[[[[[[[[[{{{{{{{{{{'};

      expect(
        SchemaCodec.decode(jsonEncode(json)).label,
        Label.literal('[[[[[[[[[[[[[[[[[[[[{{{{{{{{{{'),
      );
    });

    test('oversized documents are refused', () {
      expect(
        () => SchemaCodec.decode(' ' * (SchemaCodec.maxDocumentLength + 1)),
        rejected(),
      );
    });

    Map<String, Object?> mutable() => jsonDecode(valid) as Map<String, Object?>;
    Map<String, Object?> firstField(Map<String, Object?> json) =>
        (json['fields']! as List).first as Map<String, Object?>;

    test('type confusion: a string where a boolean belongs', () {
      final json = mutable();
      firstField(json)['required'] = 'yes';

      expect(() => SchemaCodec.decode(jsonEncode(json)), rejected());
    });

    test('type confusion: a double where an integer belongs', () {
      final json = mutable()..['version'] = 1.5;

      expect(() => SchemaCodec.decode(jsonEncode(json)), rejected());
    });

    test('type confusion: constraints of another kind are refused', () {
      final json = mutable();
      firstField(json)['type'] = {
        'kind': 'text',
        'options': ['a'],
      };

      expect(() => SchemaCodec.decode(jsonEncode(json)), rejected());
    });

    test('an unknown field kind is refused, not guessed', () {
      final json = mutable();
      firstField(json)['type'] = {'kind': 'script'};

      expect(() => SchemaCodec.decode(jsonEncode(json)), rejected());
    });

    test('unknown top-level properties are refused', () {
      final json = mutable()..['__proto__'] = {'admin': true};

      expect(() => SchemaCodec.decode(jsonEncode(json)), rejected());
    });

    test('a schema that breaks an invariant is refused as malformed', () {
      final json = mutable();
      (json['fields']! as List).add(firstField(json));

      expect(() => SchemaCodec.decode(jsonEncode(json)), rejected());
    });

    test('the top level must be an object', () {
      for (final input in ['[]', '"schema"', '42', 'null', '']) {
        expect(() => SchemaCodec.decode(input), rejected(), reason: input);
      }
    });
  });
}
