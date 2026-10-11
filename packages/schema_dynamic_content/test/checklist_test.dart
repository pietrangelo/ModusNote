import 'dart:convert';

import 'package:schema_dynamic_content/schema_dynamic_content.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

ChecklistValue list(List<(String, bool)> items) => ChecklistValue([
  for (final (text, done) in items) ChecklistItem(text, done: done),
]);

void main() {
  final type = ChecklistFieldType(maxItems: 3);
  final schema = schemaOf([field('items', type, required: true)]);

  test('a list of tasks fits a checklist field', () {
    expect(type.check(list([('latte', false), ('pane', true)])), isEmpty);
    expect(type.check(const TextValue('latte')), [ViolationCode.typeMismatch]);
  });

  test('progress counts the tasks done', () {
    final value = list([('a', true), ('b', false), ('c', true)]);

    expect((value.done, value.total), (2, 3));
    expect(value.allDone, isFalse);
    expect(list([('a', true)]).allDone, isTrue);
  });

  test('values compare by items, in order', () {
    expect(list([('a', false)]), list([('a', false)]));
    expect(list([('a', false)]), isNot(list([('a', true)])));
    expect(
      list([('a', false), ('b', false)]),
      isNot(list([('b', false), ('a', false)])),
    );
  });

  test('the entry codec keeps tasks, order and state', () {
    final entry = valueOf(
      DynamicEntry.create(
        schema: schema,
        id: EntryId('e1'),
        attributes: {
          key('items'): list([('latte', false), ('pane', true)]),
        },
        at: at,
      ),
    );

    final back = valueOf(
      EntryCodec.decode(EntryCodec.encode(entry), schemas: (_) => schema),
    );

    expect(back.valueOf(key('items')), entry.valueOf(key('items')));
  });

  test('the schema codec keeps the item limit', () {
    final back = SchemaCodec.decode(SchemaCodec.encode(schema));

    expect(back, schema);
    expect(
      (back.fieldFor(key('items'))!.type as ChecklistFieldType).maxItems,
      3,
    );
  });

  test('search finds words in any task', () {
    final entry = valueOf(
      DynamicEntry.create(
        schema: schema,
        id: EntryId('e1'),
        attributes: {
          key('items'): list([('Comprare il caffè', false)]),
        },
        at: at,
      ),
    );

    expect(EntrySearch('caffe').matches(entry), isTrue);
    expect(EntrySearch('tè').matches(entry), isFalse);
  });

  group('adversary', () {
    test('limits on items and their text', () {
      expect(
        type.check(
          list([('a', false), ('b', false), ('c', false), ('d', false)]),
        ),
        [ViolationCode.tooManyItems],
      );
      expect(type.check(list([('  ', false)])), [ViolationCode.emptyItem]);
      expect(
        type.check(
          list([('x' * (ChecklistFieldType.maxItemLength + 1), false)]),
        ),
        [ViolationCode.tooLong],
      );
      // A task is one line, and may not hide what it says.
      expect(type.check(list([('a\nb', false)])), [
        ViolationCode.invalidCharacters,
      ]);
      expect(type.check(list([('\u202Egnp.exe', false)])), [
        ViolationCode.invalidCharacters,
      ]);
      expect(type.check(ChecklistValue(const [])), [
        ViolationCode.missingRequired,
      ]);
    });

    test('the item limit itself is bounded', () {
      expect(
        () => ChecklistFieldType(maxItems: 0),
        throwsA(isA<InvalidSchemaException>()),
      );
      expect(
        () => ChecklistFieldType(
          maxItems: ChecklistFieldType.maxAllowedItems + 1,
        ),
        throwsA(isA<InvalidSchemaException>()),
      );
    });

    List<int> withItems(Object? value) => utf8.encode(
      jsonEncode({
        'format': 1,
        'id': 'e1',
        'schema': 'test',
        'version': 1,
        'createdAt': 0,
        'updatedAt': 0,
        'revision': 1,
        'attributes': {
          'items': {'kind': 'checklist', 'value': value},
        },
      }),
    );

    test('malformed checklist documents are refused as such', () {
      for (final value in <Object?>[
        'latte',
        [
          ['latte'],
        ],
        [
          ['latte', 'yes'],
        ],
        [
          [1, true],
        ],
        [
          ['latte', true, 'extra'],
        ],
        [
          {'text': 'latte', 'done': true},
        ],
        [
          [
            ['nested', true],
            true,
          ],
        ],
      ]) {
        expect(
          () => EntryCodec.decode(withItems(value), schemas: (_) => schema),
          throwsA(isA<EntryFormatException>()),
          reason: '$value',
        );
      }
    });

    test('a list over the limit decodes but is not a valid entry', () {
      final result = EntryCodec.decode(
        withItems([
          for (var i = 0; i < 4; i++) ['t$i', false],
        ]),
        schemas: (_) => schema,
      );

      expect(codesOf(result), [ViolationCode.tooManyItems]);
    });
  });
}
