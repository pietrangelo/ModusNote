/// Identity & Cryptography: coppie di chiavi, derivazione Argon2id, buste
/// XChaCha20-Poly1305.
///
/// Public API of the bounded context. Other packages import only this
/// library, never files under `src/`.
library;

export 'src/application/envelope_encryptor.dart';
export 'src/application/identity_service.dart';
export 'src/application/key_derivation_service.dart';
export 'src/application/passkey_prf.dart';
export 'src/application/secret.dart';
export 'src/application/subkey_derivation_service.dart';
export 'src/core/associated_data.dart';
export 'src/core/cryptography_exception.dart';
export 'src/core/encrypted_envelope.dart';
export 'src/core/kdf_parameters.dart';
export 'src/core/nonce.dart';
export 'src/core/passkey.dart';
export 'src/core/passphrase_policy.dart';
export 'src/core/public_keys.dart';
export 'src/core/salt.dart';
export 'src/core/subkey.dart';
