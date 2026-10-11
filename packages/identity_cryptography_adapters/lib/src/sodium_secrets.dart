import 'dart:typed_data';

import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:meta/meta.dart';
import 'package:sodium/sodium_sumo.dart';

/// [SymmetricKey] backed by libsodium guarded memory (`sodium_malloc`,
/// `sodium_mprotect_noaccess` while locked, zeroed by `sodium_free`).
final class SodiumSymmetricKey implements SymmetricKey {
  SodiumSymmetricKey.wrap(SecureKey native) : _native = _Native(native);

  final _Native _native;

  @override
  bool get isDisposed => _native.isDisposed;

  @override
  void dispose() => _native.dispose();

  @internal
  SecureKey get native => _native.key;

  @override
  String toString() => 'SymmetricKey(redacted)';
}

/// [PasswordSecret] backed by libsodium guarded memory.
final class SodiumPasswordSecret implements PasswordSecret {
  SodiumPasswordSecret.wrap(SecureKey native) : _native = _Native(native);

  /// Moves a UTF-8 passphrase into native memory and wipes [buffer], so the
  /// only Dart-heap copy is gone before this constructor returns.
  factory SodiumPasswordSecret.fromUtf8Bytes(Sodium sodium, Uint8List buffer) {
    try {
      return SodiumPasswordSecret.wrap(sodium.secureCopy(buffer));
    } finally {
      buffer.fillRange(0, buffer.length, 0);
    }
  }

  final _Native _native;

  @override
  bool get isDisposed => _native.isDisposed;

  @override
  void dispose() => _native.dispose();

  @internal
  SecureKey get native => _native.key;

  @override
  String toString() => 'PasswordSecret(redacted)';
}

/// Shared lifecycle: dispose exactly once, refuse use afterwards.
final class _Native {
  _Native(this._key);

  final SecureKey _key;
  bool isDisposed = false;

  SecureKey get key {
    if (isDisposed) throw const DisposedKeyException();
    return _key;
  }

  void dispose() {
    if (isDisposed) return;
    isDisposed = true;
    _key.dispose();
  }
}

/// Only keys minted by these adapters carry native memory; anything else
/// handed in through the port is a programming error, not a key to trust.
@internal
SecureKey unwrapKey(SymmetricKey key) => switch (key) {
  SodiumSymmetricKey() => key.native,
  _ => throw ArgumentError('key was not created by a sodium adapter'),
};

@internal
SecureKey unwrapPassword(PasswordSecret password) => switch (password) {
  SodiumPasswordSecret() => password.native,
  _ => throw ArgumentError('passphrase was not created by a sodium adapter'),
};
