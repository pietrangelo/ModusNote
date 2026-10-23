import 'dart:typed_data';

import 'package:collaboration_access_control/collaboration_access_control.dart';
import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:offline_sync/offline_sync.dart';
import 'package:sqlite3/common.dart';

import 'local_schema.dart';

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
    migrateLocalDatabase(_database);
  }

  static const schemaVersion = localSchemaVersion;

  final CommonDatabase _database;
  final String _workspace;

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
  Future<Map<RecordId, EncryptedEnvelope>> loadAll() async => {
    for (final row in _database.select(
      'SELECT record, envelope FROM records WHERE workspace = ?',
      [_workspace],
    ))
      RecordId.parse(row['record'] as String): EncryptedEnvelope.parse(
        row['envelope'] as Uint8List,
      ),
  };

  @override
  Future<void> save(RecordId id, EncryptedEnvelope sealed) async =>
      _database.execute(
        'INSERT OR REPLACE INTO records (workspace, record, envelope) '
        'VALUES (?, ?, ?)',
        [_workspace, id.hex, sealed.toBytes()],
      );

  @override
  Future<Outbox> loadOutbox() async => Outbox.of([
    for (final row in _database.select(
      'SELECT record, epoch, envelope, supersedes FROM outbox '
      'WHERE workspace = ? ORDER BY position',
      [_workspace],
    ))
      _sealedRow(
        row['record'] as String,
        row['epoch'] as int,
        row['envelope'] as Uint8List,
        row['supersedes'] as int,
      ),
  ]);

  @override
  Future<void> queue(SealedRow row) async {
    final values = [
      row.ciphertext.epoch.value,
      row.ciphertext.envelope.toBytes(),
      row.supersedes,
    ];
    _transaction(() {
      // shortcut: scans the workspace's queued rows, no index on record;
      // add one (schema v6) if outboxes ever grow to thousands of rows.
      _database.execute(
        'UPDATE outbox SET epoch = ?, envelope = ?, supersedes = ? '
        'WHERE workspace = ? AND record = ?',
        [...values, _workspace, row.record.hex],
      );
      if (_database.updatedRows > 0) return;
      _database.execute(
        'INSERT INTO outbox '
        '(workspace, position, record, epoch, envelope, supersedes) '
        'SELECT ?, coalesce(max(position) + 1, 0), ?, ?, ?, ? '
        'FROM outbox WHERE workspace = ?',
        [_workspace, row.record.hex, ...values, _workspace],
      );
    });
  }

  @override
  Future<void> unqueue(Iterable<SealedRow> pushed) async {
    _transaction(() {
      final delete = _database.prepare(
        'DELETE FROM outbox WHERE workspace = ? AND record = ? '
        'AND epoch = ? AND envelope = ? AND supersedes = ?',
      );
      try {
        for (final row in pushed) {
          delete.execute([
            _workspace,
            row.record.hex,
            row.ciphertext.epoch.value,
            row.ciphertext.envelope.toBytes(),
            row.supersedes,
          ]);
        }
      } finally {
        delete.close();
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

  @override
  Future<int?> loadUnreadable(RecordId id) async {
    final rows = _database.select(
      'SELECT position FROM unreadable_rows WHERE workspace = ? AND record = ?',
      [_workspace, id.hex],
    );
    return rows.isEmpty ? null : rows.single['position'] as int;
  }

  @override
  Future<void> markUnreadable(RecordId id, int position) async =>
      _database.execute(
        'INSERT INTO unreadable_rows (workspace, record, position) '
        'VALUES (?, ?, ?) ON CONFLICT (workspace, record) '
        'DO UPDATE SET position = min(position, excluded.position)',
        [_workspace, id.hex, position],
      );

  @override
  Future<void> forgetServer() async => _transaction(() {
    for (final table in ['cursors', 'unreadable_rows']) {
      _database.execute('DELETE FROM $table WHERE workspace = ?', [_workspace]);
    }
  });

  void _transaction(void Function() body) => transaction(_database, body);

  static SealedRow _sealedRow(
    String record,
    int epoch,
    Uint8List envelope,
    int supersedes,
  ) {
    try {
      return SealedRow(
        record: RecordId.parse(record),
        ciphertext: WorkspaceCiphertext(
          epoch: KeyEpoch(epoch),
          envelope: EncryptedEnvelope.parse(envelope),
        ),
        supersedes: supersedes,
      );
    } on CollaborationException {
      throw const MalformedSyncDataException('corrupted outbox row');
    } on CryptographyException {
      throw const MalformedSyncDataException('corrupted outbox row');
    }
  }
}
