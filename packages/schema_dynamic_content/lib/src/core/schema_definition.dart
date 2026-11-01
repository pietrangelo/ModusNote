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

/// The symbol that tells a note type apart at a glance. Names, not
/// pictures: the app draws each one, and a name it does not know (from a
/// newer device) is simply not shown.
enum NoteIcon {
  note,
  music,
  moon,
  checklist,
  star,
  lightbulb,
  book,
  heart,
  page,
  bookmark,
  person,
  place,
  key,
  calendar,
  recipe,
}

/// The accent colour of a note type, as a palette role the app maps to
/// its design tokens.
enum NoteTint { gold, violet, cyan, rose, silver, sage }

/// The meta-model of a note type, interpreted at runtime. Every instance
/// satisfies its invariants; there is no way to hold a half-valid schema.
@immutable
final class SchemaDefinition {
  SchemaDefinition({
    required this.id,
    required this.label,
    required List<FieldDefinition> fields,
    List<WidgetPlacement> uiHints = const [],
    this.icon,
    this.tint,
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
  final NoteIcon? icon;
  final NoteTint? tint;
  final Map<FieldKey, FieldDefinition> _byKey;

  FieldDefinition? fieldFor(FieldKey key) => _byKey[key];

  /// The field that names or holds the note: the first text-like one.
  FieldDefinition? get primaryTextField {
    for (final field in fields) {
      if (field.type
          case TextFieldType() || RichTextFieldType() || MarkdownFieldType()) {
        return field;
      }
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is SchemaDefinition &&
      other.id == id &&
      other.label == label &&
      listEquals(other.fields, fields) &&
      listEquals(other.uiHints, uiHints) &&
      other.icon == icon &&
      other.tint == tint;

  @override
  int get hashCode => Object.hash(
    id,
    label,
    Object.hashAll(fields),
    Object.hashAll(uiHints),
    icon,
    tint,
  );
}
