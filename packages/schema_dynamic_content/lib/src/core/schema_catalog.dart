import 'package:meta/meta.dart';

import 'dynamic_entry.dart';
import 'identifiers.dart';
import 'schema_definition.dart';
import 'schema_migration.dart';
import 'violation.dart';

/// Every version of every note type a device can read, and how to bring
/// an entry of an old version up to the current one.
@immutable
final class SchemaCatalog {
  SchemaCatalog({
    required List<SchemaDefinition> current,
    List<SchemaMigration> migrations = const [],
  }) : current = List.unmodifiable(current),
       _migrations = {for (final m in migrations) m.source.id: m},
       _schemas = {
         for (final m in migrations) m.source.id: m.source,
         for (final s in current) s.id: s,
       };

  /// The versions new notes are written in.
  final List<SchemaDefinition> current;
  final Map<SchemaId, SchemaMigration> _migrations;
  final Map<SchemaId, SchemaDefinition> _schemas;

  /// The schema an entry names, current or old; null when unknown.
  SchemaDefinition? schemaFor(SchemaId id) => _schemas[id];

  /// [entry] as the current version of its type, the same instance when
  /// it already is, or null when no chain of migrations reaches a current
  /// version or a step leaves it invalid.
  DynamicEntry? upgrade(DynamicEntry entry) {
    var at = entry;
    // Each step raises the version, so the chain ends; the bound guards
    // against a catalog built with a cycle anyway.
    for (var steps = 0; steps <= _migrations.length; steps++) {
      if (current.any((schema) => schema.id == at.schemaId)) return at;
      final migration = _migrations[at.schemaId];
      if (migration == null) return null;
      switch (migration.upgrade(at)) {
        case Valid(:final value):
          at = value;
        case Invalid():
          return null;
      }
    }
    return null;
  }
}
