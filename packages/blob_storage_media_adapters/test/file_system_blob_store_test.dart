import 'dart:typed_data';

import 'package:blob_storage_media/blob_storage_media.dart';
import 'package:blob_storage_media_adapters/blob_storage_media_adapters.dart';
import 'package:file/file.dart';
import 'package:file/local.dart';
import 'package:file/memory.dart';
import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:identity_cryptography_adapters/identity_cryptography_adapters.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:test/test.dart';

Uint8List bytes(int length, [int seed = 7]) => Uint8List.fromList([
  for (var i = 0; i < length; i++) (i * 31 + seed) & 0xFF,
]);

Future<Uint8List> collect(Stream<List<int>> stream) async {
  final builder = BytesBuilder(copy: false);
  await for (final piece in stream) {
    builder.add(piece);
  }
  return builder.takeBytes();
}

void main() {
  for (final (name, makeRoot) in [
    (
      'memory file system',
      () async => MemoryFileSystem.test().directory('/cache/blobs'),
    ),
    (
      'local file system',
      () async => const LocalFileSystem().systemTempDirectory.createTemp(
        'modusnote_blobs_',
      ),
    ),
  ]) {
    group(name, () {
      late Directory root;
      late FileSystemCiphertextBlobStore store;
      final id = BlobId('blob-1');

      setUp(() async {
        root = await makeRoot();
        store = FileSystemCiphertextBlobStore(root);
      });
      tearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });

      List<String> filesOnDisk() => root.existsSync()
          ? [
              for (final entity in root.listSync())
                entity.fileSystem.path.basename(entity.path),
            ]
          : const [];

      Future<void> put(BlobId blob, Uint8List content) async {
        final writer = await store.create(blob);
        await writer.add(
          Uint8List.sublistView(content, 0, content.length ~/ 2),
        );
        await writer.add(Uint8List.sublistView(content, content.length ~/ 2));
        await writer.commit();
      }

      test('a committed blob reads back byte for byte', () async {
        final content = bytes(200000);
        await put(id, content);

        expect(await store.contains(id), isTrue);
        expect(await collect(store.read(id)), content);
        expect(filesOnDisk(), ['blob-1.enc']);
      });

      test('an uncommitted write is invisible to readers', () async {
        final writer = await store.create(id);
        await writer.add(bytes(10));

        expect(await store.contains(id), isFalse);
        expect(
          () => collect(store.read(id)),
          throwsA(isA<BlobNotFoundException>()),
        );
        await writer.abort();
      });

      test('abort removes everything written so far', () async {
        final writer = await store.create(id);
        await writer.add(bytes(1000));
        await writer.abort();

        expect(filesOnDisk(), isEmpty);
      });

      test(
        'a blob id cannot be created twice, committed or in flight',
        () async {
          final writer = await store.create(id);
          await expectLater(
            store.create(id),
            throwsA(isA<BlobAlreadyExistsException>()),
          );
          await writer.commit();
          await expectLater(
            store.create(id),
            throwsA(isA<BlobAlreadyExistsException>()),
          );
        },
      );

      test('delete removes the file; deleting twice is harmless', () async {
        await put(id, bytes(10));
        await store.delete(id);
        await store.delete(id);

        expect(await store.contains(id), isFalse);
        expect(filesOnDisk(), isEmpty);
      });

      test(
        'discardIncomplete drops crashed writes and keeps committed ones',
        () async {
          await put(BlobId('kept'), bytes(10));
          // A write the app never finished: killed mid-recording.
          await (await store.create(BlobId('crashed'))).add(bytes(10));
          final restarted = FileSystemCiphertextBlobStore(root);
          await restarted.discardIncomplete();

          expect(filesOnDisk(), ['kept.enc']);
          expect(await restarted.contains(BlobId('kept')), isTrue);
        },
      );

      test('reading a missing blob is BlobNotFound', () async {
        await expectLater(
          collect(store.read(BlobId('missing'))),
          throwsA(isA<BlobNotFoundException>()),
        );
      });
    });
  }

  group('adversary', () {
    late SodiumSumo sodium;
    late MemoryFileSystem fs;
    late Directory root;
    late EncryptedBlobStorage storage;
    late SymmetricKey contentKey;

    setUpAll(() async => sodium = await SodiumSumoInit.init());
    setUp(() {
      fs = MemoryFileSystem.test();
      root = fs.directory('/cache/blobs');
      storage = EncryptedBlobStorage(
        store: FileSystemCiphertextBlobStore(root),
        encryptor: SodiumEnvelopeEncryptor(sodium),
        subkeys: SodiumSubkeyDerivationService(sodium),
      );
      contentKey = SodiumEnvelopeEncryptor(sodium).generateKey();
    });
    tearDown(() => contentKey.dispose());

    /// Every byte under the whole file system, wherever an adapter or a
    /// temp file might have put it.
    Uint8List everythingOnDisk() => Uint8List.fromList([
      for (final entity in fs.directory('/').listSync(recursive: true))
        if (entity is File) ...entity.readAsBytesSync(),
    ]);

    bool containsRun(Uint8List haystack, Uint8List needle) {
      const window = 32;
      outer:
      for (var i = 0; i + window <= haystack.length; i++) {
        for (var j = 0; j < window; j++) {
          if (haystack[i + j] != needle[j]) continue outer;
        }
        return true;
      }
      return false;
    }

    test('no plaintext is ever on disk, during or after a recording', () async {
      final spoken = bytes(3 * ChunkLayout.plaintextChunkBytes + 11);
      final seen = <Uint8List>[];
      Stream<List<int>> recorder() async* {
        for (var offset = 0; offset < spoken.length; offset += 9000) {
          final end = offset + 9000 < spoken.length
              ? offset + 9000
              : spoken.length;
          yield Uint8List.sublistView(spoken, offset, end);
          await Future<void>.delayed(Duration.zero);
          seen.add(everythingOnDisk());
        }
      }

      final blob = await storage.write(
        recorder(),
        id: BlobId('take-1'),
        contentKey: contentKey,
      );
      seen.add(everythingOnDisk());

      for (final snapshot in seen) {
        expect(containsRun(snapshot, spoken), isFalse);
      }
      expect(await collect(storage.read(blob, contentKey: contentKey)), spoken);
    });

    test(
      'a recording interrupted by a crash leaves only ciphertext, then nothing',
      () async {
        final spoken = bytes(2 * ChunkLayout.plaintextChunkBytes);
        Stream<List<int>> crashing() async* {
          yield spoken;
          throw StateError('app killed');
        }

        await expectLater(
          storage.write(
            crashing(),
            id: BlobId('take-2'),
            contentKey: contentKey,
          ),
          throwsStateError,
        );

        expect(root.listSync(), isEmpty);
      },
    );

    test(
      'a corrupted file on disk fails authentication, not the app',
      () async {
        final blob = await storage.write(
          Stream.value(bytes(5000)),
          id: BlobId('take-3'),
          contentKey: contentKey,
        );
        final file = root.childFile('take-3.enc');
        final damaged = file.readAsBytesSync()..[100] ^= 0x01;
        file.writeAsBytesSync(damaged);

        await expectLater(
          collect(storage.read(blob, contentKey: contentKey)),
          throwsA(isA<AuthenticationTagMismatchException>()),
        );
      },
    );

    test(
      'a half-written file from a crash is truncation, not a crash',
      () async {
        final blob = await storage.write(
          Stream.value(bytes(ChunkLayout.plaintextChunkBytes + 9)),
          id: BlobId('take-4'),
          contentKey: contentKey,
        );
        final file = root.childFile('take-4.enc');
        file.writeAsBytesSync(file.readAsBytesSync().sublist(0, 65000));

        await expectLater(
          collect(storage.read(blob, contentKey: contentKey)),
          throwsA(isA<TruncatedBlobException>()),
        );
      },
    );

    test('blob ids cannot name a path outside the blob directory', () {
      for (final hostile in ['../escape', '/etc/passwd', 'a/b', r'..\x', '.']) {
        expect(
          () => BlobId(hostile),
          throwsA(isA<InvalidSchemaException>()),
          reason: hostile,
        );
      }
    });
  });
}
