import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:identity_cryptography_adapters/identity_cryptography_adapters.dart';
import 'package:offline_sync/offline_sync.dart';
import 'package:offline_sync_adapters/offline_sync_adapters.dart';
import 'package:path_provider/path_provider.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:sqlite3/sqlite3.dart';

import '../vault/offline_server.dart';
import '../vault/vault_gate.dart';

/// libsodium is built by the `sodium` package's build hook and loaded once
/// here; the vault lives in one SQLite file in the app's private support
/// directory, which holds only envelopes and the sealed vault header.
Future<Widget> buildHome() async {
  final sodium = await SodiumSumoInit.init();
  final directory = await getApplicationSupportDirectory();
  final database = sqlite3.open('${directory.path}/vault.sqlite');
  return VaultGate(
    keeper: VaultKeeper(
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
      kdf: KdfParameters.moderate,
    ),
    passwordFrom: (bytes) => SodiumPasswordSecret.fromUtf8Bytes(sodium, bytes),
    schemas: SeedSchemas.all,
  );
}
