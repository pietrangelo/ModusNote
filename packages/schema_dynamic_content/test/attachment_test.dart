import 'dart:convert';

import 'package:glados/glados.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

final at = DateTime.utc(2026, 10, 13, 18);
final picture = BlobId('a' * 32);
final other = BlobId('b' * 32);

WebLink link(String url, {String title = ''}) =>
    WebLink.parse(url, title: title)!;

DynamicEntry document(List<Attachment> attachments) =>
    switch (DynamicEntry.create(
      schema: SeedSchemas.documentV1,
      id: EntryId('d' * 32),
      attributes: {
        FieldKey('title'): const TextValue('Manuale'),
        FieldKey('attachments'): AttachmentsValue(attachments),
      },
      at: at,
    )) {
      Valid(:final value) => value,
      Invalid(:final violations) => throw StateError('$violations'),
    };

void main() {
  group('WebLink', () {
    test('keeps http and https addresses as written', () {
      expect(
        link('https://modus.serv.run/guida?p=1#a').url,
        'https://modus.serv.run/guida?p=1#a',
      );
      expect(link('  http://example.org  ').url, 'http://example.org');
      expect(link('https://example.org/x').host, 'example.org');
    });

    test('an address without a scheme is taken as https', () {
      expect(link('example.org/pagina').url, 'https://example.org/pagina');
    });

    test('refuses what could run, mislead or reach elsewhere', () {
      for (final bad in [
        '',
        'javascript:alert(1)',
        'JavaScript:alert(1)',
        'data:text/html,<script>',
        'file:///etc/passwd',
        'note:${'a' * 32}',
        'blob:https://modus.serv.run/x',
        'ftp://example.org',
        'intent://scan#Intent;scheme=zxing;end',
        'https://',
        'https:///path',
        'https://user:pass@example.org',
        'https://user@example.org',
        'https://exa mple.org',
        'https://example.org/\u202Egpj.exe',
        'https://ex\u0430mple.org', // Cyrillic a: a look-alike host
        'https://example.org/\npath',
        'https://${'a' * WebLink.maxLength}.org',
      ]) {
        expect(WebLink.parse(bad), isNull, reason: jsonEncode(bad));
      }
    });

    test('a title is one safe line', () {
      expect(link('example.org', title: '  Guida  ').title, 'Guida');
      expect(WebLink.parse('example.org', title: 'a\nb'), isNull);
      expect(WebLink.parse('example.org', title: 'a\u202Eb'), isNull);
      expect(
        WebLink.parse('example.org', title: 'x' * (Attachment.maxText + 1)),
        isNull,
      );
    });
  });

  group('AttachmentsFieldType', () {
    final type = AttachmentsFieldType(maxItems: 3);

    test('takes images and links', () {
      expect(
        type.check(
          AttachmentsValue([
            ImageAttachment(picture, caption: 'Pianta'),
            link('example.org', title: 'Fonte'),
          ]),
        ),
        isEmpty,
      );
    });

    test('refuses other values, empty and long lists', () {
      expect(type.check(const TextValue('x')), [ViolationCode.typeMismatch]);
      expect(type.check(AttachmentsValue(const [])), [
        ViolationCode.missingRequired,
      ]);
      expect(
        type.check(
          AttachmentsValue([
            for (var i = 0; i < 4; i++) link('example.org/$i'),
          ]),
        ),
        [ViolationCode.tooManyItems],
      );
    });

    test('one image appears once', () {
      expect(
        type.check(
          AttachmentsValue([
            ImageAttachment(picture),
            ImageAttachment(picture),
          ]),
        ),
        [ViolationCode.duplicateItem],
      );
    });

    test('an image caption is one safe line', () {
      expect(
        () => ImageAttachment(picture, caption: 'a\nb'),
        throwsA(isA<InvalidValueException>()),
      );
      expect(
        () => ImageAttachment(picture, caption: 'x' * (Attachment.maxText + 1)),
        throwsA(isA<InvalidValueException>()),
      );
      expect(ImageAttachment(picture, caption: ' Pianta ').caption, 'Pianta');
    });

    test('has bounds', () {
      expect(
        () => AttachmentsFieldType(maxItems: 0),
        throwsA(isA<InvalidSchemaException>()),
      );
      expect(
        () => AttachmentsFieldType(
          maxItems: AttachmentsFieldType.maxAllowedItems + 1,
        ),
        throwsA(isA<InvalidSchemaException>()),
      );
    });

    test('lists the images it holds', () {
      final entry = document([
        ImageAttachment(picture),
        link('example.org'),
        ImageAttachment(other),
      ]);
      expect(AttachmentsValue.imagesOf(entry), [picture, other]);
    });
  });

  group('codecs', () {
    test('an entry with attachments round-trips', () {
      final entry = document([
        ImageAttachment(picture, caption: 'Pianta «primo» piano'),
        link('https://example.org/a?b=c', title: 'Fonte'),
      ]);
      final back = EntryCodec.decode(
        EntryCodec.encode(entry),
        schemas: SeedSchemas.catalog.schemaFor,
      );
      final value = (back as Valid<DynamicEntry>).value;
      expect(value.attributes, entry.attributes);
      expect(value.id, entry.id);
    });

    test('the field type round-trips in a schema', () {
      final schema = SeedSchemas.documentV1;
      expect(SchemaCodec.decode(SchemaCodec.encode(schema)), schema);
    });

    test('hostile attachments are format errors', () {
      List<int> withValue(Object value) => utf8.encode(
        jsonEncode({
          'format': 1,
          'id': 'd' * 32,
          'schema': 'document',
          'version': 1,
          'createdAt': 0,
          'updatedAt': 0,
          'revision': 1,
          'attributes': {
            'title': {'kind': 'text', 'value': 'x'},
            'attachments': {'kind': 'attachments', 'value': value},
          },
        }),
      );
      for (final value in <Object>[
        'x',
        [
          ['image'],
        ],
        [
          ['image', 'a' * 32],
        ],
        [
          ['image', 'not a blob!', ''],
        ],
        [
          ['image', 'a' * 32, 7],
        ],
        [
          ['link', 'javascript:alert(1)', ''],
        ],
        [
          ['link', 'https://example.org', 'a\u202Eb'],
        ],
        [
          ['video', 'a' * 32, ''],
        ],
        [
          {'kind': 'image'},
        ],
      ]) {
        expect(
          () => EntryCodec.decode(
            withValue(value),
            schemas: SeedSchemas.catalog.schemaFor,
          ),
          throwsA(isA<EntryFormatException>()),
          reason: jsonEncode(value),
        );
      }
    });
  });

  test('search finds captions and link titles, not addresses', () {
    final entry = document([
      ImageAttachment(picture, caption: 'Pianta del castello'),
      link('https://segreto.example.org', title: 'Mappa'),
    ]);
    expect(EntrySearch('castello').matches(entry), isTrue);
    expect(EntrySearch('mappa').matches(entry), isTrue);
    expect(EntrySearch('segreto').matches(entry), isFalse);
  });

  test('carrying attachments to another type keeps them where they fit', () {
    final values = {
      FieldKey('attachments'): AttachmentsValue([link('example.org')]),
    };
    expect(
      SchemaSwitch.carryOver(
        from: SeedSchemas.documentV1,
        values: values,
        to: SeedSchemas.quickNoteV1,
      ),
      isNot(contains(FieldKey('attachments'))),
    );
  });

  Glados(any.letterOrDigits).test('any parsed address is http(s), one '
      'printable ASCII line', (text) {
    final parsed = WebLink.parse(text);
    if (parsed == null) return;
    expect(parsed.url, matches(RegExp('^https?://')));
    expect(parsed.url, matches(RegExp(r'^[\x21-\x7E]+$')));
  });
}
