import 'dart:typed_data';

import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:sodium/sodium_sumo.dart';

import 'sodium_secrets.dart';

/// [KeyDerivationService] on `crypto_pwhash` pinned to Argon2id v1.3.
///
/// Runs on the calling isolate. The passphrase is read straight out of
/// guarded memory and copied by libsodium into its own scratch allocation,
/// so it never lands on the Dart heap.
final class SodiumKeyDerivationService implements KeyDerivationService {
  SodiumKeyDerivationService(this._sodium);

  final SodiumSumo _sodium;

  static const _keyLength = 32;

  @override
  Salt newSalt() => Salt.fromBytes(_sodium.randombytes.buf(Salt.length));

  @override
  Future<SymmetricKey> deriveKey({
    required PasswordSecret password,
    required Salt salt,
    required KdfParameters parameters,
  }) async {
    final native = unwrapPassword(password);
    final key = native.runUnlockedSync(
      (passphrase) => _sodium.crypto.pwhash.callRaw(
        outLen: _keyLength,
        password: Int8List.sublistView(passphrase),
        salt: salt.bytes,
        opsLimit: parameters.opsLimit,
        memLimit: parameters.memLimitBytes,
        alg: CryptoPwhashAlgorithm.argon2id13,
      ),
    );
    return SodiumSymmetricKey.wrap(key);
  }
}
