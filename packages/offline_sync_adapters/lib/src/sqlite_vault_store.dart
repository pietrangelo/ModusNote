import 'dart:typed_data';

import 'package:collaboration_access_control/collaboration_access_control.dart';
import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:offline_sync/offline_sync.dart';
import 'package:sqlite3/common.dart';

import 'local_schema.dart';

/// [VaultStore] on the same SQLite file as the records.
///
/// The header is the only vault data in clear, and it holds nothing but
/// the salt, KDF costs, opaque ids and the sealed identity; the log and
/// bundles are signed, and are re-verified every time the vault opens. The
/// passkey slot, when there is one, adds only the passkey's id, its PRF
/// salt and the same secrets sealed again.
final class SqliteVaultStore implements VaultStore {
  SqliteVaultStore(this._database) {
    migrateLocalDatabase(_database);
  }

  final CommonDatabase _database;

  @override
  Future<VaultHeader?> loadHeader() async {
    final rows = _database.select('SELECT header FROM vault WHERE slot = 0');
    if (rows.isEmpty) return null;
    return VaultHeader.parse(rows.single['header'] as Uint8List);
  }

  @override
  Future<void> create(
    VaultHeader header, {
    required List<MembershipRecord> membership,
    required List<KeyBundle> bundles,
  }) async {
    if (await loadHeader() != null) throw const VaultAlreadyExistsException();
    transaction(_database, () {
      _database.execute('INSERT INTO vault (slot, header) VALUES (0, ?)', [
        header.toBytes(),
      ]);
      for (final record in membership) {
        _database.execute(
          'INSERT INTO vault_membership (sequence, record) VALUES (?, ?)',
          [record.sequence, record.toBytes()],
        );
      }
      for (final (position, bundle) in bundles.indexed) {
        _database.execute(
          'INSERT INTO vault_key_bundles (position, bundle) VALUES (?, ?)',
          [position, bundle.toBytes()],
        );
      }
    });
  }

  @override
  Future<List<MembershipRecord>> loadMembership() async => [
    for (final row in _database.select(
      'SELECT record FROM vault_membership ORDER BY sequence',
    ))
      _parse(() => MembershipRecord.parse(row['record'] as Uint8List)),
  ];

  @override
  Future<List<KeyBundle>> loadKeyBundles() async => [
    for (final row in _database.select(
      'SELECT bundle FROM vault_key_bundles ORDER BY position',
    ))
      _parse(() => KeyBundle.parse(row['bundle'] as Uint8List)),
  ];

  @override
  Future<PasskeySlot?> loadPasskey() async {
    final rows = _database.select(
      'SELECT passkey FROM vault_passkey WHERE slot = 0',
    );
    if (rows.isEmpty) return null;
    return PasskeySlot.parse(rows.single['passkey'] as Uint8List);
  }

  @override
  Future<void> savePasskey(PasskeySlot slot) async {
    if (await loadHeader() == null) throw const NoVaultException();
    _database.execute(
      'INSERT OR REPLACE INTO vault_passkey (slot, passkey) VALUES (0, ?)',
      [slot.toBytes()],
    );
  }

  @override
  Future<void> removePasskey() async {
    _database.execute('DELETE FROM vault_passkey');
  }

  @override
  Future<EncryptedEnvelope?> loadSetting(String name) async {
    final rows = _database.select(
      'SELECT envelope FROM vault_settings WHERE name = ?',
      [name],
    );
    if (rows.isEmpty) return null;
    return _parse(
      () => EncryptedEnvelope.parse(rows.single['envelope'] as Uint8List),
    );
  }

  @override
  Future<void> saveSetting(String name, EncryptedEnvelope? sealed) async {
    if (sealed == null) {
      _database.execute('DELETE FROM vault_settings WHERE name = ?', [name]);
    } else {
      _database.execute(
        'INSERT OR REPLACE INTO vault_settings (name, envelope) VALUES (?, ?)',
        [name, sealed.toBytes()],
      );
    }
  }

  static T _parse<T>(T Function() parse) {
    try {
      return parse();
    } on CollaborationException {
      throw const MalformedSyncDataException('corrupted vault log');
    } on CryptographyException {
      throw const MalformedSyncDataException('corrupted vault log');
    }
  }
}
