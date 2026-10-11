import 'package:meta/meta.dart';

import 'dynamic_entry.dart';
import 'field_value.dart';
import 'identifiers.dart';
import 'schema_definition.dart';
import 'schema_exception.dart';
import 'violation.dart';

@immutable
sealed class MigrationStep {
  const MigrationStep();
}

final class AddField extends MigrationStep {
  const AddField(this.field, {this.defaultValue});

  final FieldDefinition field;

  /// Written into every migrated entry; mandatory when [field] is required,
  /// so existing entries stay valid.
  final FieldValue? defaultValue;
}

final class RemoveField extends MigrationStep {
  const RemoveField(this.key);

  final FieldKey key;
}

final class RenameField extends MigrationStep {
  const RenameField({required this.from, required this.to});

  final FieldKey from;
  final FieldKey to;
}

/// Adds [field] with a value computed from the entry's attributes as they
/// stand at this step, for changes no rename can express (a text and a
/// flag becoming a list of tasks). [derive] returning null leaves the
/// field empty, which leaves the entry invalid if [field] is required.
final class DeriveField extends MigrationStep {
  const DeriveField(this.field, this.derive);

  final FieldDefinition field;
  final FieldValue? Function(Map<FieldKey, FieldValue> attributes) derive;
}

/// Turns version N of a schema into version N+1 and carries entries along.
///
/// The steps are checked against the source schema when the migration is
/// built, so a migration that would strand entries cannot be constructed.
@immutable
final class SchemaMigration {
  factory SchemaMigration({
    required SchemaDefinition from,
    required List<MigrationStep> steps,
    List<WidgetPlacement>? uiHints,
  }) {
    var fields = [...from.fields];
    var hints = [...from.uiHints];

    bool has(FieldKey key) => fields.any((f) => f.key == key);
    void requireField(FieldKey key) {
      if (!has(key)) {
        throw InvalidSchemaException(
          SchemaInvariant.unknownMigrationTarget,
          key.value,
        );
      }
    }

    for (final step in steps) {
      switch (step) {
        case AddField(:final field, :final defaultValue):
          if (field.required && defaultValue == null) {
            throw const InvalidSchemaException(
              SchemaInvariant.requiredFieldWithoutDefault,
            );
          }
          if (defaultValue != null &&
              field.type.check(defaultValue).isNotEmpty) {
            throw const InvalidSchemaException(SchemaInvariant.invalidDefault);
          }
          fields = [...fields, field];
        case DeriveField(:final field):
          if (has(field.key)) {
            throw const InvalidSchemaException(
              SchemaInvariant.duplicateFieldKey,
            );
          }
          fields = [...fields, field];
        case RemoveField(:final key):
          requireField(key);
          fields = [
            for (final f in fields)
              if (f.key != key) f,
          ];
          hints = [
            for (final h in hints)
              if (h.field != key) h,
          ];
        case RenameField(:final from, :final to):
          requireField(from);
          if (has(to)) {
            throw const InvalidSchemaException(
              SchemaInvariant.duplicateFieldKey,
            );
          }
          fields = [for (final f in fields) f.key == from ? f.renamed(to) : f];
          hints = [
            for (final h in hints)
              h.field == from
                  ? WidgetPlacement(
                      field: to,
                      section: h.section,
                      order: h.order,
                    )
                  : h,
          ];
      }
    }

    return SchemaMigration._(
      from,
      SchemaDefinition(
        id: from.id.next,
        label: from.label,
        fields: fields,
        uiHints: uiHints ?? hints,
        icon: from.icon,
        tint: from.tint,
      ),
      List.unmodifiable(steps),
    );
  }

  const SchemaMigration._(this.source, this.target, this.steps);

  final SchemaDefinition source;
  final SchemaDefinition target;
  final List<MigrationStep> steps;

  Validated<DynamicEntry> migrate(DynamicEntry entry, {required DateTime at}) {
    if (entry.schemaId != source.id) {
      return Invalid(const [Violation(ViolationCode.schemaMismatch)]);
    }
    return entry.migratedTo(target, _attributes(entry), at);
  }

  /// [entry] read as the target version, with its audit trail untouched:
  /// a view for display and editing, written under the new version only
  /// when the user next saves it. Old notes are not rewritten on every
  /// device that happens to open them.
  Validated<DynamicEntry> upgrade(DynamicEntry entry) {
    if (entry.schemaId != source.id) {
      return Invalid(const [Violation(ViolationCode.schemaMismatch)]);
    }
    return entry.migratedTo(target, _attributes(entry), null);
  }

  Map<FieldKey, FieldValue> _attributes(DynamicEntry entry) {
    final attributes = {...entry.attributes};
    for (final step in steps) {
      switch (step) {
        case AddField(:final field, :final defaultValue?):
          attributes[field.key] = defaultValue;
        case AddField():
          break;
        case RemoveField(:final key):
          attributes.remove(key);
        case DeriveField(:final field, :final derive):
          if (derive(Map.unmodifiable(attributes)) case final value?) {
            attributes[field.key] = value;
          }
        case RenameField(:final from, :final to):
          final value = attributes.remove(from);
          if (value != null) attributes[to] = value;
      }
    }
    return attributes;
  }
}
