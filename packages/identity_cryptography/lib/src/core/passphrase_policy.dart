/// Minimum a passphrase must meet before it is stretched. Argon2id slows
/// guessing down; it cannot rescue an empty or trivially short passphrase.
abstract final class PassphrasePolicy {
  /// Measured in UTF-8 bytes, the unit adapters receive.
  static const minimumBytes = 8;
}
