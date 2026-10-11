import 'dart:typed_data';

import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:sodium/sodium_sumo.dart';

import 'sodium_envelope_encryptor.dart';
import 'sodium_secrets.dart';

/// [IdentityService] on `crypto_sign` (Ed25519) and `crypto_kem` (X-Wing).
final class SodiumIdentityService implements IdentityService {
  SodiumIdentityService(this._sodium);

  final Sodium _sodium;

  /// Stored form: `Ed25519 seed | X-Wing seed`; both key pairs, public
  /// halves included, are re-derived from the seeds.
  static const _seedBytes = 32;

  @override
  IdentityKeyPair generateIdentity() =>
      _wrap(_sodium.crypto.sign.keyPair(), _sodium.crypto.kem.keyPair);

  IdentityKeyPair _wrap(KeyPair signing, KeyPair Function() encryptionPair) {
    final KeyPair encryption;
    try {
      encryption = encryptionPair();
    } on Object {
      signing.secretKey.dispose();
      rethrow;
    }
    return SodiumIdentityKeyPair.wrap(
      publicIdentity: PublicIdentity(
        signingKey: PublicSigningKey.fromBytes(signing.publicKey),
        encryptionKey: PublicEncryptionKey.fromBytes(encryption.publicKey),
      ),
      signingKey: signing.secretKey,
      decapsulationKey: encryption.secretKey,
    );
  }

  @override
  Signature sign(Uint8List message, {required IdentityKeyPair signer}) =>
      Signature.fromBytes(
        _sodium.crypto.sign.detached(
          message: message,
          secretKey: unwrapSigningKey(signer),
        ),
      );

  @override
  void verify(
    Uint8List message, {
    required Signature signature,
    required PublicSigningKey signer,
  }) {
    final bool valid;
    try {
      valid = _sodium.crypto.sign.verifyDetached(
        message: message,
        signature: signature.bytes,
        publicKey: signer.bytes,
      );
    } on SodiumException {
      throw const InvalidSignatureException();
    }
    if (!valid) throw const InvalidSignatureException();
  }

  @override
  EncryptedEnvelope sealIdentity(
    IdentityKeyPair identity, {
    required SymmetricKey key,
    required AssociatedData associatedData,
  }) {
    final signing = unwrapSigningKey(identity);
    final decapsulation = unwrapDecapsulationKey(identity);
    final seeds = SecureKey(_sodium, 2 * _seedBytes);
    try {
      // Both seeds are assembled in guarded memory and encrypted from the
      // unlocked native view, so they never land on the Dart heap.
      seeds.runUnlockedSync((target) {
        signing.runUnlockedSync(
          (source) => target.setRange(0, _seedBytes, source),
        );
        decapsulation.runUnlockedSync(
          (source) => target.setRange(_seedBytes, 2 * _seedBytes, source),
        );
      }, writable: true);
      return seeds.runUnlockedSync(
        (bytes) =>
            SodiumEnvelopeEncryptor(_sodium)
                .seal(bytes, key: key, associatedData: associatedData),
      );
    } finally {
      seeds.dispose();
    }
  }

  @override
  IdentityKeyPair openIdentity(
    EncryptedEnvelope sealed, {
    required SymmetricKey key,
    required AssociatedData associatedData,
  }) {
    final plaintext = SodiumEnvelopeEncryptor(_sodium)
        .open(sealed, key: key, associatedData: associatedData);
    final SecureKey signingSeed;
    final SecureKey encryptionSeed;
    try {
      if (plaintext.length != 2 * _seedBytes) {
        throw const MalformedEnvelopeException('stored identity length');
      }
      // The binding can only decrypt to the heap: copy into guarded memory
      // and wipe at once, as for the passphrase.
      signingSeed = _sodium.secureCopy(
        Uint8List.sublistView(plaintext, 0, _seedBytes),
      );
      encryptionSeed = _sodium.secureCopy(
        Uint8List.sublistView(plaintext, _seedBytes),
      );
    } finally {
      plaintext.fillRange(0, plaintext.length, 0);
    }
    try {
      return _wrap(
        _sodium.crypto.sign.seedKeyPair(signingSeed),
        () => _sodium.crypto.kem.seedKeyPair(encryptionSeed),
      );
    } finally {
      signingSeed.dispose();
      encryptionSeed.dispose();
    }
  }
}
