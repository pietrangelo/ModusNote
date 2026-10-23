import 'dart:convert';
import 'dart:typed_data';

import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:identity_cryptography_adapters/identity_cryptography_adapters.dart';
import 'package:modusnote/bootstrap/vault_wiring.dart';
import 'package:offline_sync/offline_sync.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:sqlite3/sqlite3.dart';

late SodiumSumo sodium;

Future<void> loadSodium() async => sodium = await SodiumSumoInit.init();

/// A vault on an in-memory SQLite database, as the app builds it on a
/// device; several keepers on the same [database] are app restarts.
VaultKeeper keeperOn(
  Database database, {
  SyncGateway? gateway,
  PasskeyPrf? passkeys,
}) => vaultKeeper(
  sodium: sodium,
  database: database,
  kdf: KdfParameters.interactive,
  gateway: gateway,
  passkeys: passkeys,
);

/// An authenticator in memory: each passkey is a random secret and its PRF
/// a hash of secret and salt, as `hmac-secret` is an HMAC of both.
final class FakePasskeys implements PasskeyPrf {
  final _secrets = <PasskeyCredentialId, Uint8List>{};

  /// Thrown by the next request instead of answering it.
  Object? failNext;

  /// Answers with an unrelated secret, as another authenticator would.
  bool impostor = false;

  @override
  Future<RegisteredPasskey> register({required PrfSalt salt}) async {
    _maybeFail();
    final credential = PasskeyCredentialId.fromBytes(
      sodium.randombytes.buf(32),
    );
    _secrets[credential] = sodium.randombytes.buf(32);
    return RegisteredPasskey(
      credential: credential,
      key: _prf(credential, salt),
    );
  }

  @override
  Future<SymmetricKey> evaluate(
    PasskeyCredentialId credential, {
    required PrfSalt salt,
  }) async {
    _maybeFail();
    if (!_secrets.containsKey(credential)) {
      throw const PasskeyCancelledException();
    }
    return _prf(credential, salt);
  }

  @override
  Future<void> forget(PasskeyCredentialId credential) async =>
      _secrets.remove(credential);

  void _maybeFail() {
    final failure = failNext;
    failNext = null;
    if (failure != null) throw failure;
  }

  SymmetricKey _prf(PasskeyCredentialId credential, PrfSalt salt) =>
      SodiumSymmetricKey.wrap(
        sodium.secureCopy(
          sodium.crypto.genericHash(
            message: Uint8List.fromList([
              ...impostor ? sodium.randombytes.buf(32) : _secrets[credential]!,
              ...salt.bytes,
            ]),
          ),
        ),
      );
}

Database memoryDatabase() => sqlite3.openInMemory();

PasswordSecret passphrase(String text) => SodiumPasswordSecret.fromUtf8Bytes(
  sodium,
  Uint8List.fromList(utf8.encode(text)),
);
