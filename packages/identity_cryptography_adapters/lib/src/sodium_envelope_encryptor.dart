import 'dart:typed_data';

import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:sodium/sodium_sumo.dart';

import 'sodium_secrets.dart';

/// [EnvelopeEncryptor] on `crypto_aead_xchacha20poly1305_ietf`.
final class SodiumEnvelopeEncryptor implements EnvelopeEncryptor {
  SodiumEnvelopeEncryptor(this._sodium);

  final Sodium _sodium;

  Aead get _aead => _sodium.crypto.aeadXChaCha20Poly1305IETF;

  @override
  SymmetricKey generateKey() => SodiumSymmetricKey.wrap(_aead.keygen());

  @override
  EncryptedEnvelope seal(
    Uint8List plaintext, {
    required SymmetricKey key,
    required AssociatedData associatedData,
  }) {
    final native = unwrapKey(key);
    final nonce = Nonce.fromBytes(_sodium.randombytes.buf(Nonce.length));
    final ciphertext = _aead.encrypt(
      message: plaintext,
      nonce: nonce.bytes,
      key: native,
      additionalData: EncryptedEnvelope.authenticatedData(associatedData),
    );
    return EncryptedEnvelope(nonce: nonce, ciphertext: ciphertext);
  }

  @override
  Uint8List open(
    EncryptedEnvelope envelope, {
    required SymmetricKey key,
    required AssociatedData associatedData,
  }) {
    final native = unwrapKey(key);
    try {
      return _aead.decrypt(
        cipherText: envelope.ciphertext,
        nonce: envelope.nonce.bytes,
        key: native,
        additionalData: EncryptedEnvelope.authenticatedData(associatedData),
      );
    } on SodiumException {
      throw const AuthenticationTagMismatchException();
    }
  }
}
