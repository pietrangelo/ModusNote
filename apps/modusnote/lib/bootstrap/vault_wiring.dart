import 'dart:math';

import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:identity_cryptography_adapters/identity_cryptography_adapters.dart';
import 'package:offline_sync/offline_sync.dart';
import 'package:offline_sync_adapters/offline_sync_adapters.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:sqlite3/common.dart';

import '../vault/offline_server.dart';

/// The vault as every platform builds it: libsodium for the crypto and one
/// SQLite database (a file on mobile, IndexedDB in the browser) holding the
/// sealed header, the member log and the record envelopes.
VaultKeeper vaultKeeper({
  required SodiumSumo sodium,
  required CommonDatabase database,
  required KdfParameters kdf,
}) => VaultKeeper(
  vaults: SqliteVaultStore(database),
  records: (workspace) =>
      SqliteLocalRecordStore(database, workspace: workspace),
  server: const OfflineSyncServer(),
  identities: SodiumIdentityService(sodium),
  keys: SodiumKeyDerivationService(sodium),
  subkeys: SodiumSubkeyDerivationService(sodium),
  envelopes: SodiumEnvelopeEncryptor(sodium),
  encapsulation: SodiumKeyEncapsulation(sodium),
  clock: const SystemClock(),
  random: Random.secure(),
  kdf: kdf,
);
