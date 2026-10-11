import '../core/subkey.dart';
import 'secret.dart';

/// Port: derives independent subkeys from a parent [SymmetricKey]
/// (`crypto_kdf`, BLAKE2b), e.g. one BlobKey per audio blob from the
/// content key, so the subkey stays in native memory end to end.
abstract interface class SubkeyDerivationService {
  /// A fresh random id; collisions are harmless (only key separation is
  /// lost), so 64 random bits are plenty.
  SubkeyId newSubkeyId();

  /// Deterministic: the same parent, context and id always give the same
  /// key, which is how a reader re-derives what a writer used. The caller
  /// owns the returned key and disposes it independently of [parent].
  SymmetricKey deriveSubkey({
    required SymmetricKey parent,
    required KeyContext context,
    required SubkeyId id,
  });
}
