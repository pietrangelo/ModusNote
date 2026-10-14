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
  Future<List<RecordId>> recordIds() async => [
    for (final row in _database.select(
      'SELECT record FROM records WHERE workspace = ?',
      [_workspace],
    ))
      RecordId.parse(row['record'] as String),
  ];

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
      'SELECT record, epoch, envelope, supersedes FROM outbox '
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
          row['supersedes'] as int,
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
        'INSERT INTO outbox '
        '(workspace, position, record, epoch, envelope, supersedes) '
        'VALUES (?, ?, ?, ?, ?, ?)',
      );
      try {
        for (final (position, row) in outbox.pending.indexed) {
          insert.execute([
            _workspace,
            position,
            row.record.hex,
            row.ciphertext.epoch.value,
            row.ciphertext.envelope.toBytes(),
            row.supersedes,
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
