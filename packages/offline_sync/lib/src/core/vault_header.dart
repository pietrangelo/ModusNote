import 'dart:typed_data';

import 'package:collaboration_access_control/collaboration_access_control.dart';
import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:meta/meta.dart';

import 'sync_exception.dart';
import 'wire.dart';

/// What a device keeps in clear to reopen its vault: the Argon2id salt and
/// costs, the workspace with its pinned founder, the device's own member
/// id, the selector of the device-local key, and the identity sealed under
/// the MasterKey.
///
/// Every clear field is bound into the identity's associated data, so a
/// header edited on disk (a weaker KDF, another founder) no longer opens.
///
/// Wire, for the device that founded the workspace: `version(1) | salt(16)
/// | opsLimit(u32) | memLimit(u32) | workspace(16) | founder(32) |
/// localKeyId(8) | sealedIdentity(blob)`. A device that joined it writes
/// version 2, with its own `member(32)` after the founder.
@immutable
final class VaultHeader {
  const VaultHeader({
    required this.salt,
    required this.kdf,
    required this.workspace,
    required this.founder,
    required this.localKeyId,
    required this.sealedIdentity,
    this._member,
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
    MemberId? member,
  }) {
    final unsealed = VaultHeader(
      salt: salt,
      kdf: kdf,
      workspace: workspace,
      founder: founder,
      member: member,
      localKeyId: localKeyId,
      sealedIdentity: _unsealed,
    );
    return VaultHeader(
      salt: salt,
      kdf: kdf,
      workspace: workspace,
      founder: founder,
      member: member,
      localKeyId: localKeyId,
      sealedIdentity: seal(unsealed.identitySlot),
    );
  }

  factory VaultHeader.parse(List<int> wire) {
    final reader = WireReader(wire);
    final version = reader.uint8();
    if (version != _founderVersion && version != _memberVersion) {
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
    final founder = _memberId(reader);
    final member = version == _memberVersion ? _memberId(reader) : founder;
    if (version == _memberVersion && member == founder) {
      // One header, one encoding: the founder's is always version 1.
      throw const MalformedSyncDataException('member header names founder');
    }
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
      member: member,
      localKeyId: localKeyId,
      sealedIdentity: sealedIdentity,
    );
  }

  static MemberId _memberId(WireReader reader) => MemberId(
    PublicSigningKey.fromBytes(reader.bytes(PublicSigningKey.length)),
  );

  static const _founderVersion = 1;
  static const _memberVersion = 2;
  static final _unsealed = EncryptedEnvelope(
    nonce: Nonce.fromBytes(Uint8List(Nonce.length)),
    ciphertext: Uint8List(EncryptedEnvelope.tagLength),
  );

  final Salt salt;
  final KdfParameters kdf;
  final WorkspaceId workspace;

  /// The member who founded the workspace: the log is verified against it.
  final MemberId founder;
  final MemberId? _member;
  final SubkeyId localKeyId;
  final EncryptedEnvelope sealedIdentity;

  /// The device's own member id, which its sealed identity must match: the
  /// founder on the device that founded the workspace.
  MemberId get member => _member ?? founder;

  bool get _joined => member != founder;

  /// The associated data the identity is sealed under.
  AssociatedData get identitySlot => AssociatedData.forContext(
    'modusnote.vault.identity.v1',
    _hex(boundFields),
  );

  /// Every clear field, as bound into the identity's associated data; other
  /// secrets kept next to the header bind them too.
  Uint8List get boundFields => _clearFields().take();

  Uint8List toBytes() =>
      (_clearFields()..blob(sealedIdentity.toBytes())).take();

  WireWriter _clearFields() {
    final writer = WireWriter()
      ..uint8(_joined ? _memberVersion : _founderVersion)
      ..bytes(salt.bytes)
      ..uint32(kdf.opsLimit)
      ..uint32(kdf.memLimitBytes)
      ..bytes(workspace.bytes)
      ..bytes(founder.signingKey.bytes);
    if (_joined) writer.bytes(member.signingKey.bytes);
    return writer..bytes(localKeyId.bytes);
  }

  static String _hex(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  @override
  bool operator ==(Object other) =>
      other is VaultHeader &&
      other.salt == salt &&
      other.kdf == kdf &&
      other.workspace == workspace &&
      other.founder == founder &&
      other.member == member &&
      other.localKeyId == localKeyId &&
      other.sealedIdentity == sealedIdentity;

  @override
  int get hashCode => Object.hash(
    salt,
    kdf,
    workspace,
    founder,
    member,
    localKeyId,
    sealedIdentity,
  );
}
