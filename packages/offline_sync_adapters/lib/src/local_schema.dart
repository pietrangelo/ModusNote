import 'package:sqlite3/common.dart';

/// The local database file was written by a newer version of the app.
final class UnsupportedLocalSchemaException implements Exception {
  const UnsupportedLocalSchemaException();

  @override
  String toString() => 'UnsupportedLocalSchemaException';
}

const localSchemaVersion = 3;

/// One schema for the whole device database, shared by every store that
/// opens it, so their migrations cannot race on `user_version`.
void migrateLocalDatabase(CommonDatabase database) {
  final version = database.userVersion;
  if (version > localSchemaVersion) {
    throw const UnsupportedLocalSchemaException();
  }
  // Freed pages are zeroed, so an overwritten envelope or outbox row does
  // not linger in the file.
  database.execute('PRAGMA secure_delete = ON');
  if (version == localSchemaVersion) return;
  transaction(database, () {
    if (version < 1) database.execute(_records);
    if (version < 2) database.execute(_vault);
    if (version < 3) database.execute(_passkey);
    database.execute('PRAGMA user_version = $localSchemaVersion');
  });
}

void transaction(CommonDatabase database, void Function() body) {
  database.execute('BEGIN');
  try {
    body();
    database.execute('COMMIT');
  } on Object {
    database.execute('ROLLBACK');
    rethrow;
  }
}

const _records = '''
  CREATE TABLE records (
    workspace TEXT NOT NULL,
    record TEXT NOT NULL,
    envelope BLOB NOT NULL,
    PRIMARY KEY (workspace, record)
  ) WITHOUT ROWID;
  CREATE TABLE outbox (
    workspace TEXT NOT NULL,
    position INTEGER NOT NULL,
    record TEXT NOT NULL,
    epoch INTEGER NOT NULL,
    envelope BLOB NOT NULL,
    PRIMARY KEY (workspace, position)
  ) WITHOUT ROWID;
  CREATE TABLE cursors (
    workspace TEXT NOT NULL,
    stream TEXT NOT NULL,
    position INTEGER NOT NULL,
    PRIMARY KEY (workspace, stream)
  ) WITHOUT ROWID;
''';

const _vault = '''
  CREATE TABLE vault (
    slot INTEGER PRIMARY KEY CHECK (slot = 0),
    header BLOB NOT NULL
  );
  CREATE TABLE vault_membership (
    sequence INTEGER PRIMARY KEY,
    record BLOB NOT NULL
  );
  CREATE TABLE vault_key_bundles (
    position INTEGER PRIMARY KEY,
    bundle BLOB NOT NULL
  );
''';

const _passkey = '''
  CREATE TABLE vault_passkey (
    slot INTEGER PRIMARY KEY CHECK (slot = 0),
    passkey BLOB NOT NULL
  );
''';
