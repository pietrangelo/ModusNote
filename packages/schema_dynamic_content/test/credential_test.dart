import 'dart:convert';

import 'package:schema_dynamic_content/schema_dynamic_content.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

void main() {
  group('PasswordFieldType', () {
    final type = PasswordFieldType(maxLength: 8);

    test('takes a secret within its length', () {
      expect(type.check(const SecretValue('a1!B c€')), isEmpty);
      expect(type.check(const SecretValue('12345678')), isEmpty);
    });

    test('refuses a longer secret, counted in characters', () {
      expect(type.check(const SecretValue('123456789')), [
        ViolationCode.tooLong,
      ]);
    });

    test('refuses control and bidirectional characters', () {
      expect(type.check(const SecretValue('ab\ncd')), [
        ViolationCode.invalidCharacters,
      ]);
      expect(type.check(const SecretValue('ab\u202Ecd')), [
        ViolationCode.invalidCharacters,
      ]);
    });

    test('refuses plain text: a password is never a TextValue', () {
      expect(type.check(const TextValue('secret')), [
        ViolationCode.typeMismatch,
      ]);
    });

    test('bounds its length', () {
      expect(() => PasswordFieldType(maxLength: 0), throwsA(anything));
      expect(
        () => PasswordFieldType(maxLength: PasswordFieldType.maxAllowed + 1),
        throwsA(anything),
      );
    });
  });

  group('SecretValue', () {
    test('never shows its text in toString', () {
      expect('${const SecretValue('hunter2')}', isNot(contains('hunter2')));
    });
  });

  group('UrlFieldType', () {
    const type = UrlFieldType();

    test('takes an http or https address as the app writes it', () {
      expect(type.check(const TextValue('https://example.com/login')), isEmpty);
      expect(type.check(const TextValue('http://example.com')), isEmpty);
    });

    test('refuses what the app would not open', () {
      for (final url in [
        'example.com', // not normalized: the UI adds https://
        'javascript:alert(1)',
        'file:///etc/passwd',
        'https://user:pw@example.com',
        'https://exаmple.com', // Cyrillic a
        ' https://example.com',
      ]) {
        expect(type.check(TextValue(url)), [
          ViolationCode.invalidUrl,
        ], reason: url);
      }
    });

    test('refuses other kinds of value', () {
      expect(type.check(const SecretValue('https://example.com')), [
        ViolationCode.typeMismatch,
      ]);
    });
  });

  group('credential', () {
    final schema = SeedSchemas.credentialV1;

    test('has the fields the user asked for', () {
      expect(schema.fields.map((f) => f.key.value), [
        'description',
        'username',
        'password',
        'link',
        'password_expiry',
      ]);
      expect(schema.fieldFor(key('description'))!.required, isTrue);
      expect(schema.fieldFor(key('password'))!.type, isA<PasswordFieldType>());
      expect(schema.fieldFor(key('link'))!.type, isA<UrlFieldType>());
      expect(
        schema.fieldFor(key('password_expiry'))!.type,
        isA<DateFieldType>(),
      );
      expect(schema.icon, NoteIcon.key);
    });

    DynamicEntry entry() => switch (DynamicEntry.create(
      schema: schema,
      id: EntryId('0123456789abcdef0123456789abcdef'),
      attributes: {
        key('description'): const TextValue('Banca'),
        key('username'): const TextValue('mario'),
        key('password'): const SecretValue('zebra-Quokka-42'),
        key('link'): const TextValue('https://banca.example'),
        key('password_expiry'): DateValue(2026, 12, 1),
      },
      at: at,
    )) {
      Valid(:final value) => value,
      Invalid(:final violations) => throw StateError('$violations'),
    };

    test('round-trips through the entry codec as a secret', () {
      final bytes = EntryCodec.encode(entry());
      final json = jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;
      expect((json['attributes'] as Map)['password'], {
        'kind': 'secret',
        'value': 'zebra-Quokka-42',
      });
      final back = EntryCodec.decode(
        bytes,
        schemas: (id) => id == schema.id ? schema : null,
      );
      expect(
        (back as Valid<DynamicEntry>).value.attributes,
        entry().attributes,
      );
    });

    test('search never matches the password', () {
      expect(EntrySearch('quokka').matches(entry()), isFalse);
      expect(EntrySearch('banca mario').matches(entry()), isTrue);
    });

    test('the schema round-trips through the schema codec', () {
      expect(SchemaCodec.decode(SchemaCodec.encode(schema)), schema);
    });

    test('switching type never turns the password into text', () {
      final carried = SchemaSwitch.carryOver(
        from: schema,
        values: entry().attributes,
        to: SeedSchemas.quickNoteV1,
      );
      expect(carried.values.whereType<SecretValue>(), isEmpty);
      expect(
        carried.values.whereType<TextValue>().map((v) => v.text),
        isNot(contains('zebra-Quokka-42')),
      );
    });
  });
}
