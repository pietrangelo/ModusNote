import 'dart:typed_data';

import 'package:collaboration_access_control/collaboration_access_control.dart';
import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:offline_sync/offline_sync.dart';
import 'package:sqlite3/common.dart';

/// The local database file was written by a newer version of the app.
final class UnsupportedLocalSchemaException implements Exception {
  const UnsupportedLocalSchemaException();

  @override
  String toString() => 'UnsupportedLocalSchemaException';
}

/// [LocalRecordStore] on SQLite, through the API shared by the native
/// library and the WASM build, so mobile and web run the same code.
///
/// The database holds only what the domain hands it: envelopes, sealed
/// outbox rows, opaque ids and cursors. No SQLCipher: there would be nothing
/// left in clear for it to protect but those ids, and its key would have to
/// travel as a `PRAGMA` string.
final class SqliteLocalRecordStore implements LocalRecordStore {
  SqliteLocalRecordStore(this._database, {required WorkspaceId workspace})
    : _workspace = workspace.hex {
    _migrate();
  }

  static const schemaVersion = 1;

  final CommonDatabase _database;
  final String _workspace;

  void _migrate() {
    final version = _database.userVersion;
    if (version > schemaVersion) throw const UnsupportedLocalSchemaException();
    // Freed pages are zeroed, so an overwritten envelope or outbox row does
    // not linger in the file.
    _database.execute('PRAGMA secure_delete = ON');
    if (version == schemaVersion) return;
    _database.execute('''
      BEGIN;
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
      PRAGMA user_version = $schemaVersion;
      COMMIT;
    ''');
  }

  @override
  Future<EncryptedEnvelope?> load(RecordId id) async {
    final rows = _database.select(
      'SELECT envelope FROM records WHERE workspace = ? AND record = ?',
      [_workspace, id.hex],
    );
    if (rows.isEmpty) return null;
    return EncryptedEnvelope.parse(rows.single['envelope'] as Uint8List);
  }

  @override
  Future<void> save(RecordId id, EncryptedEnvelope sealed) async =>
      _database.execute(
        'INSERT OR REPLACE INTO records (workspace, record, envelope) '
        'VALUES (?, ?, ?)',
        [_workspace, id.hex, sealed.toBytes()],
      );

  @override
  Future<Outbox> loadOutbox() async {
    final rows = _database.select(
      'SELECT record, epoch, envelope FROM outbox '
      'WHERE workspace = ? ORDER BY position',
      [_workspace],
    );
    var outbox = Outbox.empty;
    for (final row in rows) {
      outbox = outbox.enqueue(
        _sealedRow(
          row['record'] as String,
          row['epoch'] as int,
          row['envelope'] as Uint8List,
        ),
      );
    }
    return outbox;
  }

  @override
  Future<void> saveOutbox(Outbox outbox) async {
    _transaction(() {
      _database.execute('DELETE FROM outbox WHERE workspace = ?', [_workspace]);
      final insert = _database.prepare(
        'INSERT INTO outbox (workspace, position, record, epoch, envelope) '
        'VALUES (?, ?, ?, ?, ?)',
      );
      try {
        for (final (position, row) in outbox.pending.indexed) {
          insert.execute([
            _workspace,
            position,
            row.record.hex,
            row.ciphertext.epoch.value,
            row.ciphertext.envelope.toBytes(),
          ]);
        }
      } finally {
        insert.close();
      }
    });
  }

  @override
  Future<int> loadCursor(SyncStream stream) async {
    final rows = _database.select(
      'SELECT position FROM cursors WHERE workspace = ? AND stream = ?',
      [_workspace, stream.name],
    );
    return rows.isEmpty ? 0 : rows.single['position'] as int;
  }

  @override
  Future<void> saveCursor(SyncStream stream, int cursor) async =>
      _database.execute(
        'INSERT OR REPLACE INTO cursors (workspace, stream, position) '
        'VALUES (?, ?, ?)',
        [_workspace, stream.name, cursor],
      );

  void _transaction(void Function() body) {
    _database.execute('BEGIN');
    try {
      body();
      _database.execute('COMMIT');
    } on Object {
      _database.execute('ROLLBACK');
      rethrow;
    }
  }

  static SealedRow _sealedRow(String record, int epoch, Uint8List envelope) {
    try {
      return SealedRow(
        record: RecordId.parse(record),
        ciphertext: WorkspaceCiphertext(
          epoch: KeyEpoch(epoch),
          envelope: EncryptedEnvelope.parse(envelope),
        ),
      );
    } on CollaborationException {
      throw const MalformedSyncDataException('corrupted outbox row');
    } on CryptographyException {
      throw const MalformedSyncDataException('corrupted outbox row');
    }
  }
}
