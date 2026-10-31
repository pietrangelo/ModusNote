import 'package:schema_dynamic_content/schema_dynamic_content.dart';

FieldDefinition field(String name, FieldType type) => FieldDefinition(
  key: FieldKey(name),
  label: Label.literal(name),
  type: type,
  required: false,
);

SchemaDefinition schema(String name, List<FieldDefinition> fields) =>
    SchemaDefinition(
      id: SchemaId(name, 1),
      label: Label.literal(name),
      fields: fields,
    );

DynamicEntry entry(
  SchemaDefinition s,
  Map<String, FieldValue> values, {
  String id = 'note-1',
}) {
  final at = DateTime.utc(2026, 10, 31, 12);
  final restored = DynamicEntry.restore(
    schema: s,
    id: EntryId(id),
    attributes: {for (final e in values.entries) FieldKey(e.key): e.value},
    audit: AuditTrail(createdAt: at, updatedAt: at, revision: 1),
  );
  return switch (restored) {
    Valid(:final value) => value,
    Invalid(:final violations) => throw StateError('$violations'),
  };
}

Set<FieldKey> keys(Iterable<String> names) => {
  for (final n in names) FieldKey(n),
};

String labelOf(FieldDefinition field) => switch (field.label) {
  LiteralLabel(:final text) => text,
  LocalizedLabel(:final key) => key,
};

String describe(FieldDefinition field, FieldValue value) => switch (value) {
  NumberValue(:final number) => '$number',
  BooleanValue(:final value) => value ? 'sì' : 'no',
  RatingValue(:final rating) => '$rating',
  ChoiceValue(:final option) => option,
  DateValue(:final year, :final month, :final day) => '$day/$month/$year',
  _ => '',
};
