import 'dart:async';
import 'dart:typed_data';

import 'package:blob_storage_media/blob_storage_media.dart';
import 'package:glados/glados.dart';
import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import 'support.dart';

const chunk = ChunkLayout.plaintextChunkBytes;

void main() {
  late InMemoryBlobStore store;
  late EncryptedBlobStorage storage;
  late SymmetricKey contentKey;
  final id = BlobId('blob-1');

  setUpAll(initSodium);
  setUp(() {
    store = InMemoryBlobStore();
    storage = EncryptedBlobStorage(
      store: store,
      encryptor: newEncryptor(),
      subkeys: newSubkeys(),
    );
    contentKey = newEncryptor().generateKey();
  });
  tearDown(() => contentKey.dispose());

  Future<SealedBlob> write(
    Uint8List plaintext, {
    List<int> pieces = const [4096],
  }) => storage.write(
    piecewise(plaintext, pieces),
    id: id,
    contentKey: contentKey,
  );

  Future<Uint8List> read(SealedBlob blob, {SymmetricKey? key}) =>
      collect(storage.read(blob, contentKey: key ?? contentKey));

  /// Rewrites the committed ciphertext, as a hostile server or a damaged
  /// disk would.
  void tamper(Uint8List Function(Uint8List) change) =>
      store.committed[id] = change(Uint8List.fromList(store.committed[id]!));

  List<Uint8List> framesOf(Uint8List ciphertext) {
    final frames = <Uint8List>[];
    var offset = 0;
    while (offset < ciphertext.length) {
      final length = ByteData.sublistView(ciphertext, offset).getUint32(0);
      final end = offset + ChunkLayout.lengthPrefixBytes + length;
      frames.add(Uint8List.sublistView(ciphertext, offset, end));
      offset = end;
    }
    return frames;
  }

  Uint8List joined(List<Uint8List> frames) =>
      Uint8List.fromList([for (final f in frames) ...f]);

  test(
    'read(write(audio)) returns the audio for chunk-boundary sizes',
    () async {
      for (final length in [
        0,
        1,
        chunk - 1,
        chunk,
        chunk + 1,
        3 * chunk + 17,
      ]) {
        store = InMemoryBlobStore();
        storage = EncryptedBlobStorage(
          store: store,
          encryptor: newEncryptor(),
          subkeys: newSubkeys(),
        );
        final plaintext = audio(length);
        final blob = await write(plaintext);

        expect(await read(blob), plaintext, reason: '$length bytes');
      }
    },
  );

  Glados2(
    any.intInRange(0, 3 * chunk),
    any.nonEmptyList(any.intInRange(1, 9000)),
  ).test('round-trips however the recorder slices its buffers', (
    length,
    pieces,
  ) async {
    final local = EncryptedBlobStorage(
      store: InMemoryBlobStore(),
      encryptor: newEncryptor(),
      subkeys: newSubkeys(),
    );
    final plaintext = audio(length);
    final blob = await local.write(
      piecewise(plaintext, pieces),
      id: id,
      contentKey: contentKey,
    );

    expect(await collect(local.read(blob, contentKey: contentKey)), plaintext);
  });

  test('the sealed blob records length, chunks and a fresh key id', () async {
    final blob = await write(audio(2 * chunk + 3));
    store.committed.clear();
    final other = await write(audio(10));

    expect(blob.id, id);
    expect(blob.plaintextLength, 2 * chunk + 3);
    expect(blob.chunkCount, 3);
    expect(other.keyId, isNot(blob.keyId));
  });

  test('stored bytes are exactly the predicted ciphertext length', () async {
    final blob = await write(audio(chunk + 100));

    expect(store.committed[id], hasLength(blob.ciphertextLength));
  });

  test('a blob id is written once; a second write is refused', () async {
    await write(audio(10));

    expect(() => write(audio(10)), throwsA(isA<BlobAlreadyExistsException>()));
  });

  test('delete removes the ciphertext', () async {
    await write(audio(10));
    await storage.delete(id);

    expect(await store.contains(id), isFalse);
  });

  group('adversary', () {
    test('a store handing back single bytes is read in linear time', () async {
      final plaintext = audio(2 * chunk + 999);
      final blob = await write(plaintext);
      store.readPiece = 1;

      // Joining the pending bytes on every piece took minutes here.
      final watch = Stopwatch()..start();
      expect(await read(blob), plaintext);
      expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
    });

    test(
      'no plaintext ever reaches the store, committed or in flight',
      () async {
        final plaintext = audio(2 * chunk + 999);
        await write(plaintext, pieces: [1, 700, 65536]);

        expect(leaks(store.everWritten.toBytes(), plaintext), isFalse);
      },
    );

    test(
      'a failing recorder aborts the write: nothing partial survives',
      () async {
        Stream<List<int>> failing() async* {
          yield audio(chunk + 5);
          throw StateError('microphone unplugged');
        }

        await expectLater(
          storage.write(failing(), id: id, contentKey: contentKey),
          throwsStateError,
        );
        expect(store.committed, isEmpty);
        expect(store.pending, isEmpty);
      },
    );

    test('flipping any single bit fails authentication', () async {
      final blob = await write(audio(chunk + 50));
      final original = Uint8List.fromList(store.committed[id]!);
      // Every byte of the second frame header and envelope prefix, plus a
      // spread of positions through both frames, skipping length prefixes
      // (covered by the framing tests below).
      final positions =
          {
            for (var i = 4; i < original.length; i += 997) i,
            for (var i = 0; i < 40; i++) original.length - 1 - i,
          }..removeWhere(
            (i) =>
                i < 4 ||
                (i >= framesOf(original).first.length &&
                    i < framesOf(original).first.length + 4),
          );
      for (final position in positions) {
        for (final bit in [0, 7]) {
          tamper(
            (bytes) => Uint8List.fromList(original)..[position] ^= 1 << bit,
          );

          await expectLater(
            read(blob),
            throwsA(
              anyOf(
                isA<AuthenticationTagMismatchException>(),
                isA<MalformedEnvelopeException>(),
              ),
            ),
            reason: 'byte $position bit $bit',
          );
        }
      }
    });

    test('a wrong content key fails authentication', () async {
      final blob = await write(audio(100));
      final stranger = newEncryptor().generateKey();

      await expectLater(
        read(blob, key: stranger),
        throwsA(isA<AuthenticationTagMismatchException>()),
      );
      stranger.dispose();
    });

    test('dropping the last chunk is detected as truncation', () async {
      final blob = await write(audio(2 * chunk + 1));
      tamper((bytes) {
        final frames = framesOf(bytes);
        return joined(frames.sublist(0, frames.length - 1));
      });

      await expectLater(read(blob), throwsA(isA<TruncatedBlobException>()));
    });

    test('a download cut mid-frame is detected as truncation', () async {
      final blob = await write(audio(chunk + 1));
      tamper((bytes) => bytes.sublist(0, bytes.length - 3));

      await expectLater(read(blob), throwsA(isA<TruncatedBlobException>()));
    });

    test('dropping the tail and lying about the length still fails', () async {
      final blob = await write(audio(2 * chunk + 1));
      tamper((bytes) => joined(framesOf(bytes).sublist(0, 2)));
      // The attacker also controls the metadata copy they hand back.
      final lie = SealedBlob(
        id: blob.id,
        keyId: blob.keyId,
        plaintextLength: 2 * chunk,
      );

      // Chunk 1 was sealed as "more", so it cannot pose as the final one.
      await expectLater(
        read(lie),
        throwsA(isA<AuthenticationTagMismatchException>()),
      );
    });

    test('swapping two chunks fails authentication', () async {
      final blob = await write(audio(3 * chunk));
      tamper((bytes) {
        final frames = framesOf(bytes);
        return joined([frames[1], frames[0], frames[2]]);
      });

      await expectLater(
        read(blob),
        throwsA(isA<AuthenticationTagMismatchException>()),
      );
    });

    test(
      'replaying a chunk in place of another fails authentication',
      () async {
        final blob = await write(audio(3 * chunk));
        tamper((bytes) {
          final frames = framesOf(bytes);
          return joined([frames[0], frames[0], frames[2]]);
        });

        await expectLater(
          read(blob),
          throwsA(isA<AuthenticationTagMismatchException>()),
        );
      },
    );

    test('a chunk spliced from another blob fails authentication', () async {
      final blob = await write(audio(2 * chunk));
      final otherId = BlobId('blob-2');
      await storage.write(
        piecewise(audio(2 * chunk), [chunk]),
        id: otherId,
        contentKey: contentKey,
      );
      final foreign = framesOf(store.committed[otherId]!);
      tamper((bytes) => joined([framesOf(bytes)[0], foreign[1]]));

      await expectLater(
        read(blob),
        throwsA(isA<AuthenticationTagMismatchException>()),
      );
    });

    test('an extra chunk after the final one is rejected', () async {
      final blob = await write(audio(chunk + 1));
      tamper((bytes) {
        final frames = framesOf(bytes);
        return joined([...frames, frames.last]);
      });

      await expectLater(read(blob), throwsA(isA<MalformedBlobException>()));
    });

    test(
      'a frame length beyond one chunk is rejected before buffering',
      () async {
        final blob = await write(audio(100));
        tamper((bytes) => bytes..buffer.asByteData().setUint32(0, 0xFFFFFFFF));

        await expectLater(read(blob), throwsA(isA<MalformedBlobException>()));
      },
    );

    test('a frame too short to hold an envelope is rejected', () async {
      final blob = await write(audio(100));
      tamper((bytes) => bytes..buffer.asByteData().setUint32(0, 3));

      await expectLater(read(blob), throwsA(isA<MalformedBlobException>()));
    });

    test('metadata claiming more audio than stored is truncation', () async {
      final blob = await write(audio(chunk));
      final lie = SealedBlob(
        id: blob.id,
        keyId: blob.keyId,
        plaintextLength: chunk + 1,
      );

      await expectLater(
        read(lie),
        throwsA(
          anyOf(
            isA<TruncatedBlobException>(),
            isA<AuthenticationTagMismatchException>(),
          ),
        ),
      );
    });

    test('reading a blob that was never committed is BlobNotFound', () async {
      await expectLater(
        read(
          SealedBlob(
            id: id,
            keyId: newSubkeys().newSubkeyId(),
            plaintextLength: 1,
          ),
        ),
        throwsA(isA<BlobNotFoundException>()),
      );
    });

    Glados(any.list(any.intInRange(0, 256))).test(
      'arbitrary garbage only ever raises domain exceptions',
      (garbage) async {
        final local = InMemoryBlobStore()
          ..committed[id] = Uint8List.fromList(garbage);
        final reader = EncryptedBlobStorage(
          store: local,
          encryptor: newEncryptor(),
          subkeys: newSubkeys(),
        );
        final blob = SealedBlob(
          id: id,
          keyId: newSubkeys().newSubkeyId(),
          plaintextLength: garbage.length,
        );

        await expectLater(
          collect(reader.read(blob, contentKey: contentKey)),
          throwsA(anyOf(isA<BlobException>(), isA<CryptographyException>())),
        );
      },
    );
  });
}
