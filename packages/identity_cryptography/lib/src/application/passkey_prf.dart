import '../core/passkey.dart';
import 'secret.dart';

/// A passkey just registered, with its first PRF output as a key.
final class RegisteredPasskey {
  const RegisteredPasskey({required this.credential, required this.key});

  final PasskeyCredentialId credential;

  /// Owned by the caller, who disposes it.
  final SymmetricKey key;
}

/// Port: a passkey as a source of key material, through the WebAuthn PRF
/// extension. The authenticator keeps the secret and asks the user (a
/// fingerprint, a face, a PIN) before every evaluation; the PRF output
/// comes back as a [SymmetricKey] handle, never as bytes.
///
/// Throws [PasskeyCancelledException] when the user dismisses the prompt
/// and [PasskeyUnsupportedException] when no PRF output is available.
abstract interface class PasskeyPrf {
  /// Creates a new passkey for this device's vault and evaluates its PRF on
  /// [salt].
  Future<RegisteredPasskey> register({required PrfSalt salt});

  /// Asks for [credential], and only that passkey, and evaluates its PRF on
  /// [salt].
  Future<SymmetricKey> evaluate(
    PasskeyCredentialId credential, {
    required PrfSalt salt,
  });

  /// Best effort: tells the passkey manager that [credential] is no longer
  /// used, so it can stop offering it. Never throws.
  Future<void> forget(PasskeyCredentialId credential);
}
