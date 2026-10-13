import 'package:blob_storage_media/blob_storage_media.dart';
import 'package:blob_storage_media_adapters/audio_encoding.dart';
import 'package:blob_storage_media_adapters/web_media.dart';
import 'package:blob_storage_media_recorder_adapters/blob_storage_media_recorder_adapters.dart';
import 'package:flutter/widgets.dart';
import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:identity_cryptography_adapters/identity_cryptography_adapters.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:sqlite3/wasm.dart';

import '../audio/note_playback.dart';
import '../audio/note_recorder.dart';
import '../audio/web_audio_player.dart';
import '../vault/vault_gate.dart';
import 'vault_wiring.dart';

/// The browser is another vault device. libsodium arrives as `sodium.js`
/// (loaded by `index.html`), SQLite as `sqlite3.wasm`, both served from our
/// own origin. The database lives in IndexedDB and, as on mobile, holds only
/// the sealed vault header and envelopes: nothing readable without the
/// passphrase. Recordings are sealed blobs in a second IndexedDB database,
/// encoded to Ogg Opus by WebCodecs where the browser has it (WAV
/// elsewhere) and played through Web Audio.
Future<Widget> buildHome() async {
  final sodium = await SodiumSumoInit.init();
  final sqlite = await WasmSqlite3.loadFromUrl(Uri.parse('sqlite3.wasm'));
  final storage = await IndexedDbFileSystem.open(dbName: _storageName);
  sqlite.registerVirtualFileSystem(storage, makeDefault: true);
  final database = sqlite.open('/vault.sqlite');
  // Writes reach IndexedDB in the background; push them out before the tab
  // can be closed or frozen.
  AppLifecycleListener(onHide: storage.flush, onPause: storage.flush);
  final blobStore = await IndexedDbCiphertextBlobStore.open();
  // Takes cut off by a closed tab are partial ciphertext: drop them.
  await blobStore.discardIncomplete();
  final blobs = EncryptedBlobStorage(
    store: blobStore,
    encryptor: SodiumEnvelopeEncryptor(sodium),
    subkeys: SodiumSubkeyDerivationService(sodium),
  );
  final opus = await WebCodecsOpusEncoder.isSupported();
  final opusPlayback = await WebCodecsOpusDecoder.isSupported();
  final player = WebAudioRecordingPlayer();
  return VaultGate(
    keeper: vaultKeeper(
      sodium: sodium,
      database: database,
      kdf: KdfParameters.moderate,
    ),
    passwordFrom: (bytes) => SodiumPasswordSecret.fromUtf8Bytes(sodium, bytes),
    catalog: SeedSchemas.catalog,
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
    playbackFor: (engine) => NotePlayback(
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
    ),
  );
}

/// One IndexedDB database per origin holds the vault file.
const _storageName = 'modusnote';
