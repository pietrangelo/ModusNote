import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:glados/glados.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import 'fixtures.dart';

DynamicEntry fullSong() => switch (DynamicEntry.create(
  schema: song,
  id: EntryId('0123456789abcdef0123456789abcdef'),
  attributes: {
    key('title'): const TextValue('Riff in La'),
    key('bpm'): NumberValue(120),
    key('key'): const ChoiceValue('a_minor'),
    key('lucidity'): const RatingValue(4),
    key('tags'): TagListValue({'demo', 'chitarra'}),
    key('recorded_on'): DateValue(2026, 3, 3),
    key('due'): DateTimeValue(DateTime.utc(2026, 10, 12, 18, 30)),
    key('done'): const BooleanValue(false),
    key('guide_track'): AudioBlobValue(BlobId('blob_01')),
  },
  at: at,
)) {
  Valid(:final value) => switch (value.update(
    schema: song,
    changes: {key('bpm'): NumberValue(96)},
    at: later,
  )) {
    Valid(:final value) => value,
    Invalid() => throw StateError('fixture'),
  },
  Invalid() => throw StateError('fixture'),
};

SchemaDefinition? resolve(SchemaId id) => id == song.id ? song : null;

DynamicEntry decoded(List<int> bytes) =>
    switch (EntryCodec.decode(bytes, schemas: resolve)) {
      Valid(:final value) => value,
      Invalid(:final violations) => throw StateError('$violations'),
    };

Uint8List document(Map<String, Object?> json) =>
    Uint8List.fromList(utf8.encode(jsonEncode(json)));

Map<String, Object?> jsonOf(DynamicEntry entry) =>
    jsonDecode(utf8.decode(EntryCodec.encode(entry))) as Map<String, Object?>;

void main() {
  test('every kind of value, the schema and the audit trail round-trip', () {
    final entry = fullSong();

    final back = decoded(EntryCodec.encode(entry));

    expect(back.id, entry.id);
    expect(back.schemaId, entry.schemaId);
    expect(back.attributes, entry.attributes);
    expect(back.audit, entry.audit);
  });

  test('an entry whose schema this device does not know is not opened', () {
    final unknown = jsonOf(fullSong())..['schema'] = 'someone_else';

    expect(codesOf(EntryCodec.decode(document(unknown), schemas: resolve)), [
      ViolationCode.schemaMismatch,
    ]);
  });

  test('a stored value its schema rejects is reported, not trusted', () {
    final json = jsonOf(fullSong());
    (json['attributes']! as Map<String, Object?>)['bpm'] = {
      'kind': 'number',
      'value': 999,
    };

    expect(codesOf(EntryCodec.decode(document(json), schemas: resolve)), [
      ViolationCode.outOfRange,
    ]);
  });

  group('adversary', () {
    void refuses(Map<String, Object?> json, String reason) => expect(
      () => EntryCodec.decode(document(json), schemas: resolve),
      throwsA(isA<EntryFormatException>()),
      reason: reason,
    );

    Map<String, Object?> withAttribute(String name, Object? value) {
      final json = jsonOf(fullSong());
      (json['attributes']! as Map<String, Object?>)[name] = value;
      return json;
    }

    test('type confusion in a value is a format error', () {
      refuses(withAttribute('bpm', {'kind': 'number', 'value': '120'}), 'str');
      refuses(withAttribute('title', {'kind': 'text', 'value': 5}), 'int');
      refuses(withAttribute('done', {'kind': 'boolean', 'value': 1}), 'bool');
      refuses(withAttribute('tags', {'kind': 'tags', 'value': 'a'}), 'tags');
      refuses(
        withAttribute('tags', {
          'kind': 'tags',
          'value': [1],
        }),
        'tag',
      );
      refuses(withAttribute('title', {'kind': 'sql', 'value': 'x'}), 'kind');
      refuses(withAttribute('title', 'Riff'), 'bare value');
      refuses(
        withAttribute('title', {'kind': 'text', 'value': 'x', 'extra': 1}),
        'stray property',
      );
    });

    test('impossible dates and instants are format errors', () {
      refuses(
        withAttribute('recorded_on', {
          'kind': 'date',
          'value': [2026, 2, 30],
        }),
        'no 30 February',
      );
      refuses(
        withAttribute('due', {
          'kind': 'datetime',
          'value': 9000000000000000000,
        }),
        'beyond DateTime range',
      );
      refuses(
        jsonOf(fullSong())..['updatedAt'] = -9000000000000000000,
        'audit range',
      );
    });

    test('duplicate tags are refused, never silently merged', () {
      refuses(
        withAttribute('tags', {
          'kind': 'tags',
          'value': ['a', 'a'],
        }),
        'duplicate',
      );
    });

    test('broken identifiers and audit trails are format errors', () {
      refuses(jsonOf(fullSong())..['id'] = '../etc', 'entry id');
      refuses(jsonOf(fullSong())..['version'] = 0, 'schema version');
      refuses(jsonOf(fullSong())..['revision'] = 0, 'revision');
      final json = jsonOf(fullSong());
      refuses(
        json
          ..['createdAt'] = json['updatedAt']
          ..['updatedAt'] = 0,
        'updated before created',
      );
      refuses(jsonOf(fullSong())..remove('attributes'), 'missing');
      refuses(jsonOf(fullSong())..['format'] = 2, 'unknown format');
      refuses(withAttribute('Not-A-Key', {'kind': 'text', 'value': 'x'}), 'k');
    });

    test('oversized and deeply nested documents are refused up front', () {
      expect(
        () => EntryCodec.decode(
          Uint8List(EntryCodec.maxDocumentLength + 1),
          schemas: resolve,
        ),
        throwsA(isA<EntryFormatException>()),
      );
      expect(
        () => EntryCodec.decode(
          utf8.encode('${'[' * 100000}${']' * 100000}'),
          schemas: resolve,
        ),
        throwsA(isA<EntryFormatException>()),
      );
    });

    test('bytes that are not UTF-8 are a format error', () {
      expect(
        () => EntryCodec.decode([0xC3, 0x28], schemas: resolve),
        throwsA(isA<EntryFormatException>()),
      );
    });

    Glados(any.list(any.uint8))
        .test('random bytes never crash the decoder', (bytes) {
          try {
            EntryCodec.decode(bytes, schemas: resolve);
          } on EntryFormatException {
            // The only acceptable failure.
          }
        });

    Glados2(
      any.letterOrDigits,
      any.intInRange(20, 301),
    ).test('what it encodes it decodes to the same entry', (text, bpm) {
      final title = text.isEmpty
          ? 't'
          : text.substring(0, min(20, text.length));
      final entry = switch (fullSong().update(
        schema: song,
        changes: {key('title'): TextValue(title), key('bpm'): NumberValue(bpm)},
        at: later,
      )) {
        Valid(:final value) => value,
        Invalid() => throw StateError('generator'),
      };

      final back = decoded(EntryCodec.encode(entry));

      expect(back.attributes, entry.attributes);
      expect(back.audit, entry.audit);
    });
  });
}
