/// Failures of the Identity & Cryptography context.
///
/// Messages are fixed strings on purpose: an exception may end up in a log or
/// crash report, so it must never echo keys, plaintext, or ciphertext.
sealed class CryptographyException implements Exception {
  const CryptographyException();

  String get message;

  @override
  String toString() => '$runtimeType: $message';
}

/// AEAD verification failed: the ciphertext, nonce, associated data or key
/// does not match. No partial plaintext is ever released.
final class AuthenticationTagMismatchException extends CryptographyException {
  const AuthenticationTagMismatchException();

  @override
  String get message => 'authentication tag mismatch';
}

final class MalformedEnvelopeException extends CryptographyException {
  const MalformedEnvelopeException(this.message);

  @override
  final String message;
}

final class InvalidLengthException extends CryptographyException {
  const InvalidLengthException(this.valueObject, this.expected, this.actual);

  final String valueObject;
  final int expected;
  final int actual;

  @override
  String get message => '$valueObject must be $expected bytes, got $actual';
}

final class WeakKdfParametersException extends CryptographyException {
  const WeakKdfParametersException();

  @override
  String get message => 'KDF parameters are below the interactive floor';
}

final class ExcessiveKdfParametersException extends CryptographyException {
  const ExcessiveKdfParametersException();

  @override
  String get message => 'KDF parameters exceed what a device can afford';
}

final class WeakPassphraseException extends CryptographyException {
  const WeakPassphraseException();

  @override
  String get message => 'passphrase shorter than the policy minimum';
}

/// A secret was used after `dispose()` released its native memory.
final class DisposedKeyException extends CryptographyException {
  const DisposedKeyException();

  @override
  String get message => 'secret used after dispose';
}

final class InvalidKeyContextException extends CryptographyException {
  const InvalidKeyContextException();

  @override
  String get message => 'key context must be 8 printable ASCII characters';
}

/// An Ed25519 signature does not match the message and signer. Whatever it
/// was attached to (a membership change, a KeyBundle) must be discarded.
final class InvalidSignatureException extends CryptographyException {
  const InvalidSignatureException();

  @override
  String get message => 'invalid signature';
}
