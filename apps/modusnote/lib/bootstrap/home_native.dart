import 'package:blob_storage_media/blob_storage_media.dart';
import 'package:blob_storage_media_adapters/blob_storage_media_adapters.dart';
import 'package:blob_storage_media_recorder_adapters/blob_storage_media_recorder_adapters.dart';
import 'package:file/local.dart';

import 'package:flutter/widgets.dart';
import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:identity_cryptography_adapters/identity_cryptography_adapters.dart';
import 'package:path_provider/path_provider.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:sqlite3/sqlite3.dart';

import '../attachments/note_images.dart';
import '../audio/note_playback.dart';
import '../audio/note_recorder.dart';
import '../sync/sync_config.dart';
import '../audio/soloud_player.dart';
import '../vault/vault_gate.dart';
import 'gallery_image_chooser.dart';
import 'vault_wiring.dart';

/// libsodium is built by the `sodium` package's build hook and loaded once
/// here; the vault lives in one SQLite file in the app's private support
/// directory, which holds only envelopes and the sealed vault header, and
/// recordings and pictures are `.enc` blobs beside it.
Future<Widget> buildHome() async {
  final sodium = await SodiumSumoInit.init();
  final directory = await getApplicationSupportDirectory();
  final database = sqlite3.open('${directory.path}/vault.sqlite');
  final blobStore = FileSystemCiphertextBlobStore(
    const LocalFileSystem().directory('${directory.path}/blobs'),
  );
  // Takes interrupted by a crash or a kill are partial ciphertext: drop them.
  await blobStore.discardIncomplete();
  final blobs = EncryptedBlobStorage(
    store: blobStore,
    encryptor: SodiumEnvelopeEncryptor(sodium),
    subkeys: SodiumSubkeyDerivationService(sodium),
  );
  final player = SoloudRecordingPlayer();
  final cloud = cloudWiring(SyncConfig.fromEnvironment());
  return VaultGate(
    keeper: vaultKeeper(
      sodium: sodium,
      database: database,
      kdf: KdfParameters.moderate,
      server: cloud.server,
    ),
    account: cloud.account,
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
    recorderFor: (engine) => NoteRecorder(
      capture: createPlatformAudioCapture,
      blobs: blobs,
      engine: engine,
    ),
    imagesFor: (engine, ensureLocal) => NoteImages(
      blobs: blobs,
      engine: engine,
      chooser: GalleryImageChooser(),
      ensureLocal: ensureLocal,
    ),
    playbackFor: (engine, ensureLocal) => NotePlayback(
      decoding: RecordingPlayback(
        storage: blobs,
        // Web takes are WAV; everything recorded here is Ogg Opus.
        decoders: const [OpusAudioDecoder(), WavAudioDecoder()],
      ),
      engine: engine,
      player: player,
      ensureLocal: ensureLocal,
    ),
  );
}
