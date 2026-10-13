import 'dart:math';

import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:identity_cryptography_adapters/identity_cryptography_adapters.dart';
import 'package:offline_sync/offline_sync.dart';
import 'package:offline_sync_adapters/offline_sync_adapters.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:sqlite3/common.dart';

import '../sync/sync_config.dart';
import '../vault/offline_server.dart';

/// The vault as every platform builds it: libsodium for the crypto and one
/// SQLite database (a file on mobile, IndexedDB in the browser) holding the
/// sealed header, the member log and the record envelopes. [passkeys] is
/// the second way in where the platform has one (WebAuthn in the browser).
VaultKeeper vaultKeeper({
  required SodiumSumo sodium,
  required CommonDatabase database,
  required KdfParameters kdf,
  SyncServer server = const OfflineSyncServer(),
  PasskeyPrf? passkeys,
}) => VaultKeeper(
  vaults: SqliteVaultStore(database),
  records: (workspace) =>
      SqliteLocalRecordStore(database, workspace: workspace),
  server: server,
  identities: SodiumIdentityService(sodium),
  keys: SodiumKeyDerivationService(sodium),
  subkeys: SodiumSubkeyDerivationService(sodium),
  envelopes: SodiumEnvelopeEncryptor(sodium),
  encapsulation: SodiumKeyEncapsulation(sodium),
  clock: const SystemClock(),
  random: Random.secure(),
  kdf: kdf,
  passkeys: passkeys,
);

/// The server the vault syncs with and the account that opens it.
final class CloudWiring {
  const CloudWiring({required this.server, this.account});

  final SyncServer server;

  /// Null in a build without a Supabase project: no sign-in is offered.
  final SyncAccount? account;
}

/// Supabase when the build names a project ([SyncConfig]); otherwise a
/// server that is never reachable, so edits stay queued and sealed.
CloudWiring cloudWiring(SyncConfig? config) {
  if (config == null) {
    return const CloudWiring(server: OfflineSyncServer());
  }
  final account = SyncAccount(
    SupabaseAuth(projectUrl: config.projectUrl, anonKey: config.anonKey),
  );
  return CloudWiring(
    server: SupabaseSyncServer(
      projectUrl: config.projectUrl,
      anonKey: config.anonKey,
      accessToken: account.accessToken,
    ),
    account: account,
  );
}
