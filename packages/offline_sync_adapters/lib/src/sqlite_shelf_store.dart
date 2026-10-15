import 'package:offline_sync/offline_sync.dart';
import 'package:sqlite3/common.dart';

import 'local_schema.dart';

/// [ShelfStore] in a small SQLite database of its own, beside the vaults'
/// databases: it is read before any of them is unlocked, so it holds only
/// what [VaultShelf] does, in clear.
final class SqliteShelfStore implements ShelfStore {
  SqliteShelfStore(this._database) {
    _database.execute('''
      CREATE TABLE IF NOT EXISTS shelf (
        position INTEGER PRIMARY KEY,
        id TEXT NOT NULL UNIQUE,
        label TEXT,
        scope INTEGER NOT NULL UNIQUE
      ) STRICT
    ''');
    _database.execute('''
      CREATE TABLE IF NOT EXISTS shelf_state (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      ) STRICT
    ''');
  }

  final CommonDatabase _database;

  @override
  Future<VaultShelf> load() async {
    final List<ShelfEntry> entries;
    final ShelfId? lastOpened;
    try {
      entries = [
        for (final row in _database.select(
          'SELECT id, label, scope FROM shelf ORDER BY position',
        ))
          ShelfEntry(
            id: ShelfId.parse(row['id'] as String),
            label: row['label'] as String?,
            scope: row['scope'] as int,
          ),
      ];
      final last = _database.select(
        "SELECT value FROM shelf_state WHERE key = 'last_opened'",
      );
      lastOpened = last.isEmpty
          ? null
          : ShelfId.parse(last.single['value'] as String);
    } on SyncException {
      return VaultShelf.initial();
    } on TypeError {
      return VaultShelf.initial();
    }
    return VaultShelf.restore(entries, lastOpened);
  }

  @override
  Future<void> save(VaultShelf shelf) async {
    transaction(_database, () {
      _database.execute('DELETE FROM shelf');
      for (final (position, entry) in shelf.entries.indexed) {
        _database.execute(
          'INSERT INTO shelf (position, id, label, scope) VALUES (?, ?, ?, ?)',
          [position, entry.id.value, entry.label, entry.scope],
        );
      }
      _database.execute(
        "INSERT OR REPLACE INTO shelf_state (key, value) "
        "VALUES ('last_opened', ?)",
        [shelf.lastOpened.value],
      );
    });
  }
}
