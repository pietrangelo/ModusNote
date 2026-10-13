import 'dart:typed_data';

import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:meta/meta.dart';

import 'sync_exception.dart';
import 'vault_header.dart';
import 'wire.dart';

/// A second way into the device's vault: the identity and the local record
/// key sealed under a key derived from a passkey's PRF output, so a
/// fingerprint or a PIN on the authenticator replaces the passphrase.
///
/// The PRF output never leaves the device and is never stored: only the
/// passkey's id, the public PRF salt and the selector of the subkey derived
/// from it are kept in clear, and all of them, together with every clear
/// field of the [VaultHeader], are bound into the associated data of both
/// sealed secrets. A slot moved to another vault, or a header edited after
/// enrolling, no longer opens.
///
/// The local key is sealed to the device's own identity, so the passkey key
/// opens the identity and the identity opens the local key.
///
/// Wire: `version(1) | credential(blob) | salt(32) | keyId(8) |
/// sealedIdentity(blob) | sealedLocalKey(SealedKey.length)`.
@immutable
final class PasskeySlot {
  const PasskeySlot({
    required this.credential,
    required this.salt,
    required this.keyId,
    required this.sealedIdentity,
    required this.sealedLocalKey,
  });

  /// Builds a slot whose secrets are sealed by [sealIdentity] and
  /// [sealLocalKey] under the associated data that binds them, so the
  /// binding cannot be forgotten.
  factory PasskeySlot.sealing({
    required VaultHeader header,
    required PasskeyCredentialId credential,
    required PrfSalt salt,
    required SubkeyId keyId,
    required EncryptedEnvelope Function(AssociatedData slot) sealIdentity,
    required SealedKey Function(AssociatedData slot) sealLocalKey,
  }) {
    final unsealed = PasskeySlot(
      credential: credential,
      salt: salt,
      keyId: keyId,
      sealedIdentity: _unsealedIdentity,
      sealedLocalKey: _unsealedKey,
    );
    return PasskeySlot(
      credential: credential,
      salt: salt,
      keyId: keyId,
      sealedIdentity: sealIdentity(unsealed.identitySlot(header)),
      sealedLocalKey: sealLocalKey(unsealed.localKeySlot(header)),
    );
  }

  factory PasskeySlot.parse(List<int> wire) {
    try {
      final reader = WireReader(wire);
      if (reader.uint8() != _version) {
        throw const MalformedSyncDataException('unsupported passkey version');
      }
      final slot = PasskeySlot(
        credential: PasskeyCredentialId.fromBytes(reader.blob()),
        salt: PrfSalt.fromBytes(reader.bytes(PrfSalt.length)),
        keyId: SubkeyId.fromBytes(reader.bytes(SubkeyId.length)),
        sealedIdentity: EncryptedEnvelope.parse(reader.blob()),
        sealedLocalKey: SealedKey.parse(reader.bytes(SealedKey.length)),
      );
      reader.finish();
      return slot;
    } on CryptographyException {
      throw const MalformedSyncDataException('malformed passkey slot');
    }
  }

  static const _version = 1;
  static final _unsealedIdentity = EncryptedEnvelope(
    nonce: Nonce.fromBytes(Uint8List(Nonce.length)),
    ciphertext: Uint8List(EncryptedEnvelope.tagLength),
  );
  static final _unsealedKey = SealedKey(
    encapsulation: Uint8List(SealedKey.encapsulationLength),
    envelope: EncryptedEnvelope(
      nonce: Nonce.fromBytes(Uint8List(Nonce.length)),
      ciphertext: Uint8List(SealedKey.keyLength + EncryptedEnvelope.tagLength),
    ),
  );

  final PasskeyCredentialId credential;
  final PrfSalt salt;

  /// Selects the key derived from the PRF output that seals the identity.
  final SubkeyId keyId;
  final EncryptedEnvelope sealedIdentity;
  final SealedKey sealedLocalKey;

  /// The associated data the identity is sealed under.
  AssociatedData identitySlot(VaultHeader header) =>
      _slot('modusnote.vault.passkey.identity.v1', header);

  /// The associated data the local key is sealed under.
  AssociatedData localKeySlot(VaultHeader header) =>
      _slot('modusnote.vault.passkey.local-key.v1', header);

  AssociatedData _slot(String context, VaultHeader header) =>
      AssociatedData.forContext(
        context,
        '${_hex(header.boundFields)}.${_hex(_clearFields().take())}',
      );

  Uint8List toBytes() =>
      (_clearFields()
            ..blob(sealedIdentity.toBytes())
            ..bytes(sealedLocalKey.toBytes()))
          .take();

  WireWriter _clearFields() => WireWriter()
    ..uint8(_version)
    ..blob(credential.bytes)
    ..bytes(salt.bytes)
    ..bytes(keyId.bytes);

  static String _hex(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  @override
  bool operator ==(Object other) =>
      other is PasskeySlot &&
      other.credential == credential &&
      other.salt == salt &&
      other.keyId == keyId &&
      other.sealedIdentity == sealedIdentity &&
      other.sealedLocalKey == sealedLocalKey;

  @override
  int get hashCode =>
      Object.hash(credential, salt, keyId, sealedIdentity, sealedLocalKey);
}
