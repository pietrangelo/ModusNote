import 'package:blob_storage_media/blob_storage_media.dart';
import 'package:blob_storage_media_adapters/audio_encoding.dart';
import 'package:blob_storage_media_adapters/web_media.dart';
import 'package:blob_storage_media_recorder_adapters/blob_storage_media_recorder_adapters.dart';
import 'package:flutter/widgets.dart';
import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:identity_cryptography_adapters/identity_cryptography_adapters.dart';
import 'package:identity_cryptography_adapters/web_passkeys.dart';
import 'package:offline_sync/offline_sync.dart';
import 'package:offline_sync_adapters/offline_sync_adapters.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:sqlite3/wasm.dart';

import '../attachments/note_images.dart';
import '../audio/note_playback.dart';
import '../audio/note_recorder.dart';
import '../audio/web_audio_player.dart';
import '../sync/sync_config.dart';
import '../vault/vault_gate.dart';
import '../vault/vault_shelf_gate.dart';
import 'browser_file_exchange.dart';
import 'browser_image_chooser.dart';
import 'vault_wiring.dart';

/// The browser is another vault device. libsodium arrives as `sodium.js`
/// (loaded by `index.html`), SQLite as `sqlite3.wasm`, both served from our
/// own origin. Each vault of the device has its own database file in
/// IndexedDB which, as on mobile, holds only the sealed vault header and
/// envelopes: nothing readable without the passphrase. Recordings are sealed
/// blobs in an IndexedDB database per vault, encoded to Ogg Opus by
/// WebCodecs where the browser has it (WAV elsewhere) and played through Web
/// Audio. Where the browser has WebAuthn, a passkey with the PRF extension
/// can replace typing the passphrase.
Future<Widget> buildHome() async {
  final sodium = await SodiumSumoInit.init();
  final sqlite = await WasmSqlite3.loadFromUrl(Uri.parse('sqlite3.wasm'));
  final storage = await IndexedDbFileSystem.open(dbName: _storageName);
  sqlite.registerVirtualFileSystem(storage, makeDefault: true);
  // Writes reach IndexedDB in the background; push them out before the tab
  // can be closed or frozen.
  AppLifecycleListener(onHide: storage.flush, onPause: storage.flush);
  final opus = await WebCodecsOpusEncoder.isSupported();
  final opusPlayback = await WebCodecsOpusDecoder.isSupported();
  final player = WebAudioRecordingPlayer();
  final passkeys = await WebAuthnPasskeyPrf.isSupported()
      ? WebAuthnPasskeyPrf(sodium)
      : null;
  final cloud = cloudWiring(SyncConfig.fromEnvironment());
  return VaultShelfGate(
    store: SqliteShelfStore(sqlite.open('/$shelfDatabaseName')),
    open: (entry) async {
      final names = vaultStorageNames(entry.id);
      final path = '/${names.database}';
      final database = sqlite.open(path);
      final blobName = entry.id == ShelfId.first
          ? IndexedDbCiphertextBlobStore.defaultName
          : '${IndexedDbCiphertextBlobStore.defaultName}-${entry.id}';
      final blobStore = await IndexedDbCiphertextBlobStore.open(name: blobName);
      // Takes cut off by a closed tab are partial ciphertext: drop them.
      await blobStore.discardIncomplete();
      final keeper = vaultKeeper(
        sodium: sodium,
        database: database,
        kdf: KdfParameters.moderate,
        server: cloud.server,
        passkeys: passkeys,
      );
      return ShelfVault(
        build: (switcher) => _gate(
          sodium: sodium,
          keeper: keeper,
          blobStore: blobStore,
          player: player,
          cloud: cloud,
          opus: opus,
          opusPlayback: opusPlayback,
          switcher: switcher,
        ),
        isEmpty: () async => !await keeper.exists,
        close: () async {
          database.close();
          blobStore.close();
        },
        erase: () async {
          database.close();
          blobStore.close();
          for (final file in [path, '$path-journal']) {
            if (storage.xAccess(file, 0) != 0) storage.xDelete(file, 0);
          }
          await storage.flush();
          await IndexedDbCiphertextBlobStore.deleteDatabase(blobName);
        },
      );
    },
  );
}

VaultGate _gate({
  required SodiumSumo sodium,
  required VaultKeeper keeper,
  required IndexedDbCiphertextBlobStore blobStore,
  required WebAudioRecordingPlayer player,
  required CloudWiring cloud,
  required bool opus,
  required bool opusPlayback,
  required ShelfSwitcher switcher,
}) {
  final blobs = EncryptedBlobStorage(
    store: blobStore,
    encryptor: SodiumEnvelopeEncryptor(sodium),
    subkeys: SodiumSubkeyDerivationService(sodium),
  );
  return VaultGate(
    keeper: keeper,
    account: cloud.account,
    switcher: switcher,
    sharedBlobsFor: cloud.remoteBlobs == null
        ? null
        : (engine) {
            final remote = cloud.remoteBlobs!(engine.ledger.workspace.id.hex);
            return (
              replication: BlobReplication(local: blobStore, remote: remote),
              pruning: BlobPruning(remote: remote),
            );
          },
    passwordFrom: (bytes) => SodiumPasswordSecret.fromUtf8Bytes(sodium, bytes),
    catalog: SeedSchemas.catalog,
    files: BrowserFileExchange(),
    recorderFor: (engine) => NoteRecorder(
      capture: () => StreamingAudioCapture(
        microphone: RecordPcmMicrophone(),
        encoder: opus
            ? WebCodecsOpusEncoder()
            : const WavStreamEncoder(sampleRate: 48000),
      ),
      blobs: blobs,
      engine: engine,
    ),
    imagesFor: (engine, ensureLocal) => NoteImages(
      blobs: blobs,
      engine: engine,
      chooser: BrowserImageChooser(),
      ensureLocal: ensureLocal,
    ),
    playbackFor: (engine, ensureLocal) => NotePlayback(
      decoding: RecordingPlayback(
        storage: blobs,
        // Without WebCodecs a phone's Opus take cannot play here; the note
        // says so instead of failing.
        decoders: [
          if (opusPlayback) const WebCodecsOpusDecoder(),
          const WavAudioDecoder(),
        ],
      ),
      engine: engine,
      player: player,
      ensureLocal: ensureLocal,
    ),
  );
}

/// One IndexedDB database per origin holds the vault file.
const _storageName = 'modusnote';
