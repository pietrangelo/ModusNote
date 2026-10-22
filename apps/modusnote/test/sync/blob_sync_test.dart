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
  final storedAt = <BlobId, DateTime>{};
  final uploads = <BlobId>[];
  final deletions = <BlobId>[];
  var listings = 0;
  var online = true;

  /// When uploads happen, as R2 would stamp them.
  DateTime now = DateTime.utc(2026, 10, 13, 9);

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
    storedAt.putIfAbsent(id, () => now);
  }

  @override
  Future<void> delete(List<BlobId> ids) async {
    if (!online) throw const RemoteBlobUnavailableException();
    deletions.addAll(ids);
    for (final id in ids) {
      objects.remove(id);
      storedAt.remove(id);
    }
  }

  @override
  Future<StoredBlobPage> list({String? after}) async {
    if (!online) throw const RemoteBlobUnavailableException();
    listings++;
    return StoredBlobPage([
      for (final MapEntry(:key, :value) in storedAt.entries)
        StoredBlob(key, storedAt: value),
    ]);
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
      hasher: SodiumContentHasher(sodium),
    );
    replication = BlobReplication(
      local: local,
      remote: remote,
      hasher: SodiumContentHasher(sodium),
    );
    pruning = BlobPruning(remote: remote);
  }

  final files = MemoryFileSystem();
  late final EncryptedBlobStorage storage;
  late final BlobReplication replication;
  late final BlobPruning pruning;

  /// The sealed device settings, as the vault would keep them.
  final settings = <String, Uint8List?>{};

  /// What the device's clock says.
  DateTime now = DateTime.utc(2026, 10, 13, 9);

  /// Whether the vault agrees with the server, as the gate would tell.
  var unsent = false;
  var unreadable = false;

  BlobSync sync(VaultNoteStore store) => BlobSync(
    replication: replication,
    pruning: pruning,
    blobs: () => store.blobs,
    canPrune: () => !unreadable,
    unsentWrites: () async => unsent,
    clock: () => now,
    load: (name) async => settings[name],
    save: (name, value) async => settings[name] = value,
  );

  /// Wires [store] as the gate does: what its notes let go of is released.
  BlobSync attach(VaultNoteStore store) {
    final sync = this.sync(store);
    store.onRelease = sync.release;
    return sync;
  }
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

  test('a new server gets every recording again, once', () async {
    await phone.sync(store).afterSync();
    remote.objects.clear();

    await phone.sync(store).afterSync(moved: true);
    await phone.sync(store).afterSync();

    expect(remote.uploads, [take.id, take.id]);
    expect(remote.objects.keys, [take.id]);
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
    // Not held here yet: nothing to send, and it stays known as such.
    await tabletSync.uploadPending();
    expect(remote.uploads, hasLength(1));

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

  group('deleting on the server', () {
    late BlobSync sync;

    setUp(() async {
      sync = phone.attach(store);
      await sync.afterSync();
      expect(remote.objects.keys, [take.id]);
    });

    test('a note deleted for good takes its recording with it', () async {
      await store.moveToTrash(EntryId(noteId));
      await sync.afterSync();
      expect(remote.objects.keys, [take.id], reason: 'the trash keeps it');

      await store.deleteForever(EntryId(noteId));
      await sync.afterSync();

      expect(remote.objects, isEmpty);
      expect(remote.deletions, [take.id]);
      // Nothing left to remember about it.
      await sync.afterSync();
      expect(remote.deletions, [take.id]);
    });

    test('a recording removed from a note goes too', () async {
      final emptied = switch (DynamicEntry.create(
        schema: SeedSchemas.songSketchV1,
        id: EntryId(noteId),
        attributes: {FieldKey('title'): const TextValue('Ritornello')},
        at: DateTime.utc(2026, 10, 14),
      )) {
        Valid(:final value) => value,
        Invalid(:final violations) => throw StateError('$violations'),
      };
      await store.save(emptied);

      await sync.afterSync();

      expect(remote.objects, isEmpty);
    });

    test('offline, the deletion waits for the next sync', () async {
      await store.moveToTrash(EntryId(noteId));
      await store.deleteForever(EntryId(noteId));
      remote.online = false;
      await expectLater(
        sync.prune(),
        throwsA(isA<RemoteBlobUnavailableException>()),
      );

      remote.online = true;
      await phone.sync(store).afterSync();

      expect(remote.objects, isEmpty);
    });

    test('nothing goes while edits still wait for the server', () async {
      await store.moveToTrash(EntryId(noteId));
      await store.deleteForever(EntryId(noteId));
      phone.unsent = true;

      await sync.afterSync();
      expect(remote.objects.keys, [take.id]);

      phone.unsent = false;
      await sync.afterSync();
      expect(remote.objects, isEmpty);
    });

    test('a sweep deletes old blobs no note references, once a day', () async {
      // A day after the sweep of setUp, remembered across unlocks.
      phone.now = phone.now.add(const Duration(days: 1));
      // Left by a device that deleted a note before this feature.
      remote.objects[BlobId('left-behind')] = Uint8List(41);
      remote.storedAt[BlobId('left-behind')] = DateTime.utc(2026, 10, 1);
      // Uploaded an hour ago by a device whose note this one has not
      // pulled yet.
      remote.objects[BlobId('just-uploaded')] = Uint8List(41);
      remote.storedAt[BlobId('just-uploaded')] = phone.now.subtract(
        const Duration(hours: 1),
      );
      final listings = remote.listings;

      await phone.attach(store).afterSync();

      expect(remote.objects.keys, {take.id, BlobId('just-uploaded')});
      expect(remote.listings, listings + 1);

      // A new unlock remembers the last sweep.
      final later = phone.attach(store);
      await later.afterSync();
      phone.now = phone.now.add(const Duration(hours: 2));
      await later.afterSync();
      expect(remote.listings, listings + 1, reason: 'once per day');

      phone.now = phone.now.add(const Duration(days: 1));
      await later.afterSync();
      expect(remote.objects.keys, [take.id]);
    });
  });

  group('adversary', () {
    test('nothing is deleted while a note this app cannot read exists, '
        'since it may reference blobs this app does not see', () async {
      final sync = phone.attach(store);
      await sync.afterSync();
      remote.objects[BlobId('newer-app')] = Uint8List(41);
      remote.storedAt[BlobId('newer-app')] = DateTime.utc(2026, 10, 1);
      await store.moveToTrash(EntryId(noteId));
      await store.deleteForever(EntryId(noteId));
      phone.unreadable = true;

      await phone.attach(store).afterSync();

      expect(remote.deletions, isEmpty);
    });

    test('a released blob a note takes back is kept', () async {
      final sync = phone.attach(store);
      await sync.afterSync();
      await sync.release([take.id]);

      await sync.afterSync();

      expect(remote.objects.keys, [take.id]);
      expect(remote.deletions, isEmpty);
    });

    test('a damaged list of released blobs deletes nothing it names '
        'wrongly', () async {
      final sync = phone.attach(store);
      await sync.afterSync();
      phone.settings[BlobSync.releasedSetting] = Uint8List.fromList(
        '../other\n${take.id.value}\n\xff'.codeUnits,
      );

      await phone.attach(store).afterSync();

      expect(remote.objects.keys, [take.id]);
      expect(phone.settings[BlobSync.releasedSetting], isEmpty);
    });

    test(
      'a damaged memory of uploads only costs a harmless re-upload',
      () async {
        await phone.sync(store).uploadPending();
        phone.settings[BlobSync.sentSetting] = Uint8List.fromList([
          0xff,
          0xfe,
          0x0a,
          0x00,
        ]);

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
