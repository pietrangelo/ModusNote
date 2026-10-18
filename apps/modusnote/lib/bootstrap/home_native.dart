import 'dart:io';

import 'package:blob_storage_media/blob_storage_media.dart';
import 'package:blob_storage_media_adapters/blob_storage_media_adapters.dart';
import 'package:blob_storage_media_recorder_adapters/blob_storage_media_recorder_adapters.dart';
import 'package:file/local.dart';

import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:identity_cryptography_adapters/identity_cryptography_adapters.dart';
import 'package:offline_sync/offline_sync.dart';
import 'package:offline_sync_adapters/offline_sync_adapters.dart';
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
import '../appearance/theme_memory.dart';
import 'home.dart' show AppHome;
import '../vault/vault_shelf_gate.dart';
import 'gallery_image_chooser.dart';
import 'local_reminder_scheduler.dart';
import 'vault_wiring.dart';

/// libsodium is built by the `sodium` package's build hook and loaded once
/// here. Every vault of the device ([VaultShelf]) lives in its own SQLite
/// file in the app's private support directory, which holds only envelopes
/// and the sealed vault header, and its recordings and pictures are `.enc`
/// blobs in a folder of its own beside it.
Future<AppHome> buildHome() async {
  final sodium = await SodiumSumoInit.init();
  final directory = (await getApplicationSupportDirectory()).path;
  final player = SoloudRecordingPlayer();
  final cloud = cloudWiring(SyncConfig.fromEnvironment());
  final shelf = sqlite3.open('$directory/$shelfDatabaseName');
  final home = VaultShelfGate(
    store: SqliteShelfStore(shelf),
    open: (entry) async {
      final names = vaultStorageNames(entry.id);
      final path = '$directory/${names.database}';
      final database = sqlite3.open(path);
      final blobFolder = const LocalFileSystem().directory(
        '$directory/${names.blobs}',
      );
      final blobStore = FileSystemCiphertextBlobStore(blobFolder);
      // Takes interrupted by a crash or a kill are partial ciphertext: drop
      // them.
      await blobStore.discardIncomplete();
      final keeper = vaultKeeper(
        sodium: sodium,
        database: database,
        kdf: KdfParameters.moderate,
        server: cloud.server,
      );
      return ShelfVault(
        build: (switcher) => _gate(
          sodium: sodium,
          keeper: keeper,
          blobStore: blobStore,
          player: player,
          cloud: cloud,
          scope: entry.scope,
          switcher: switcher,
        ),
        isEmpty: () async => !await keeper.exists,
        close: () async => database.close(),
        erase: () async {
          database.close();
          for (final suffix in const ['', '-wal', '-shm', '-journal']) {
            final file = File('$path$suffix');
            if (await file.exists()) await file.delete();
          }
          if (await blobFolder.exists()) {
            await blobFolder.delete(recursive: true);
          }
        },
      );
    },
  );
  return (home: home, themes: SqliteThemeMemory(shelf));
}

VaultGate _gate({
  required SodiumSumo sodium,
  required VaultKeeper keeper,
  required CiphertextBlobStore blobStore,
  required SoloudRecordingPlayer player,
  required CloudWiring cloud,
  required int scope,
  required ShelfSwitcher switcher,
}) {
  final blobs = EncryptedBlobStorage(
    store: blobStore,
    encryptor: SodiumEnvelopeEncryptor(sodium),
    subkeys: SodiumSubkeyDerivationService(sodium),
    hasher: SodiumContentHasher(sodium),
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
              replication: BlobReplication(
                local: blobStore,
                remote: remote,
                hasher: SodiumContentHasher(sodium),
              ),
              pruning: BlobPruning(remote: remote),
            );
          },
    passwordFrom: (bytes) => SodiumPasswordSecret.fromUtf8Bytes(sodium, bytes),
    catalog: SeedSchemas.catalog,
    remindersFor: (l10n) => LocalReminderScheduler(
      channel: l10n.reminderChannel,
      description: l10n.reminderChannelDescription,
      journalChannel: l10n.journalReminderChannel,
      journalDescription: l10n.journalReminderChannelDescription,
      scope: scope,
    ),
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
