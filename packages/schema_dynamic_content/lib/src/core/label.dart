import 'package:meta/meta.dart';

import 'schema_exception.dart';

/// What the UI shows for a schema or field.
///
/// Seed schemas never carry display text: they carry a localization key the
/// app resolves, so the domain stays language-neutral.
@immutable
sealed class Label {
  const Label();

  factory Label.localized(String key) = LocalizedLabel;
  factory Label.literal(String text) = LiteralLabel;
}

final class LocalizedLabel extends Label {
  LocalizedLabel(this.key) {
    if (!_key.hasMatch(key)) {
      throw InvalidSchemaException(SchemaInvariant.invalidLabel, key);
    }
  }

  static final _key = RegExp(r'^[a-z][a-z0-9_]*(\.[a-z0-9_]+)+$');

  final String key;

  @override
  bool operator ==(Object other) => other is LocalizedLabel && other.key == key;

  @override
  int get hashCode => key.hashCode;
}

/// A label typed by the user for a schema they created, shown as is.
final class LiteralLabel extends Label {
  LiteralLabel(String text) : text = text.trim() {
    if (this.text.isEmpty || this.text.length > maxLength) {
      throw const InvalidSchemaException(SchemaInvariant.invalidLabel);
    }
  }

  static const maxLength = 120;

  final String text;

  @override
  bool operator ==(Object other) => other is LiteralLabel && other.text == text;

  @override
  int get hashCode => text.hashCode;
}
