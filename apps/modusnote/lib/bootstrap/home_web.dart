import 'package:flutter/widgets.dart';
import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:identity_cryptography_adapters/identity_cryptography_adapters.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:sqlite3/wasm.dart';

import '../vault/vault_gate.dart';
import 'vault_wiring.dart';

/// The browser is another vault device. libsodium arrives as `sodium.js`
/// (loaded by `index.html`), SQLite as `sqlite3.wasm`, both served from our
/// own origin. The database lives in IndexedDB and, as on mobile, holds only
/// the sealed vault header and envelopes: nothing readable without the
/// passphrase. Recording and playback come later in Fase 7.
Future<Widget> buildHome() async {
  final sodium = await SodiumSumoInit.init();
  final sqlite = await WasmSqlite3.loadFromUrl(Uri.parse('sqlite3.wasm'));
  final storage = await IndexedDbFileSystem.open(dbName: _storageName);
  sqlite.registerVirtualFileSystem(storage, makeDefault: true);
  final database = sqlite.open('/vault.sqlite');
  // Writes reach IndexedDB in the background; push them out before the tab
  // can be closed or frozen.
  AppLifecycleListener(onHide: storage.flush, onPause: storage.flush);
  return VaultGate(
    keeper: vaultKeeper(
      sodium: sodium,
      database: database,
      kdf: KdfParameters.moderate,
    ),
    passwordFrom: (bytes) => SodiumPasswordSecret.fromUtf8Bytes(sodium, bytes),
    catalog: SeedSchemas.catalog,
  );
}

/// One IndexedDB database per origin holds the vault file.
const _storageName = 'modusnote';
