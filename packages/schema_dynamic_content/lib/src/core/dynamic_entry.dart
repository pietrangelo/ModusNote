import 'package:meta/meta.dart';

import 'field_value.dart';
import 'identifiers.dart';
import 'schema_definition.dart';
import 'violation.dart';

@immutable
final class AuditTrail {
  const AuditTrail({
    required this.createdAt,
    required this.updatedAt,
    required this.revision,
  });

  final DateTime createdAt;
  final DateTime updatedAt;
  final int revision;

  AuditTrail touchedAt(DateTime at) =>
      AuditTrail(createdAt: createdAt, updatedAt: at, revision: revision + 1);

  @override
  bool operator ==(Object other) =>
      other is AuditTrail &&
      other.createdAt == createdAt &&
      other.updatedAt == updatedAt &&
      other.revision == revision;

  @override
  int get hashCode => Object.hash(createdAt, updatedAt, revision);
}

/// Aggregate root: one note of any type.
///
/// Only reachable through [create], [update] and schema migrations, all of
/// which validate against the schema, so a held [DynamicEntry] always
/// satisfied its schema at its last transition. Transitions return new
/// instances; nothing mutates in place.
@immutable
final class DynamicEntry {
  DynamicEntry._({
    required this.id,
    required this.schemaId,
    required Map<FieldKey, FieldValue> attributes,
    required this.audit,
  }) : attributes = Map.unmodifiable(attributes);

  static Validated<DynamicEntry> create({
    required SchemaDefinition schema,
    required EntryId id,
    required Map<FieldKey, FieldValue> attributes,
    required DateTime at,
  }) => _validated(
    schema,
    attributes,
    (valid) => DynamicEntry._(
      id: id,
      schemaId: schema.id,
      attributes: valid,
      audit: AuditTrail(createdAt: at, updatedAt: at, revision: 1),
    ),
  );

  final EntryId id;
  final SchemaId schemaId;
  final Map<FieldKey, FieldValue> attributes;
  final AuditTrail audit;

  FieldValue? valueOf(FieldKey key) => attributes[key];

  /// Applies [changes]; a `null` value clears that attribute.
  Validated<DynamicEntry> update({
    required SchemaDefinition schema,
    required Map<FieldKey, FieldValue?> changes,
    required DateTime at,
  }) {
    if (schema.id != schemaId) {
      return Invalid(const [Violation(ViolationCode.schemaMismatch)]);
    }
    final next = {...attributes};
    changes.forEach((key, value) {
      if (value == null) {
        next.remove(key);
      } else {
        next[key] = value;
      }
    });
    return _validated(
      schema,
      next,
      (valid) => DynamicEntry._(
        id: id,
        schemaId: schemaId,
        attributes: valid,
        audit: audit.touchedAt(at),
      ),
    );
  }

  /// Re-homes this entry onto [target] with already-migrated [attributes].
  @internal
  Validated<DynamicEntry> migratedTo(
    SchemaDefinition target,
    Map<FieldKey, FieldValue> attributes,
    DateTime at,
  ) => _validated(
    target,
    attributes,
    (valid) => DynamicEntry._(
      id: id,
      schemaId: target.id,
      attributes: valid,
      audit: audit.touchedAt(at),
    ),
  );

  static Validated<DynamicEntry> _validated(
    SchemaDefinition schema,
    Map<FieldKey, FieldValue> attributes,
    DynamicEntry Function(Map<FieldKey, FieldValue>) build,
  ) {
    final violations = [
      for (final key in attributes.keys)
        if (schema.fieldFor(key) == null)
          Violation(ViolationCode.unknownField, key),
      for (final field in schema.fields)
        ...switch (attributes[field.key]) {
          null when field.required => [
            Violation(ViolationCode.missingRequired, field.key),
          ],
          null => const <Violation>[],
          final value => [
            for (final code in field.type.check(value))
              Violation(code, field.key),
          ],
        },
    ];
    return violations.isEmpty ? Valid(build(attributes)) : Invalid(violations);
  }
}
