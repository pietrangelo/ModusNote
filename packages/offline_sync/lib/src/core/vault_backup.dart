import 'dart:typed_data';

import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:meta/meta.dart';

import 'record_revision.dart';
import 'sync_exception.dart';
import 'wire.dart';

/// A vault's records as a file kept outside the app, sealed under a
/// passphrase of its own, so it opens in any vault, of any workspace.
///
/// Wire: `"MNBK" | version(1) | salt(16) | opsLimit(u32) | memLimit(u32) |
/// sealed(blob)`. Every clear field is bound into the associated data, so
/// a file with weaker costs or another salt does not open.
@immutable
final class SealedBackup {
  const SealedBackup({
    required this.salt,
    required this.kdf,
    required this.sealed,
  });

  /// Throws [MalformedSyncDataException], before any Argon2id runs, for a
  /// file that is not a backup or asks for costs out of bounds.
  factory SealedBackup.parse(List<int> wire) {
    final reader = WireReader(wire);
    if (!_sameBytes(reader.bytes(_magic.length), _magic) ||
        reader.uint8() != _version) {
      throw const MalformedSyncDataException('not a backup');
    }
    final salt = Salt.fromBytes(reader.bytes(Salt.length));
    final KdfParameters kdf;
    try {
      kdf = KdfParameters.custom(
        opsLimit: reader.uint32(),
        memLimitBytes: reader.uint32(),
      );
    } on CryptographyException {
      throw const MalformedSyncDataException('backup KDF out of bounds');
    }
    final EncryptedEnvelope sealed;
    try {
      sealed = EncryptedEnvelope.parse(reader.blob());
    } on CryptographyException {
      throw const MalformedSyncDataException('malformed sealed backup');
    }
    reader.finish();
    return SealedBackup(salt: salt, kdf: kdf, sealed: sealed);
  }

  /// Builds a backup whose contents are sealed by [seal] under the slot
  /// that binds its clear fields.
  factory SealedBackup.sealing({
    required Salt salt,
    required KdfParameters kdf,
    required EncryptedEnvelope Function(AssociatedData slot) seal,
  }) => SealedBackup(salt: salt, kdf: kdf, sealed: seal(slotFor(salt, kdf)));

  static const _version = 1;
  static final _magic = Uint8List.fromList('MNBK'.codeUnits);

  final Salt salt;
  final KdfParameters kdf;
  final EncryptedEnvelope sealed;

  AssociatedData get slot => slotFor(salt, kdf);

  static AssociatedData slotFor(Salt salt, KdfParameters kdf) =>
      AssociatedData.forContext(
        'modusnote.backup.v1',
        _hex(_clearFields(salt, kdf).take()),
      );

  Uint8List toBytes() =>
      (_clearFields(salt, kdf)..blob(sealed.toBytes())).take();

  static WireWriter _clearFields(Salt salt, KdfParameters kdf) => WireWriter()
    ..bytes(_magic)
    ..uint8(_version)
    ..bytes(salt.bytes)
    ..uint32(kdf.opsLimit)
    ..uint32(kdf.memLimitBytes);

  static String _hex(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// What a backup holds: the contents of every live record, by id, opaque
/// here as in the vault.
///
/// Wire: `version(1) | count(u32) | (id(16) | contents(blob))*`.
@immutable
final class BackupContents {
  BackupContents(Map<RecordId, List<int>> records)
    : records = Map.unmodifiable(records);

  /// Throws [MalformedSyncDataException] for anything but one entry per
  /// record, up to [maxRecords].
  factory BackupContents.parse(List<int> wire) {
    final reader = WireReader(wire);
    if (reader.uint8() != _version) {
      throw const MalformedSyncDataException('unsupported backup version');
    }
    final count = reader.uint32();
    if (count > maxRecords) {
      throw const MalformedSyncDataException('too many records in backup');
    }
    final records = <RecordId, List<int>>{};
    for (var i = 0; i < count; i++) {
      final id = RecordId.parse(_hex(reader.bytes(RecordId.length)));
      if (records.containsKey(id)) {
        throw const MalformedSyncDataException('record listed twice');
      }
      records[id] = reader.blob();
    }
    reader.finish();
    return BackupContents(records);
  }

  static const _version = 1;
  static const maxRecords = 1000000;

  final Map<RecordId, List<int>> records;

  Uint8List toBytes() {
    final writer = WireWriter()
      ..uint8(_version)
      ..uint32(records.length);
    for (final MapEntry(:key, :value) in records.entries) {
      writer
        ..bytes(_bytesOf(key.hex))
        ..blob(value);
    }
    return writer.take();
  }

  static Uint8List _bytesOf(String hex) => Uint8List.fromList([
    for (var i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ]);

  static String _hex(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
