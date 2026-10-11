import 'package:glados/glados.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import 'fixtures.dart';

void main() {
  final note = schemaOf([
    field('content', const MarkdownFieldType(), required: true),
    field('tags', TagListFieldType()),
  ], id: 'quick_note');
  final task = schemaOf([
    field('description', TextFieldType(maxLength: 10), required: true),
    field('due', const DateTimeFieldType()),
    field('tags', TagListFieldType(maxTags: 2)),
  ], id: 'task');

  test('the primary text field is the first text-like field', () {
    expect(note.primaryTextField?.key, key('content'));
    expect(task.primaryTextField?.key, key('description'));
    expect(
      schemaOf([field('done', const BooleanFieldType())]).primaryTextField,
      isNull,
    );
  });

  test('values under the same key and of a fitting type are kept', () {
    final carried = SchemaSwitch.carryOver(
      from: note,
      values: {
        key('content'): const TextValue('Buy milk'),
        key('tags'): TagListValue({'home'}),
      },
      to: task,
    );

    expect(carried, {
      key('description'): const TextValue('Buy milk'),
      key('tags'): TagListValue({'home'}),
    });
  });

  test('the primary text moves to the target primary text field', () {
    final carried = SchemaSwitch.carryOver(
      from: task,
      values: {key('description'): const TextValue('Call Ada')},
      to: note,
    );

    expect(carried, {key('content'): const TextValue('Call Ada')});
  });

  test('a value the target would reject is dropped, never truncated', () {
    final carried = SchemaSwitch.carryOver(
      from: note,
      values: {
        key('content'): const TextValue('Much longer than ten'),
        key('tags'): TagListValue({'a', 'b', 'c'}),
      },
      to: task,
    );

    expect(carried, isEmpty);
  });

  test('fields the target lacks are left behind', () {
    final carried = SchemaSwitch.carryOver(
      from: song,
      values: {
        key('title'): const TextValue('Riff'),
        key('bpm'): NumberValue(120),
      },
      to: note,
    );

    expect(carried, {key('content'): const TextValue('Riff')});
  });

  group('adversary', () {
    final schemas = [song, note, task, ...SeedSchemas.all];

    Glados3(
      any.intInRange(0, schemas.length),
      any.intInRange(0, schemas.length),
      any.letterOrDigits,
    ).test('the result only holds fields the target accepts', (a, b, text) {
      final from = schemas[a], to = schemas[b];
      final values = {
        for (final f in from.fields)
          f.key: switch (f.type) {
            TagListFieldType() => TagListValue({text.isEmpty ? 't' : text}),
            NumberFieldType() => NumberValue(text.length),
            BooleanFieldType() => const BooleanValue(true),
            _ => TextValue(text),
          },
      };

      final carried = SchemaSwitch.carryOver(
        from: from,
        values: values,
        to: to,
      );

      for (final MapEntry(:key, :value) in carried.entries) {
        final target = to.fieldFor(key);
        expect(target, isNotNull, reason: '$key');
        expect(target!.type.check(value), isEmpty, reason: '$key');
      }
    });
  });
}
