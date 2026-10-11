/// Handle to secret material that lives in native, locked memory.
///
/// The domain never sees the bytes: Dart's GC may copy heap objects, so a
/// secret that ever became a `Uint8List` or `String` could not be zeroed.
/// Adapters own the memory and zero it on [dispose].
abstract interface class Secret {
  bool get isDisposed;

  /// Zeroes and frees the native memory. Idempotent.
  void dispose();
}

/// Symmetric key for XChaCha20-Poly1305 envelopes (MasterKey, GroupKey,
/// per-record data keys).
abstract interface class SymmetricKey implements Secret {}

/// The user's passphrase, held in native memory until it has been stretched.
abstract interface class PasswordSecret implements Secret {}
