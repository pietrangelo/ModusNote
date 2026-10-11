import 'package:meta/meta.dart';

import 'schema_exception.dart';

final _snakeCase = RegExp(r'^[a-z][a-z0-9_]{0,63}$');
final _schemaName = RegExp(r'^[a-z0-9][a-z0-9_-]{0,63}$');
final _opaqueId = RegExp(r'^[A-Za-z0-9_-]{1,128}$');

String _checked(RegExp pattern, String value, String what) {
  if (!pattern.hasMatch(value)) {
    throw InvalidSchemaException(SchemaInvariant.invalidIdentifier, what);
  }
  return value;
}

@immutable
final class FieldKey {
  FieldKey(String value) : value = _checked(_snakeCase, value, 'FieldKey');

  final String value;

  @override
  bool operator ==(Object other) => other is FieldKey && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// Identifies a schema across versions: seed schemas use a slug
/// (`song_sketch`), user-created ones a lowercase UUID.
@immutable
final class SchemaId {
  SchemaId(String name, this.version)
    : name = _checked(_schemaName, name, 'SchemaId') {
    if (version < 1) {
      throw const InvalidSchemaException(SchemaInvariant.invalidVersion);
    }
  }

  final String name;
  final int version;

  SchemaId get next => SchemaId(name, version + 1);

  @override
  bool operator ==(Object other) =>
      other is SchemaId && other.name == name && other.version == version;

  @override
  int get hashCode => Object.hash(name, version);

  @override
  String toString() => '${name}_v$version';
}

@immutable
final class EntryId {
  EntryId(String value) : value = _checked(_opaqueId, value, 'EntryId');

  final String value;

  @override
  bool operator ==(Object other) => other is EntryId && other.value == value;

  @override
  int get hashCode => value.hashCode;
}

/// Reference to an encrypted blob owned by the Blob Storage & Media context.
@immutable
final class BlobId {
  BlobId(String value) : value = _checked(_opaqueId, value, 'BlobId');

  final String value;

  @override
  bool operator ==(Object other) => other is BlobId && other.value == value;

  @override
  int get hashCode => value.hashCode;
}
