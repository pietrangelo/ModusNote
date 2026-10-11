import '../core/kdf_parameters.dart';
import '../core/salt.dart';
import 'secret.dart';

/// Port: stretches a passphrase into a [SymmetricKey] with Argon2id.
abstract interface class KeyDerivationService {
  /// A fresh random salt; one per vault, stored next to it in clear.
  Salt newSalt();

  /// Asynchronous because Argon2id is deliberately slow and adapters are
  /// expected to move it off the UI isolate.
  Future<SymmetricKey> deriveKey({
    required PasswordSecret password,
    required Salt salt,
    required KdfParameters parameters,
  });
}
