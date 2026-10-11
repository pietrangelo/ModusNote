import 'dart:typed_data';

import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:sodium/sodium_sumo.dart';

import 'sodium_secrets.dart';

/// [IdentityService] on `crypto_sign` (Ed25519) and `crypto_kem` (X-Wing).
final class SodiumIdentityService implements IdentityService {
  SodiumIdentityService(this._sodium);

  final Sodium _sodium;

  @override
  IdentityKeyPair generateIdentity() {
    final signing = _sodium.crypto.sign.keyPair();
    final KeyPair encryption;
    try {
      encryption = _sodium.crypto.kem.keyPair();
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
}
