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
      if (buffer.length < PassphrasePolicy.minimumBytes) {
        throw const WeakPassphraseException();
      }
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

  @override
  String toString() => 'PasswordSecret(redacted)';
}

/// [IdentityKeyPair] whose Ed25519 and X-Wing secret keys both live in
/// libsodium guarded memory and are released together.
final class SodiumIdentityKeyPair implements IdentityKeyPair {
  SodiumIdentityKeyPair.wrap({
    required this.publicIdentity,
    required SecureKey signingKey,
    required SecureKey decapsulationKey,
  }) : _signing = _Native(signingKey),
       _decapsulation = _Native(decapsulationKey);

  @override
  final PublicIdentity publicIdentity;
  final _Native _signing;
  final _Native _decapsulation;

  @override
  bool get isDisposed => _signing.isDisposed;

  @override
  void dispose() {
    _signing.dispose();
    _decapsulation.dispose();
  }

  @override
  String toString() => 'IdentityKeyPair(redacted)';
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
/// These are the only way to the native memory, and they are not exported,
/// so nothing outside this package can call `extractBytes()` on a key.
@internal
SecureKey unwrapKey(SymmetricKey key) => switch (key) {
  SodiumSymmetricKey() => key._native.key,
  _ => throw ArgumentError('key was not created by a sodium adapter'),
};

@internal
SecureKey unwrapPassword(PasswordSecret password) => switch (password) {
  SodiumPasswordSecret() => password._native.key,
  _ => throw ArgumentError('passphrase was not created by a sodium adapter'),
};

@internal
SecureKey unwrapSigningKey(IdentityKeyPair identity) => switch (identity) {
  SodiumIdentityKeyPair() => identity._signing.key,
  _ => throw ArgumentError('identity was not created by a sodium adapter'),
};

@internal
SecureKey unwrapDecapsulationKey(IdentityKeyPair identity) =>
    switch (identity) {
      SodiumIdentityKeyPair() => identity._decapsulation.key,
      _ => throw ArgumentError('identity was not created by a sodium adapter'),
    };
