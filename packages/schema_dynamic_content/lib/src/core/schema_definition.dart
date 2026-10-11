import 'package:meta/meta.dart';

import 'field_type.dart';
import 'identifiers.dart';
import 'label.dart';
import 'list_equality.dart';
import 'schema_exception.dart';

@immutable
final class FieldDefinition {
  const FieldDefinition({
    required this.key,
    required this.label,
    required this.type,
    this.required = false,
  });

  final FieldKey key;
  final Label label;
  final FieldType type;
  final bool required;

  FieldDefinition renamed(FieldKey newKey) => FieldDefinition(
    key: newKey,
    label: label,
    type: type,
    required: required,
  );

  @override
  bool operator ==(Object other) =>
      other is FieldDefinition &&
      other.key == key &&
      other.label == label &&
      other.type == type &&
      other.required == required;

  @override
  int get hashCode => Object.hash(key, label, type, required);
}

/// Where the renderer places a field; purely presentational.
@immutable
final class WidgetPlacement {
  WidgetPlacement({
    required this.field,
    required this.section,
    required this.order,
  }) {
    if (!_section.hasMatch(section) || order < 0) {
      throw const InvalidSchemaException(SchemaInvariant.invalidIdentifier);
    }
  }

  static final _section = RegExp(r'^[a-z][a-z0-9_]{0,31}$');

  final FieldKey field;
  final String section;
  final int order;

  @override
  bool operator ==(Object other) =>
      other is WidgetPlacement &&
      other.field == field &&
      other.section == section &&
      other.order == order;

  @override
  int get hashCode => Object.hash(field, section, order);
}

/// The meta-model of a note type, interpreted at runtime. Every instance
/// satisfies its invariants; there is no way to hold a half-valid schema.
@immutable
final class SchemaDefinition {
  SchemaDefinition({
    required this.id,
    required this.label,
    required List<FieldDefinition> fields,
    List<WidgetPlacement> uiHints = const [],
  }) : fields = List.unmodifiable(fields),
       uiHints = List.unmodifiable(uiHints),
       _byKey = {for (final f in fields) f.key: f} {
    if (fields.isEmpty) {
      throw const InvalidSchemaException(SchemaInvariant.noFields);
    }
    if (fields.length > maxFields) {
      throw const InvalidSchemaException(SchemaInvariant.tooManyFields);
    }
    if (_byKey.length != fields.length) {
      throw const InvalidSchemaException(SchemaInvariant.duplicateFieldKey);
    }
    if (uiHints.any((hint) => !_byKey.containsKey(hint.field))) {
      throw const InvalidSchemaException(SchemaInvariant.hintForUnknownField);
    }
  }

  static const maxFields = 64;

  final SchemaId id;
  final Label label;
  final List<FieldDefinition> fields;
  final List<WidgetPlacement> uiHints;
  final Map<FieldKey, FieldDefinition> _byKey;

  FieldDefinition? fieldFor(FieldKey key) => _byKey[key];

  @override
  bool operator ==(Object other) =>
      other is SchemaDefinition &&
      other.id == id &&
      other.label == label &&
      listEquals(other.fields, fields) &&
      listEquals(other.uiHints, uiHints);

  @override
  int get hashCode =>
      Object.hash(id, label, Object.hashAll(fields), Object.hashAll(uiHints));
}
