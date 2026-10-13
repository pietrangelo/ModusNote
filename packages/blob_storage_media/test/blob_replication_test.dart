import 'dart:async';
import 'dart:typed_data';

import 'package:blob_storage_media/blob_storage_media.dart';
import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';
import 'package:test/test.dart';

import 'support.dart';

/// The shared storage in memory: what was uploaded, byte for byte.
final class FakeRemote implements RemoteBlobStore {
  final objects = <BlobId, Uint8List>{};
  var online = true;
  var downloads = 0;

  /// Serves this instead of the stored object, as a hostile server would.
  Uint8List? Function(Uint8List? stored)? serve;

  /// Holds downloads until completed.
  Completer<void>? gate;

  @override
  Future<void> upload(
    BlobId id,
    Stream<Uint8List> ciphertext, {
    required int length,
  }) async {
    if (!online) throw const RemoteBlobUnavailableException();
    final bytes = await collect(ciphertext);
    expect(bytes, hasLength(length));
    objects.putIfAbsent(id, () => bytes);
  }

  @override
  Stream<Uint8List> download(BlobId id) async* {
    downloads++;
    if (!online) throw const RemoteBlobUnavailableException();
    await gate?.future;
    final stored = objects[id];
    final bytes = serve == null ? stored : serve!(stored);
    if (bytes == null) throw BlobNotFoundException(id);
    for (var offset = 0; offset < bytes.length; offset += 7000) {
      final end = offset + 7000 < bytes.length ? offset + 7000 : bytes.length;
      yield Uint8List.sublistView(bytes, offset, end);
    }
  }
}

void main() {
  late InMemoryBlobStore phone;
  late InMemoryBlobStore tablet;
  late FakeRemote remote;
  late SymmetricKey contentKey;
  final id = BlobId('take-1');
  final recording = audio(3 * ChunkLayout.plaintextChunkBytes + 1234);

  setUpAll(initSodium);
  setUp(() {
    phone = InMemoryBlobStore();
    tablet = InMemoryBlobStore();
    remote = FakeRemote();
    contentKey = newEncryptor().generateKey();
  });
  tearDown(() => contentKey.dispose());

  EncryptedBlobStorage storageOn(InMemoryBlobStore store) =>
      EncryptedBlobStorage(
        store: store,
        encryptor: newEncryptor(),
        subkeys: newSubkeys(),
      );

  Future<SealedBlob> record() =>
      storageOn(phone)
          .write(piecewise(recording, [4096]), id: id, contentKey: contentKey);

  BlobReplication on(InMemoryBlobStore store) =>
      BlobReplication(local: store, remote: remote);

  test('a recording uploaded by one device plays on another', () async {
    final blob = await record();

    await on(phone).upload(blob);
    await on(tablet).ensureLocal(blob);

    expect(
      await collect(storageOn(tablet).read(blob, contentKey: contentKey)),
      recording,
    );
  });

  test('the shared copy is the ciphertext the device holds', () async {
    final blob = await record();

    await on(phone).upload(blob);

    expect(remote.objects[id], phone.committed[id]);
    expect(
      remote.objects[id],
      hasLength(ChunkLayout.ciphertextLengthFor(recording.length)),
    );
  });

  test('a blob already on the device is not downloaded', () async {
    final blob = await record();
    await on(phone).upload(blob);

    await on(phone).ensureLocal(blob);

    expect(remote.downloads, 0);
  });

  test('uploading again keeps the first copy and is no error', () async {
    final blob = await record();
    await on(phone).upload(blob);
    final first = remote.objects[id];

    await on(phone).upload(blob);

    expect(remote.objects[id], same(first));
  });

  test('two plays at once share one download', () async {
    final blob = await record();
    await on(phone).upload(blob);
    remote.gate = Completer<void>();
    final replication = on(tablet);

    final a = replication.ensureLocal(blob);
    final b = replication.ensureLocal(blob);
    await Future<void>.delayed(Duration.zero);
    remote.gate!.complete();
    await Future.wait([a, b]);

    expect(remote.downloads, 1);
    expect(tablet.committed[id], remote.objects[id]);
  });

  test('a blob not uploaded yet is reported and leaves nothing', () async {
    final blob = await record();

    await expectLater(
      on(tablet).ensureLocal(blob),
      throwsA(isA<BlobNotFoundException>()),
    );
    expect(tablet.committed, isEmpty);
    expect(tablet.pending, isEmpty);
  });

  test('offline, nothing is written and a later try succeeds', () async {
    final blob = await record();
    await on(phone).upload(blob);
    remote.online = false;

    await expectLater(
      on(tablet).ensureLocal(blob),
      throwsA(isA<RemoteBlobUnavailableException>()),
    );
    expect(tablet.committed, isEmpty);
    remote.online = true;
    await on(tablet).ensureLocal(blob);

    expect(tablet.committed[id], remote.objects[id]);
  });

  group('adversary', () {
    test('a server cannot make the device store more than the blob', () async {
      final blob = await record();
      await on(phone).upload(blob);
      remote.serve = (stored) =>
          Uint8List.fromList([...stored!, ...List.filled(1 << 20, 0)]);

      await expectLater(
        on(tablet).ensureLocal(blob),
        throwsA(isA<MalformedBlobException>()),
      );
      expect(tablet.committed, isEmpty);
      expect(tablet.pending, isEmpty);
      expect(
        tablet.everWritten.length,
        lessThanOrEqualTo(ChunkLayout.ciphertextLengthFor(recording.length)),
      );
    });

    test('a cut download is not kept', () async {
      final blob = await record();
      await on(phone).upload(blob);
      remote.serve = (stored) => Uint8List.sublistView(stored!, 0, 100);

      await expectLater(
        on(tablet).ensureLocal(blob),
        throwsA(isA<TruncatedBlobException>()),
      );
      expect(tablet.committed, isEmpty);
    });

    test('a swapped blob of the right size is kept but never plays', () async {
      final blob = await record();
      await on(phone).upload(blob);
      // Another recording of the same length, re-served under this id.
      final elsewhere = InMemoryBlobStore();
      final other = await storageOn(elsewhere).write(
        piecewise(audio(recording.length), [4096]),
        id: id,
        contentKey: contentKey,
      );
      expect(other.plaintextLength, blob.plaintextLength);
      remote.objects[id] = elsewhere.committed[id]!;

      await on(tablet).ensureLocal(blob);

      await expectLater(
        collect(storageOn(tablet).read(blob, contentKey: contentKey)),
        throwsA(isA<AuthenticationTagMismatchException>()),
      );
    });
  });
}
