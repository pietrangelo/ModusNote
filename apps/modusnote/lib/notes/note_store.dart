import 'package:flutter/foundation.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

/// Where the UI reads and writes notes. The screens see only decrypted
/// entries; the encrypted vault (SyncEngine on SQLite) replaces the
/// in-memory store once the unlock flow exists.
abstract interface class NoteStore implements Listenable {
  /// Most recently changed first.
  List<DynamicEntry> get entries;

  Future<void> save(DynamicEntry entry);
}

final class InMemoryNoteStore extends ChangeNotifier implements NoteStore {
  final _entries = <EntryId, DynamicEntry>{};

  @override
  List<DynamicEntry> get entries =>
      _entries.values.toList()
        ..sort((a, b) => b.audit.updatedAt.compareTo(a.audit.updatedAt));

  @override
  Future<void> save(DynamicEntry entry) async {
    _entries[entry.id] = entry;
    notifyListeners();
  }
}
