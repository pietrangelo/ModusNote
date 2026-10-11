import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:sodium/sodium_sumo.dart';

import 'sodium_envelope_encryptor.dart';
import 'sodium_secrets.dart';

/// [KeyEncapsulation] as X-Wing KEM + XChaCha20-Poly1305: the KEM's shared
/// secret, which libsodium returns in guarded memory, wraps the key.
final class SodiumKeyEncapsulation implements KeyEncapsulation {
  SodiumKeyEncapsulation(this._sodium)
    : _envelopes = SodiumEnvelopeEncryptor(_sodium);

  final Sodium _sodium;
  final SodiumEnvelopeEncryptor _envelopes;

  @override
  SealedKey seal(
    SymmetricKey key, {
    required PublicEncryptionKey recipient,
    required AssociatedData associatedData,
  }) {
    final native = unwrapKey(key);
    final (:ciphertext, :sharedSecret) = _sodium.crypto.kem.enc(
      publicKey: recipient.bytes,
    );
    final wrappingKey = SodiumSymmetricKey.wrap(sharedSecret);
    try {
      // The unlocked view points into native memory, so the key's bytes go
      // from one sodium allocation to another without a Dart-heap copy.
      final envelope = native.runUnlockedSync(
        (bytes) => _envelopes.seal(
          bytes,
          key: wrappingKey,
          associatedData: associatedData,
        ),
      );
      return SealedKey(encapsulation: ciphertext, envelope: envelope);
    } finally {
      wrappingKey.dispose();
    }
  }

  @override
  SymmetricKey open(
    SealedKey sealed, {
    required IdentityKeyPair recipient,
    required AssociatedData associatedData,
  }) {
    final wrappingKey = SodiumSymmetricKey.wrap(
      _sodium.crypto.kem.dec(
        ciphertext: sealed.encapsulation,
        secretKey: unwrapDecapsulationKey(recipient),
      ),
    );
    try {
      final plaintext = _envelopes.open(
        sealed.envelope,
        key: wrappingKey,
        associatedData: associatedData,
      );
      // The binding's decrypt can only return heap memory: copy it into
      // guarded memory and wipe it at once, as for the passphrase.
      try {
        return SodiumSymmetricKey.wrap(_sodium.secureCopy(plaintext));
      } finally {
        plaintext.fillRange(0, plaintext.length, 0);
      }
    } finally {
      wrappingKey.dispose();
    }
  }
}
