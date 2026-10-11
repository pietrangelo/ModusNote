import 'dart:typed_data';

import '../core/associated_data.dart';
import '../core/encrypted_envelope.dart';
import 'secret.dart';

/// Port: authenticated symmetric encryption (XChaCha20-Poly1305).
///
/// [AssociatedData] is required, not optional, so every call site has to
/// decide what the ciphertext is bound to.
abstract interface class EnvelopeEncryptor {
  SymmetricKey generateKey();

  EncryptedEnvelope seal(
    Uint8List plaintext, {
    required SymmetricKey key,
    required AssociatedData associatedData,
  });

  /// Throws [AuthenticationTagMismatchException] on any tampering and never
  /// returns partial plaintext.
  Uint8List open(
    EncryptedEnvelope envelope, {
    required SymmetricKey key,
    required AssociatedData associatedData,
  });
}
