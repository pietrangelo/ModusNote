import 'dart:typed_data';

import 'package:collaboration_access_control/collaboration_access_control.dart';
import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:meta/meta.dart';

import 'sync_exception.dart';
import 'wire.dart';

/// What a device keeps in clear to reopen its vault: the Argon2id salt and
/// costs, the personal workspace with its pinned founder, the selector of
/// the device-local key, and the identity sealed under the MasterKey.
///
/// Every clear field is bound into the identity's associated data, so a
/// header edited on disk (a weaker KDF, another founder) no longer opens.
///
/// Wire: `version(1) | salt(16) | opsLimit(u32) | memLimit(u32) |
/// workspace(16) | founder(32) | localKeyId(8) | sealedIdentity(blob)`.
@immutable
final class VaultHeader {
  const VaultHeader({
    required this.salt,
    required this.kdf,
    required this.workspace,
    required this.founder,
    required this.localKeyId,
    required this.sealedIdentity,
  });

  /// Builds a header whose identity is sealed by [seal] under the slot that
  /// binds every other field, so the binding cannot be forgotten.
  factory VaultHeader.sealing({
    required Salt salt,
    required KdfParameters kdf,
    required WorkspaceId workspace,
    required MemberId founder,
    required SubkeyId localKeyId,
    required EncryptedEnvelope Function(AssociatedData slot) seal,
  }) {
    final unsealed = VaultHeader(
      salt: salt,
      kdf: kdf,
      workspace: workspace,
      founder: founder,
      localKeyId: localKeyId,
      sealedIdentity: _unsealed,
    );
    return VaultHeader(
      salt: salt,
      kdf: kdf,
      workspace: workspace,
      founder: founder,
      localKeyId: localKeyId,
      sealedIdentity: seal(unsealed.identitySlot),
    );
  }

  factory VaultHeader.parse(List<int> wire) {
    final reader = WireReader(wire);
    if (reader.uint8() != _version) {
      throw const MalformedSyncDataException('unsupported vault version');
    }
    final salt = Salt.fromBytes(reader.bytes(Salt.length));
    final KdfParameters kdf;
    try {
      kdf = KdfParameters.custom(
        opsLimit: reader.uint32(),
        memLimitBytes: reader.uint32(),
      );
    } on CryptographyException {
      throw const MalformedSyncDataException('vault KDF out of bounds');
    }
    final workspace = WorkspaceId.parse(_hex(reader.bytes(WorkspaceId.length)));
    final founder = MemberId(
      PublicSigningKey.fromBytes(reader.bytes(PublicSigningKey.length)),
    );
    final localKeyId = SubkeyId.fromBytes(reader.bytes(SubkeyId.length));
    final EncryptedEnvelope sealedIdentity;
    try {
      sealedIdentity = EncryptedEnvelope.parse(reader.blob());
    } on CryptographyException {
      throw const MalformedSyncDataException('malformed sealed identity');
    }
    reader.finish();
    return VaultHeader(
      salt: salt,
      kdf: kdf,
      workspace: workspace,
      founder: founder,
      localKeyId: localKeyId,
      sealedIdentity: sealedIdentity,
    );
  }

  static const _version = 1;
  static final _unsealed = EncryptedEnvelope(
    nonce: Nonce.fromBytes(Uint8List(Nonce.length)),
    ciphertext: Uint8List(EncryptedEnvelope.tagLength),
  );

  final Salt salt;
  final KdfParameters kdf;
  final WorkspaceId workspace;
  final MemberId founder;
  final SubkeyId localKeyId;
  final EncryptedEnvelope sealedIdentity;

  /// The associated data the identity is sealed under.
  AssociatedData get identitySlot => AssociatedData.forContext(
    'modusnote.vault.identity.v1',
    _hex(_clearFields().take()),
  );

  Uint8List toBytes() =>
      (_clearFields()..blob(sealedIdentity.toBytes())).take();

  WireWriter _clearFields() => WireWriter()
    ..uint8(_version)
    ..bytes(salt.bytes)
    ..uint32(kdf.opsLimit)
    ..uint32(kdf.memLimitBytes)
    ..bytes(workspace.bytes)
    ..bytes(founder.signingKey.bytes)
    ..bytes(localKeyId.bytes);

  static String _hex(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  @override
  bool operator ==(Object other) =>
      other is VaultHeader &&
      other.salt == salt &&
      other.kdf == kdf &&
      other.workspace == workspace &&
      other.founder == founder &&
      other.localKeyId == localKeyId &&
      other.sealedIdentity == sealedIdentity;

  @override
  int get hashCode =>
      Object.hash(salt, kdf, workspace, founder, localKeyId, sealedIdentity);
}
