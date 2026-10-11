import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:sodium/sodium_sumo.dart';

import 'sodium_secrets.dart';

/// [SubkeyDerivationService] on `crypto_kdf_derive_from_key` (BLAKE2b).
///
/// libsodium writes the subkey straight into a fresh `SecureKey`, so neither
/// the parent nor the child key ever touches the Dart heap.
final class SodiumSubkeyDerivationService implements SubkeyDerivationService {
  SodiumSubkeyDerivationService(this._sodium);

  final Sodium _sodium;

  @override
  SubkeyId newSubkeyId() =>
      SubkeyId.fromBytes(_sodium.randombytes.buf(SubkeyId.length));

  @override
  SymmetricKey deriveSubkey({
    required SymmetricKey parent,
    required KeyContext context,
    required SubkeyId id,
  }) => SodiumSymmetricKey.wrap(
    _sodium.crypto.kdf.deriveFromKey(
      masterKey: unwrapKey(parent),
      context: context.value,
      subkeyId: _uint64BigEndian(id),
      subkeyLen: _sodium.crypto.aeadXChaCha20Poly1305IETF.keyBytes,
    ),
  );

  static BigInt _uint64BigEndian(SubkeyId id) => id.bytes.fold(
    BigInt.zero,
    (value, byte) => (value << 8) | BigInt.from(byte),
  );
}
