import 'dart:typed_data';

import 'package:blob_storage_media/blob_storage_media.dart';
import 'package:blob_storage_media_adapters/blob_storage_media_adapters.dart';
import 'package:file/memory.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:identity_cryptography_adapters/identity_cryptography_adapters.dart';
import 'package:modusnote/attachments/note_images.dart';
import 'package:modusnote/audio/note_playback.dart';
import 'package:modusnote/audio/note_recorder.dart';
import 'package:modusnote/sync/blob_sync.dart';
import 'package:modusnote/vault/vault_note_store.dart';
import 'package:offline_sync/offline_sync.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import '../audio/fake_capture.dart';
import '../notes/image_support.dart';
import '../vault/support.dart';

/// The workspace's shared storage in memory.
final class MemoryRemote implements RemoteBlobStore {
  final objects = <BlobId, Uint8List>{};
  final uploads = <BlobId>[];
  var online = true;

  @override
  Future<void> upload(
    BlobId id,
    Stream<Uint8List> ciphertext, {
    required int length,
  }) async {
    if (!online) throw const RemoteBlobUnavailableException();
    uploads.add(id);
    final bytes = BytesBuilder();
    await for (final piece in ciphertext) {
      bytes.add(piece);
    }
    objects.putIfAbsent(id, bytes.takeBytes);
  }

  @override
  Stream<Uint8List> download(BlobId id) async* {
    if (!online) throw const RemoteBlobUnavailableException();
    final bytes = objects[id];
    if (bytes == null) throw BlobNotFoundException(id);
    yield bytes;
  }
}

/// One device's blobs: its own disk, the shared remote.
final class DeviceBlobs {
  DeviceBlobs(MemoryRemote remote) {
    final local = FileSystemCiphertextBlobStore(files.directory('/blobs'));
    storage = EncryptedBlobStorage(
      store: local,
      encryptor: SodiumEnvelopeEncryptor(sodium),
      subkeys: SodiumSubkeyDerivationService(sodium),
    );
    replication = BlobReplication(local: local, remote: remote);
  }

  final files = MemoryFileSystem();
  late final EncryptedBlobStorage storage;
  late final BlobReplication replication;

  /// The sealed device setting, as the vault would keep it.
  Uint8List? setting;

  BlobSync sync(VaultNoteStore store) => BlobSync(
    replication: replication,
    blobs: () => store.blobs,
    load: () async => setting,
    save: (value) async => setting = value,
  );
}

DynamicEntry songWith(String id, BlobId track) => switch (DynamicEntry.create(
  schema: SeedSchemas.songSketchV1,
  id: EntryId(id),
  attributes: {
    FieldKey('title'): const TextValue('Ritornello'),
    FieldKey('guide_track'): AudioBlobValue(track),
  },
  at: DateTime.utc(2026, 10, 13),
)) {
  Valid(:final value) => value,
  Invalid(:final violations) => throw StateError('$violations'),
};

const noteId = '0123456789abcdef0123456789abcdef';

void main() {
  setUpAll(loadSodium);
  late UnlockedVault vault;
  late MemoryRemote remote;
  late DeviceBlobs phone;
  late VaultNoteStore store;
  late KeyedRecording take;

  setUp(() async {
    final database = memoryDatabase();
    addTearDown(database.close);
    vault = await keeperOn(database).create(passphrase('frase lunga'));
    addTearDown(vault.lock);
    remote = MemoryRemote();
    phone = DeviceBlobs(remote);
    final recorder = NoteRecorder(
      capture: () => FakeCapture(voice(6000)),
      blobs: phone.storage,
      engine: vault.engine,
    );
    store = await VaultNoteStore.open(
      vault.engine,
      catalog: SeedSchemas.catalog,
      recorder: recorder,
    );
    take = await (await recorder.start()).stop();
    await store.save(songWith(noteId, take.id), takes: [take]);
  });

  test('a recording goes up once, after the notes', () async {
    final sync = phone.sync(store);

    await sync.uploadPending();
    await sync.uploadPending();

    expect(remote.uploads, [take.id]);
    expect(
      remote.objects[take.id],
      phone.files.file('/blobs/${take.id.value}.enc').readAsBytesSync(),
    );
  });

  test('what went up is remembered across restarts', () async {
    await phone.sync(store).uploadPending();

    await phone.sync(store).uploadPending();

    expect(remote.uploads, hasLength(1));
  });

  test('offline, the recording waits for the next sync', () async {
    remote.online = false;
    final sync = phone.sync(store);

    await expectLater(
      sync.uploadPending(),
      throwsA(isA<RemoteBlobUnavailableException>()),
    );
    remote.online = true;
    await sync.uploadPending();

    expect(remote.objects.keys, [take.id]);
  });

  test('another device downloads it on the first play', () async {
    await phone.sync(store).uploadPending();
    final tablet = DeviceBlobs(remote);
    final tabletSync = tablet.sync(store);
    final decoder = FakeDecoder();
    final playback = NotePlayback(
      decoding: RecordingPlayback(storage: tablet.storage, decoders: [decoder]),
      engine: vault.engine,
      player: FakePlayer(),
      ensureLocal: tabletSync.ensureLocal,
    );

    await playback.open(take);

    expect(decoder.heard.single, voice(6000));
    // Already on the server: the tablet never sends it back.
    await tabletSync.uploadPending();
    expect(remote.uploads, hasLength(1));
  });

  test('a picture goes up and comes down like a recording', () async {
    final phoneImages = NoteImages(
      blobs: phone.storage,
      engine: vault.engine,
      chooser: FakeChooser(),
    );
    final image = (await phoneImages.choose())!;
    final page = switch (DynamicEntry.create(
      schema: SeedSchemas.documentV1,
      id: EntryId('d' * 32),
      attributes: {
        FieldKey('title'): const TextValue('Pagina'),
        FieldKey('attachments'): AttachmentsValue([ImageAttachment(image.id)]),
      },
      at: DateTime.utc(2026, 10, 13),
    )) {
      Valid(:final value) => value,
      Invalid(:final violations) => throw StateError('$violations'),
    };
    await store.save(page, pictures: [image]);

    await phone.sync(store).uploadPending();
    expect(remote.uploads, containsAll([take.id, image.id]));

    final tablet = DeviceBlobs(remote);
    final tabletImages = NoteImages(
      blobs: tablet.storage,
      engine: vault.engine,
      chooser: FakeChooser(),
      ensureLocal: tablet.sync(store).ensureLocal,
    );
    expect(await tabletImages.open(store.imageOf(image.id)!), pixel);
  });

  test('a recording not uploaded yet says so', () async {
    final tablet = DeviceBlobs(remote);
    final playback = NotePlayback(
      decoding: RecordingPlayback(
        storage: tablet.storage,
        decoders: [FakeDecoder()],
      ),
      engine: vault.engine,
      player: FakePlayer(),
      ensureLocal: tablet.sync(store).ensureLocal,
    );

    await expectLater(
      playback.open(take),
      throwsA(isA<BlobNotFoundException>()),
    );
  });

  group('adversary', () {
    test(
      'a damaged memory of uploads only costs a harmless re-upload',
      () async {
        await phone.sync(store).uploadPending();
        phone.setting = Uint8List.fromList([0xff, 0xfe, 0x0a, 0x00]);

        await phone.sync(store).uploadPending();

        expect(remote.uploads, hasLength(2));
        expect(remote.objects, hasLength(1));
      },
    );

    test('the server sees ciphertext only', () async {
      await phone.sync(store).uploadPending();

      final stored = remote.objects[take.id]!;
      final needle = voice(6000).sublist(0, 16);
      var found = false;
      for (var i = 0; i + needle.length <= stored.length && !found; i++) {
        var match = true;
        for (var j = 0; j < needle.length && match; j++) {
          match = stored[i + j] == needle[j];
        }
        found = match;
      }
      expect(found, isFalse);
    });
  });
}
