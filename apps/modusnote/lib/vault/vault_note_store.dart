import 'package:flutter/foundation.dart';
import 'package:offline_sync/offline_sync.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import '../notes/note_store.dart';

/// [NoteStore] on the unlocked vault: each note is an [EntryCodec] document
/// signed and sealed by the [SyncEngine], one record per note.
///
/// Decrypted notes live only in this object's memory while the vault is
/// open; the screens never see a record that fails to decode or validate.
final class VaultNoteStore extends ChangeNotifier implements NoteStore {
  VaultNoteStore._(this._engine, this._schemas);

  static Future<VaultNoteStore> open(
    SyncEngine engine, {
    required List<SchemaDefinition> schemas,
  }) async {
    final store = VaultNoteStore._(engine, schemas);
    await store._load();
    return store;
  }

  final SyncEngine _engine;
  final List<SchemaDefinition> _schemas;
  final _entries = <EntryId, DynamicEntry>{};
  var _unreadable = 0;

  /// Records that are not a valid note of a known schema: kept in the vault
  /// (a newer app may read them) but not shown.
  int get unreadable => _unreadable;

  @override
  List<DynamicEntry> get entries =>
      _entries.values.toList()
        ..sort((a, b) => b.audit.updatedAt.compareTo(a.audit.updatedAt));

  @override
  Future<void> save(DynamicEntry entry) async {
    await _engine.write(
      _recordOf(entry.id),
      RevisionContents(EntryCodec.encode(entry)),
    );
    _entries[entry.id] = entry;
    notifyListeners();
  }

  Future<void> _load() async {
    for (final MapEntry(key: record, value: contents)
        in (await _engine.records()).entries) {
      final entry = _decode(contents.bytes);
      // The id inside the note must name the record it is stored in, so a
      // note's bytes copied onto another record cannot surface twice.
      if (entry == null || entry.id.value != record.hex) {
        _unreadable++;
      } else {
        _entries[entry.id] = entry;
      }
    }
  }

  DynamicEntry? _decode(List<int> bytes) {
    try {
      return switch (EntryCodec.decode(bytes, schemas: _schemaFor)) {
        Valid(:final value) => value,
        Invalid() => null,
      };
    } on EntryFormatException {
      return null;
    }
  }

  SchemaDefinition? _schemaFor(SchemaId id) {
    for (final schema in _schemas) {
      if (schema.id == id) return schema;
    }
    return null;
  }

  static RecordId _recordOf(EntryId id) {
    try {
      return RecordId.parse(id.value);
    } on MalformedSyncDataException {
      throw ArgumentError.value(id.value, 'id', 'not a record id');
    }
  }
}
