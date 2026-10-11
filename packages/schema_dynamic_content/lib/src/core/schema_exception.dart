/// The invariant a schema or one of its parts would break.
enum SchemaInvariant {
  invalidIdentifier,
  invalidVersion,
  invalidLabel,
  noFields,
  tooManyFields,
  duplicateFieldKey,
  hintForUnknownField,
  invalidRange,
  invalidChoiceOptions,
  requiredFieldWithoutDefault,
  invalidDefault,
  unknownMigrationTarget,
}

/// A schema, field definition or migration that cannot exist.
///
/// Thrown at construction so an invalid [SchemaDefinition] is never
/// representable; entries, which users edit freely, report violations instead.
final class InvalidSchemaException implements Exception {
  const InvalidSchemaException(this.invariant, [this.detail = '']);

  final SchemaInvariant invariant;
  final String detail;

  @override
  String toString() => 'InvalidSchemaException(${invariant.name}) $detail';
}

/// A value object built from out-of-range input (an impossible date, NaN).
final class InvalidValueException implements Exception {
  const InvalidValueException(this.message);

  final String message;

  @override
  String toString() => 'InvalidValueException: $message';
}

/// A serialized schema that could not be decoded. The only exception
/// [SchemaCodec.decode] lets escape, whatever the input.
final class SchemaFormatException implements Exception {
  const SchemaFormatException(this.message);

  final String message;

  @override
  String toString() => 'SchemaFormatException: $message';
}

/// A serialized entry that could not be decoded. The only exception
/// [EntryCodec.decode] lets escape, whatever the input.
final class EntryFormatException implements Exception {
  const EntryFormatException(this.message);

  final String message;

  @override
  String toString() => 'EntryFormatException: $message';
}
