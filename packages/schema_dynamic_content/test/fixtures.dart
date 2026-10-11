import 'package:schema_dynamic_content/schema_dynamic_content.dart';

final at = DateTime.utc(2026, 10, 11, 8);
final later = DateTime.utc(2026, 10, 11, 9);

FieldKey key(String value) => FieldKey(value);

FieldDefinition field(String name, FieldType type, {bool required = false}) =>
    FieldDefinition(
      key: FieldKey(name),
      label: Label.literal(name),
      type: type,
      required: required,
    );

SchemaDefinition schemaOf(
  List<FieldDefinition> fields, {
  String id = 'test',
  int version = 1,
  List<WidgetPlacement> uiHints = const [],
}) => SchemaDefinition(
  id: SchemaId(id, version),
  label: Label.literal('Test'),
  fields: fields,
  uiHints: uiHints,
);

final song = schemaOf([
  field('title', TextFieldType(maxLength: 20), required: true),
  field('bpm', NumberFieldType(min: 20, max: 300, integerOnly: true)),
  field('key', ChoiceFieldType(['c_major', 'a_minor'])),
  field('lucidity', RatingFieldType(min: 1, max: 5)),
  field('tags', TagListFieldType(maxTags: 3)),
  field('recorded_on', const DateFieldType()),
  field('due', const DateTimeFieldType()),
  field('done', const BooleanFieldType()),
  field('guide_track', const AudioBlobFieldType()),
], id: 'song_sketch');

List<ViolationCode> codesOf<T>(Validated<T> result) => switch (result) {
  Valid() => const [],
  Invalid(:final violations) => [for (final v in violations) v.code],
};

T valueOf<T>(Validated<T> result) => switch (result) {
  Valid(:final value) => value,
  Invalid(:final violations) => throw StateError(
    'expected Valid, got $violations',
  ),
};
