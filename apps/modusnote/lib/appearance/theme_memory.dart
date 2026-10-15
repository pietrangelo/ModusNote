import 'package:sqlite3/common.dart';

import '../theme/modus_themes.dart';

/// Where the device remembers its theme, in clear: the unlock screen
/// shows it before any vault is open. Only the theme's name; how the page
/// looks stays sealed in each vault.
abstract interface class ThemeMemory {
  /// The theme last chosen; null when none was, or it is unknown (from a
  /// newer app) or unreadable.
  AppTheme? load();

  Future<void> save(AppTheme theme);
}

/// [ThemeMemory] in a table of the shelf's database, which is also read
/// before any vault is unlocked.
final class SqliteThemeMemory implements ThemeMemory {
  SqliteThemeMemory(this._database) {
    _database.execute('''
      CREATE TABLE IF NOT EXISTS device_appearance (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      ) STRICT
    ''');
  }

  final CommonDatabase _database;

  @override
  AppTheme? load() {
    try {
      final rows = _database.select(
        "SELECT value FROM device_appearance WHERE key = 'theme'",
      );
      if (rows.isEmpty) return null;
      final name = rows.single['value'];
      return AppTheme.values.where((theme) => theme.name == name).firstOrNull;
    } on SqliteException {
      return null;
    }
  }

  @override
  Future<void> save(AppTheme theme) async {
    _database.execute(
      "INSERT OR REPLACE INTO device_appearance (key, value) "
      "VALUES ('theme', ?)",
      [theme.name],
    );
  }
}
