import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:identity_cryptography_adapters/identity_cryptography_adapters.dart';
import 'package:modusnote/vault/offline_server.dart';
import 'package:offline_sync/offline_sync.dart';
import 'package:offline_sync_adapters/offline_sync_adapters.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:sqlite3/sqlite3.dart';

late SodiumSumo sodium;

Future<void> loadSodium() async => sodium = await SodiumSumoInit.init();

/// A vault on an in-memory SQLite database, as the app builds it on a
/// device; several keepers on the same [database] are app restarts.
VaultKeeper keeperOn(Database database) => VaultKeeper(
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
  kdf: KdfParameters.interactive,
);

Database memoryDatabase() => sqlite3.openInMemory();

PasswordSecret passphrase(String text) => SodiumPasswordSecret.fromUtf8Bytes(
  sodium,
  Uint8List.fromList(utf8.encode(text)),
);
