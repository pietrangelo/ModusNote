import 'dart:typed_data';

import 'package:blob_storage_media/blob_storage_media.dart';
import 'package:collaboration_access_control/collaboration_access_control.dart';
import 'package:glados/glados.dart';
import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import 'support.dart';

final at = DateTime.utc(2026, 10, 13, 19);
final later = DateTime.utc(2026, 10, 13, 20);

Uint8List be32(int v) => Uint8List(4)..buffer.asByteData().setUint32(0, v);

Uint8List png(int width, int height) => Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  ...be32(13), ...'IHDR'.codeUnits, ...be32(width), ...be32(height),
  8, 6, 0, 0, 0, ...List.filled(40, 0),
]);

Uint8List gif(int width, int height) => Uint8List.fromList([
  ...'GIF89a'.codeUnits,
  width & 0xFF, width >> 8, height & 0xFF, height >> 8, //
  ...List.filled(20, 0),
]);

/// SOI, an EXIF segment, a fill byte, a restart marker and then the frame.
Uint8List jpeg(int width, int height, {int frame = 0xC2}) =>
    Uint8List.fromList([
      0xFF, 0xD8, //
      0xFF, 0xE1, 0x00, 0x08, ...'Exif'.codeUnits, 0, 0, //
      0xFF, 0xFF, 0xD0, //
      0xFF, frame, 0x00, 0x11, 8, height >> 8, height & 0xFF, width >> 8,
      width & 0xFF, 3, ...List.filled(9, 0), //
      0xFF, 0xDA, ...List.filled(20, 0),
    ]);

Uint8List riff(String chunk, List<int> body) => Uint8List.fromList([
  ...'RIFF'.codeUnits,
  ...[0, 0, 0, 0],
  ...'WEBP'.codeUnits,
  ...chunk.codeUnits,
  ...[0, 0, 0, 0],
  ...body,
  ...List.filled(20, 0),
]);

Uint8List webpLossy(int width, int height) => riff('VP8 ', [
  0, 0, 0, 0x9D, 0x01, 0x2A, //
  width & 0xFF, width >> 8, height & 0xFF, height >> 8,
]);

Uint8List webpLossless(int width, int height) {
  final bits = (width - 1) | (height - 1) << 14;
  return riff('VP8L', [
    0x2F, bits & 0xFF, bits >> 8 & 0xFF, bits >> 16 & 0xFF, bits >> 24, //
  ]);
}

Uint8List webpExtended(int width, int height) => riff('VP8X', [
  0, 0, 0, 0, //
  (width - 1) & 0xFF, (width - 1) >> 8 & 0xFF, (width - 1) >> 16,
  (height - 1) & 0xFF, (height - 1) >> 8 & 0xFF, (height - 1) >> 16,
]);

KeyedImage picture(String id, {int epoch = 0, int width = 640}) => KeyedImage(
  epoch: KeyEpoch(epoch),
  metadata: ImageMetadata(
    blob: SealedBlob(
      id: BlobId(id),
      keyId: SubkeyId.fromBytes(List.filled(SubkeyId.length, 9)),
      plaintextLength: 5000,
    ),
    info: ImageHeader(ImageFormat.jpeg, width, 480),
    addedAt: at,
  ),
);

final schema = SeedSchemas.documentV1;
final attachments = FieldKey('attachments');

T valid<T>(Validated<T> result) => switch (result) {
  Valid(:final value) => value,
  Invalid(:final violations) => throw StateError('$violations'),
};

DynamicEntry page(List<String> images, {String id = 'p'}) => valid(
  DynamicEntry.create(
    schema: schema,
    id: EntryId(id * 32),
    attributes: {
      FieldKey('title'): const TextValue('Capitolo'),
      if (images.isNotEmpty)
        attachments: AttachmentsValue([
          for (final image in images) ImageAttachment(BlobId(image)),
          WebLink.parse('example.org')!,
        ]),
    },
    at: at,
  ),
);

SchemaDefinition? resolve(SchemaId id) => id == schema.id ? schema : null;

RecordedNote decode(List<int> bytes) =>
    valid(RecordedNoteCodec.decode(bytes, schemas: resolve));

void main() {
  group('ImageProbe', () {
    test('reads the format and size of each kind', () {
      expect(
        ImageProbe.probe(png(640, 480)),
        ImageHeader(ImageFormat.png, 640, 480),
      );
      expect(
        ImageProbe.probe(gif(32, 16)),
        ImageHeader(ImageFormat.gif, 32, 16),
      );
      expect(
        ImageProbe.probe(jpeg(4032, 3024)),
        ImageHeader(ImageFormat.jpeg, 4032, 3024),
      );
      expect(
        ImageProbe.probe(jpeg(100, 50, frame: 0xC0)),
        ImageHeader(ImageFormat.jpeg, 100, 50),
      );
      expect(
        ImageProbe.probe(webpLossy(300, 200)),
        ImageHeader(ImageFormat.webp, 300, 200),
      );
      expect(
        ImageProbe.probe(webpLossless(300, 200)),
        ImageHeader(ImageFormat.webp, 300, 200),
      );
      expect(
        ImageProbe.probe(webpExtended(16000, 2000)),
        ImageHeader(ImageFormat.webp, 16000, 2000),
      );
    });

    test('refuses pictures that would decode too large', () {
      for (final bomb in [
        png(60000, 60000),
        png(ImageProbe.maxSide + 1, 1),
        png(10000, 10000),
        jpeg(65535, 65535),
        webpExtended(16000, 16000),
        png(0, 10),
        gif(0, 0),
      ]) {
        expect(
          () => ImageProbe.probe(bomb),
          throwsA(isA<ImageTooLargeException>()),
        );
      }
      expect(
        () => ImageProbe.probe(Uint8List(ImageProbe.maxBytes + 1)),
        throwsA(isA<ImageTooLargeException>()),
      );
    });

    test('refuses anything that is not a picture it can measure', () {
      for (final other in [
        Uint8List(0),
        Uint8List.fromList(
          '<svg xmlns="http://www.w3.org/2000/svg"/>'.codeUnits,
        ),
        Uint8List.fromList('%PDF-1.7'.codeUnits),
        Uint8List.fromList('OggS'.codeUnits),
        png(10, 10).sublist(0, 20),
        Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xDA, 0, 2]),
        Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]),
        Uint8List.fromList([0xFF, 0xD8, 0x00]),
        Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0, 0]),
        riff('VP8 ', [0, 0, 0, 1, 2, 3]),
        riff('ALPH', [0, 0, 0, 0]),
        Uint8List.fromList([...png(10, 10)]..[11] = 12),
      ]) {
        expect(
          () => ImageProbe.probe(other),
          throwsA(isA<UnsupportedImageException>()),
          reason: other.take(12).toString(),
        );
      }
    });

    Glados(any.list(any.uint8)).test('random bytes only ever fail as a '
        'picture it cannot keep', (bytes) {
      for (final prefix in [
        <int>[],
        [0xFF, 0xD8],
        [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
        [...'RIFF'.codeUnits, 0, 0, 0, 0, ...'WEBP'.codeUnits],
      ]) {
        try {
          ImageProbe.probe([...prefix, ...bytes]);
        } on UnsupportedImageException {
          // expected
        } on ImageTooLargeException {
          // expected
        }
      }
    });
  });

  group('ImageStorage', () {
    setUpAll(initSodium);

    late InMemoryBlobStore store;
    late ImageStorage images;
    late SymmetricKey contentKey;

    setUp(() {
      store = InMemoryBlobStore();
      images = ImageStorage(
        storage: EncryptedBlobStorage(
          store: store,
          encryptor: newEncryptor(),
          subkeys: newSubkeys(),
        ),
      );
      contentKey = newEncryptor().generateKey();
      addTearDown(contentKey.dispose);
    });

    test('seals a picture and opens it again', () async {
      final bytes = Uint8List.fromList([...png(640, 480), ...audio(200000)]);

      final sealed = await images.seal(
        bytes,
        id: BlobId('photo'),
        contentKey: contentKey,
        at: at,
      );

      expect(sealed.info, ImageHeader(ImageFormat.png, 640, 480));
      expect(sealed.blob.plaintextLength, bytes.length);
      expect(sealed.addedAt, at);
      final stored = store.committed[BlobId('photo')]!;
      expect(_contains(stored, 'IHDR'.codeUnits), isFalse);
      expect(await images.open(sealed, contentKey: contentKey), bytes);
    });

    test('refuses to seal what is not a picture, writing nothing', () async {
      await expectLater(
        images.seal(
          Uint8List.fromList('<svg/>'.codeUnits),
          id: BlobId('svg'),
          contentKey: contentKey,
          at: at,
        ),
        throwsA(isA<UnsupportedImageException>()),
      );
      expect(store.committed, isEmpty);
      expect(store.pending, isEmpty);
    });

    test(
      'a picture that is not the one described is never handed out',
      () async {
        final sealed = await images.seal(
          png(640, 480),
          id: BlobId('photo'),
          contentKey: contentKey,
          at: at,
        );
        // A member describes it as smaller, hoping a decoder trusts that.
        final lying = ImageMetadata(
          blob: sealed.blob,
          info: ImageHeader(ImageFormat.png, 64, 48),
          addedAt: at,
        );
        await expectLater(
          images.open(lying, contentKey: contentKey),
          throwsA(isA<MalformedBlobException>()),
        );
        final sealedOther = await images.seal(
          Uint8List.fromList([...png(64, 48)]),
          id: BlobId('other'),
          contentKey: contentKey,
          at: at,
        );
        // A blob sealed for something else, under a picture's description.
        final blob =
            await EncryptedBlobStorage(
              store: store,
              encryptor: newEncryptor(),
              subkeys: newSubkeys(),
            ).write(
              Stream.value('<svg/>'.codeUnits),
              id: BlobId('svg'),
              contentKey: contentKey,
            );
        await expectLater(
          images.open(
            ImageMetadata(blob: blob, info: sealedOther.info, addedAt: at),
            contentKey: contentKey,
          ),
          throwsA(isA<MalformedBlobException>()),
        );
      },
    );
  });

  group('RecordedNote with pictures', () {
    test('pairs the pictures the page shows, and only those', () {
      final note = RecordedNote.compose(
        page(['a1']),
        pictures: [picture('a1'), picture('unused')],
      );

      expect(note.images.keys, [BlobId('a1')]);
      expect(note.blobs.map((b) => b.id), [BlobId('a1')]);
      expect(
        () => RecordedNote.compose(page(['a1'])),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('an edit that removes a picture releases it', () {
      final before = RecordedNote.compose(
        page(['a1', 'a2']),
        pictures: [picture('a1'), picture('a2')],
      );
      final after = before.edited(
        page(['a2', 'a3']),
        pictures: [picture('a3')],
      );

      expect(after.images.keys.toSet(), {BlobId('a2'), BlobId('a3')});
      expect(RecordedNote.released(before: before, after: after), {
        BlobId('a1'),
      });
    });

    DynamicEntry written(
      List<String> inline, {
      List<String> attached = const [],
    }) => valid(
      DynamicEntry.create(
        schema: schema,
        id: EntryId('w' * 32),
        attributes: {
          FieldKey('title'): const TextValue('Capitolo'),
          FieldKey('body'): TextValue(
            [
              'Il palco:',
              for (final image in inline)
                InlineImages.markdown('Foto $image', BlobId(image)),
              'Fine.',
            ].join('\n'),
          ),
          if (attached.isNotEmpty)
            attachments: AttachmentsValue([
              for (final image in attached) ImageAttachment(BlobId(image)),
            ]),
        },
        at: at,
      ),
    );

    test('pictures in the text are the page\'s pictures too', () {
      final note = RecordedNote.compose(
        written(['t1', 't2'], attached: ['a1']),
        pictures: [picture('a1'), picture('t1'), picture('t2')],
      );

      expect(note.images.keys.toSet(), {
        BlobId('a1'),
        BlobId('t1'),
        BlobId('t2'),
      });
      expect(
        () => RecordedNote.compose(written(['t1']), pictures: [picture('a1')]),
        throwsA(isA<ArgumentError>()),
        reason: 'a picture in the text needs its metadata',
      );
    });

    test('taking a picture out of the text releases it', () {
      final before = RecordedNote.compose(
        written(['t1', 't2']),
        pictures: [picture('t1'), picture('t2')],
      );
      final after = before.edited(written(['t2']));

      expect(RecordedNote.released(before: before, after: after), {
        BlobId('t1'),
      });
    });

    test('a page with pictures in its text round-trips, and refuses a '
        'picture its text does not show', () {
      final note = RecordedNote.compose(
        written(['t1']),
        pictures: [picture('t1')],
      );
      final back = decode(RecordedNoteCodec.encode(note));
      expect(back.images.keys, [BlobId('t1')]);
      expect(
        back.entry.attributes[FieldKey('body')],
        note.entry.attributes[FieldKey('body')],
      );

      expect(
        () => RecordedNoteCodec.decode(
          RecordedNoteCodec.encodeUnchecked(
            written(['t1']),
            const {},
            images: {BlobId('t2'): picture('t2')},
          ),
          schemas: resolve,
        ),
        throwsA(isA<MalformedBlobException>()),
      );
    });

    test('trash, restore and filing keep the pictures', () {
      final note = RecordedNote.compose(
        page(['a1']),
        pictures: [picture('a1')],
      );
      final shelf = CategoryId('s' * 32);

      expect(note.trashed(at: later).images, note.images);
      expect(note.trashed(at: later).restored().images, note.images);
      expect(note.filedIn(shelf).images, note.images);
    });

    test('round-trips as version 4, in the trash and filed or not', () {
      final note = RecordedNote.compose(
        page(['a1', 'a2']),
        pictures: [picture('a1', epoch: 2), picture('a2', width: 1)],
      );
      final shelf = CategoryId('s' * 32);
      for (final written in [
        note,
        note.trashed(at: later),
        note.filedIn(shelf),
        note.filedIn(shelf).trashed(at: later),
      ]) {
        final wire = RecordedNoteCodec.encode(written);
        expect(wire[0], 4);
        final back = decode(wire);
        expect(back.images, written.images);
        expect(back.category, written.category);
        expect(back.trashedAt, written.trashedAt);
        expect(back.entry.attributes, written.entry.attributes);
      }
    });

    test('a page without pictures keeps the older versions', () {
      expect(RecordedNoteCodec.encode(RecordedNote.of(page([])))[0], 1);
      expect(
        RecordedNoteCodec.encode(
          RecordedNote.of(page([])).filedIn(CategoryId('s' * 32)),
        )[0],
        3,
      );
    });

    group('adversary', () {
      Uint8List wire() => RecordedNoteCodec.encode(
        RecordedNote.compose(
          page(['a1']),
          pictures: [picture('a1')],
        ).filedIn(CategoryId('s' * 32)).trashed(at: later),
      );

      test('every truncation and trailing byte is refused', () {
        final bytes = wire();
        for (var length = 0; length < bytes.length; length++) {
          expect(
            () => RecordedNoteCodec.decode(
              Uint8List.sublistView(bytes, 0, length),
              schemas: resolve,
            ),
            throwsA(isA<MalformedBlobException>()),
            reason: '$length bytes',
          );
        }
        expect(
          () => RecordedNoteCodec.decode([...bytes, 0], schemas: resolve),
          throwsA(isA<MalformedBlobException>()),
        );
      });

      test('pictures the page does not show, or misses, are refused', () {
        for (final (images, entry) in [
          ({BlobId('a1'): picture('a1')}, page([])),
          (<BlobId, KeyedImage>{}, page(['a1'])),
          ({BlobId('a2'): picture('a2')}, page(['a1'])),
        ]) {
          expect(
            () => RecordedNoteCodec.decode(
              RecordedNoteCodec.encodeUnchecked(
                entry,
                const {},
                images: images,
              ),
              schemas: resolve,
            ),
            throwsA(isA<MalformedBlobException>()),
          );
        }
      });

      test('a picture past the limits is refused before anything decodes', () {
        final huge = KeyedImage(
          epoch: KeyEpoch(0),
          metadata: ImageMetadata(
            blob: picture('a1').blob,
            info: ImageHeader(ImageFormat.png, 5000, 5000),
            addedAt: at,
          ),
        );
        final bytes = RecordedNoteCodec.encodeUnchecked(
          page(['a1']),
          const {},
          images: {BlobId('a1'): huge},
        );
        // width and height sit before the time (8 bytes) at the end.
        final data = ByteData.sublistView(bytes);
        data.setUint32(bytes.length - 16, 60000);
        data.setUint32(bytes.length - 12, 60000);
        expect(
          () => RecordedNoteCodec.decode(bytes, schemas: resolve),
          throwsA(isA<MalformedBlobException>()),
        );
      });

      test('version 4 without pictures, or unknown flags, is refused', () {
        final bytes = RecordedNoteCodec.encodeUnchecked(
          page(['a1']),
          const {},
          images: {BlobId('a1'): picture('a1')},
        );
        // version | entry (u32 + bytes) | count (u16) | flags
        final flags = 1 + 4 + ByteData.sublistView(bytes).getUint32(1) + 2;
        expect(bytes[flags], 4);
        for (final bad in [0, 2, 1, 8, 0x80]) {
          final forged = Uint8List.fromList(bytes)..[flags] = bad;
          expect(
            () => RecordedNoteCodec.decode(forged, schemas: resolve),
            throwsA(isA<MalformedBlobException>()),
            reason: 'flags $bad',
          );
        }
        // Version 3 cannot carry pictures.
        final older = Uint8List.fromList(bytes)
          ..[0] = 3
          ..[flags] = 6;
        expect(
          () => RecordedNoteCodec.decode(older, schemas: resolve),
          throwsA(isA<MalformedBlobException>()),
        );
      });
    });
  });
}

bool _contains(List<int> haystack, List<int> needle) {
  outer:
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return true;
  }
  return false;
}
