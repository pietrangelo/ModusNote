import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:blob_storage_media/blob_storage_media.dart';
import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';
import 'package:test/test.dart';

import 'support.dart';

/// Clips made with ffmpeg (1 s, 64×48, H.264 and AAC) carrying a
/// location, a title, the encoder's name and a creation time:
/// `video_front.mp4` with moov before mdat (`+faststart`),
/// `video_back.mp4` the same streams with moov after mdat, and
/// `video_subtitled.mp4` with a text track whose one sample reads
/// «GPS 45.4642 9.1900 segreto», the way some cameras keep a GPS track.
Uint8List fixture(String name) => File('test/fixtures/$name').readAsBytesSync();

bool holds(Uint8List bytes, String text) =>
    latin1.decode(bytes, allowInvalid: true).contains(text);

/// The boxes at the top of [bytes], by type.
List<String> top(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  final out = <String>[];
  for (var at = 0; at < bytes.length;) {
    final size = data.getUint32(at);
    out.add(latin1.decode(bytes.sublist(at + 4, at + 8)));
    at += size == 0 ? bytes.length - at : size;
  }
  return out;
}

void main() {
  final front = fixture('video_front.mp4');
  final back = fixture('video_back.mp4');
  final subtitled = fixture('video_subtitled.mp4');

  group('VideoProbe', () {
    test('reads the size and the length from the boxes', () {
      for (final clip in [front, back, subtitled]) {
        final info = VideoProbe.probe(clip);
        expect(info.format, VideoFormat.mp4);
        expect((info.width, info.height), (64, 48));
        expect(info.duration, const Duration(seconds: 1));
      }
      expect(VideoFormat.mp4.mimeType, 'video/mp4');
    });

    test('refuses what is not a short MP4', () {
      expect(
        () => VideoProbe.probe(Uint8List.fromList(utf8.encode('ciao'))),
        throwsA(isA<UnsupportedVideoException>()),
      );
      expect(
        () => VideoProbe.probe(Uint8List(VideoProbe.maxBytes + 1)),
        throwsA(isA<VideoTooLargeException>()),
      );
      // Two minutes: the movie header's duration, patched.
      final long = Uint8List.fromList(front);
      final at = _find(long, 'mvhd') + 4;
      final data = ByteData.sublistView(long);
      final timescale = data.getUint32(at + 12);
      data.setUint32(at + 16, timescale * 120);
      expect(
        () => VideoProbe.probe(long),
        throwsA(isA<VideoTooLargeException>()),
      );
      // A fragmented file keeps its samples elsewhere.
      final fragmented = Uint8List.fromList([
        ...front,
        0, 0, 0, 8, ...latin1.encode('moof'), //
      ]);
      expect(
        () => VideoProbe.probe(fragmented),
        throwsA(isA<UnsupportedVideoException>()),
      );
    });

    test('hostile bytes are only ever refused', () {
      final random = Random(5);
      for (var i = 0; i < 2000; i++) {
        final bytes = Uint8List.fromList(front);
        for (var j = 0; j < 1 + random.nextInt(4); j++) {
          bytes[random.nextInt(2000)] = random.nextInt(256);
        }
        final cut = random.nextBool()
            ? bytes
            : Uint8List.sublistView(bytes, 0, random.nextInt(bytes.length));
        try {
          VideoScrubber.scrub(cut);
        } on UnsupportedVideoException {
          // refused
        } on VideoTooLargeException {
          // refused
        }
      }
    });
  });

  group('VideoScrubber', () {
    test('leaves out the location, the title, the encoder and the times', () {
      for (final clip in [front, back, subtitled]) {
        expect(holds(clip, 'Cucina di casa'), isTrue);
        final clean = VideoScrubber.scrub(clip);
        expect(holds(clean, 'Cucina di casa'), isFalse);
        expect(holds(clean, 'Lavf'), isFalse);
        expect(holds(clean, 'udta'), isFalse);
        expect(holds(clean, 'loci'), isFalse);
        expect(holds(clean, 'free'), isFalse);
        expect(top(clean), ['ftyp', 'moov', 'mdat']);
        for (final header in ['mvhd', 'tkhd', 'mdhd']) {
          final at = _find(clean, header) + 4;
          expect(
            clean.sublist(at + 4, at + 12),
            List.filled(8, 0),
            reason: header,
          );
        }
        expect(VideoProbe.probe(clean), VideoProbe.probe(clip));
      }
    });

    test('a text track is dropped and its samples zeroed', () {
      expect(holds(subtitled, 'segreto'), isTrue);
      final clean = VideoScrubber.scrub(subtitled);
      expect(holds(clean, 'segreto'), isFalse);
      expect(holds(clean, '45.4642'), isFalse);
      expect(holds(clean, 'sbtl') || holds(clean, 'text'), isFalse);
    });

    test('samples are where the offsets say, whatever the layout', () {
      // The same streams, moov first or last: one clean file.
      expect(VideoScrubber.scrub(front), VideoScrubber.scrub(back));
      final once = VideoScrubber.scrub(back);
      expect(VideoScrubber.scrub(once), once);
    });
  });

  group('VideoStorage', () {
    setUpAll(initSodium);

    late InMemoryBlobStore store;
    late VideoStorage videos;
    late SymmetricKey contentKey;
    final at = DateTime.utc(2026, 11, 1, 11);

    setUp(() {
      store = InMemoryBlobStore();
      videos = VideoStorage(
        storage: EncryptedBlobStorage(
          store: store,
          encryptor: newEncryptor(),
          subkeys: newSubkeys(),
          hasher: newHasher(),
        ),
      );
      contentKey = newEncryptor().generateKey();
      addTearDown(contentKey.dispose);
    });

    test('seals a clean copy and opens it again', () async {
      final sealed = await videos.seal(
        subtitled,
        id: BlobId('clip'),
        contentKey: contentKey,
        at: at,
      );
      final clean = VideoScrubber.scrub(subtitled);
      expect(sealed.info, VideoProbe.probe(subtitled));
      expect(sealed.blob.plaintextLength, clean.length);
      expect(sealed.addedAt, at);
      final opened = await videos.open(sealed, contentKey: contentKey);
      expect(opened, clean);
      expect(holds(opened, 'segreto'), isFalse);
      expect(holds(store.committed[BlobId('clip')]!, 'ftyp'), isFalse);
    });

    test('refuses what is not a video, writing nothing', () async {
      await expectLater(
        videos.seal(
          Uint8List.fromList(utf8.encode('<svg/>')),
          id: BlobId('svg'),
          contentKey: contentKey,
          at: at,
        ),
        throwsA(isA<UnsupportedVideoException>()),
      );
      expect(store.committed, isEmpty);
      expect(store.pending, isEmpty);
    });

    test('a video that is not the one described is never handed out', () async {
      final sealed = await videos.seal(
        front,
        id: BlobId('clip'),
        contentKey: contentKey,
        at: at,
      );
      final lying = VideoMetadata(
        blob: sealed.blob,
        info: VideoHeader(VideoFormat.mp4, 640, 480, sealed.info.duration),
        addedAt: at,
      );
      await expectLater(
        videos.open(lying, contentKey: contentKey),
        throwsA(isA<MalformedBlobException>()),
      );
    });
  });
}

int _find(Uint8List bytes, String type) {
  final target = latin1.encode(type);
  for (var i = 0; i + 4 <= bytes.length; i++) {
    if (bytes[i] == target[0] &&
        bytes[i + 1] == target[1] &&
        bytes[i + 2] == target[2] &&
        bytes[i + 3] == target[3]) {
      return i;
    }
  }
  throw StateError('no $type');
}
