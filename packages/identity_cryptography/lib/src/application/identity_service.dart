import 'dart:typed_data';

import '../core/associated_data.dart';
import '../core/encrypted_envelope.dart';
import '../core/public_keys.dart';
import 'secret.dart';

/// A device's long-term identity: an Ed25519 signing key and an X-Wing
/// decapsulation key, both held in native memory.
abstract interface class IdentityKeyPair implements Secret {
  PublicIdentity get publicIdentity;
}

/// Port: identities and detached signatures (Ed25519).
abstract interface class IdentityService {
  IdentityKeyPair generateIdentity();

  /// Callers sign a canonical encoding that starts with a purpose label, so
  /// a signature made for one kind of message never verifies as another.
  Signature sign(Uint8List message, {required IdentityKeyPair signer});

  /// Throws [InvalidSignatureException] unless [signature] was made over
  /// exactly [message] by the holder of [signer].
  void verify(
    Uint8List message, {
    required Signature signature,
    required PublicSigningKey signer,
  });

  /// Seals the identity's private keys under [key] (the MasterKey) so the
  /// device keeps its identity across restarts without ever storing it in
  /// clear.
  EncryptedEnvelope sealIdentity(
    IdentityKeyPair identity, {
    required SymmetricKey key,
    required AssociatedData associatedData,
  });

  /// Throws [AuthenticationTagMismatchException] for a wrong key, a wrong
  /// slot or any tampering.
  IdentityKeyPair openIdentity(
    EncryptedEnvelope sealed, {
    required SymmetricKey key,
    required AssociatedData associatedData,
  });
}

/// Port: seals a [SymmetricKey] (a GroupKey) to one recipient's
/// [PublicEncryptionKey], so only that recipient can recover it.
///
/// Sealing is anonymous: anyone can seal a key to anyone. Who issued a
/// [SealedKey] is established by signing it, never by the encapsulation.
abstract interface class KeyEncapsulation {
  SealedKey seal(
    SymmetricKey key, {
    required PublicEncryptionKey recipient,
    required AssociatedData associatedData,
  });

  /// Throws [AuthenticationTagMismatchException] if [sealed] was not sealed
  /// to [recipient] with the same [associatedData], or was altered.
  SymmetricKey open(
    SealedKey sealed, {
    required IdentityKeyPair recipient,
    required AssociatedData associatedData,
  });
}
