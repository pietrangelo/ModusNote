import 'dart:convert';
import 'dart:typed_data';

import 'package:blob_storage_media/blob_storage_media.dart';
import 'package:blob_storage_media_adapters/audio_encoding.dart';
import 'package:glados/glados.dart';

Uint8List packet(int length, [int fill = 0xA5]) =>
    Uint8List(length)..fillRange(0, length, fill);

OggOpusMuxer muxer({int packetsPerPage = 3, int channels = 1}) => OggOpusMuxer(
  serial: 0x1234ABCD,
  channels: channels,
  preSkip: 312,
  inputSampleRate: 48000,
  packetsPerPage: packetsPerPage,
);

Uint8List mux(
  List<Uint8List> packets, {
  int? originalSamples,
  OggOpusMuxer? m,
}) {
  final muxing = m ?? muxer();
  final out = BytesBuilder()..add(muxing.header());
  for (final p in packets) {
    if (muxing.addPacket(p, samples: 960) case final page?) out.add(page);
  }
  out.add(
    muxing.finish(
      originalSamples: originalSamples ?? packets.length * 960 - 312,
    ),
  );
  return out.takeBytes();
}

Stream<Uint8List> pieces(Uint8List bytes, int size) async* {
  for (var offset = 0; offset < bytes.length; offset += size) {
    yield Uint8List.sublistView(
      bytes,
      offset,
      offset + size > bytes.length ? bytes.length : offset + size,
    );
  }
}

Future<OggOpusRecording> demux(Uint8List bytes, {int pieceSize = 1 << 16}) =>
    const OggOpusDemuxer().read(pieces(bytes, pieceSize));

/// Page boundaries of a well-formed stream, to aim edits at one page.
List<int> pageOffsets(Uint8List stream) {
  final offsets = <int>[];
  var offset = 0;
  while (offset < stream.length) {
    offsets.add(offset);
    final segments = stream[offset + 26];
    var body = 0;
    for (var i = 0; i < segments; i++) {
      body += stream[offset + 27 + i];
    }
    offset += 27 + segments + body;
  }
  return offsets;
}

/// Recomputes the CRC of the page at [offset] after an edit, so a test
/// reaches the check it means to reach instead of the checksum.
Uint8List resealed(Uint8List stream, int offset) {
  final segments = stream[offset + 26];
  var body = 0;
  for (var i = 0; i < segments; i++) {
    body += stream[offset + 27 + i];
  }
  final end = offset + 27 + segments + body;
  final view = ByteData.sublistView(stream);
  view.setUint32(offset + 22, 0, Endian.little);
  view.setUint32(
    offset + 22,
    OggOpusMuxer.crc(stream.sublist(offset, end)),
    Endian.little,
  );
  return stream;
}

void main() {
  test(
    'reads back the packets, pre-skip and final granule it was given',
    () async {
      final packets = [
        packet(60, 1),
        packet(300, 2),
        packet(5, 3),
        packet(80, 4),
      ];

      final recording = await demux(mux(packets, originalSamples: 3000));

      expect(recording.channels, 1);
      expect(recording.preSkip, 312);
      expect(recording.finalGranule, 312 + 3000);
      expect(recording.packets, packets);
    },
  );

  test('packets do not depend on how the bytes were chunked', () async {
    final packets = [for (var i = 1; i <= 10; i++) packet(i * 37, i)];
    final stream = mux(packets);

    for (final size in [1, 7, 27, 300, stream.length]) {
      expect((await demux(stream, pieceSize: size)).packets, packets);
    }
  });

  test('a recording with no audio has no packets', () async {
    final recording = await demux(mux(const [], originalSamples: 0));

    expect(recording.packets, isEmpty);
    expect(recording.finalGranule, 0);
  });

  test('stereo heads are accepted', () async {
    final recording = await demux(mux([packet(10)], m: muxer(channels: 2)));

    expect(recording.channels, 2);
  });

  group('adversary', () {
    Future<void> refuses(Uint8List stream, String reason) => expectLater(
      demux(stream),
      throwsA(isA<MalformedBlobException>()),
      reason: reason,
    );

    final valid = mux([packet(60), packet(70), packet(80), packet(90)]);
    Uint8List copy() => Uint8List.fromList(valid);

    test('a flipped bit anywhere fails the page checksum', () async {
      for (final at in [5, 30, 60, valid.length - 1]) {
        await refuses(copy()..[at] ^= 0x10, 'byte $at');
      }
    });

    test('truncation and trailing bytes are refused', () async {
      await refuses(Uint8List.sublistView(valid, 0, valid.length - 1), 'cut');
      await refuses(Uint8List.sublistView(valid, 0, 20), 'mid header');
      await refuses(Uint8List(0), 'empty');
      final pages = pageOffsets(valid);
      await refuses(Uint8List.sublistView(valid, 0, pages.last), 'no EOS');
      await refuses(Uint8List.fromList([...valid, 0]), 'trailing byte');
      await refuses(
        Uint8List.fromList([...valid, ...valid.sublist(pages.last)]),
        'page after end of stream',
      );
    });

    test('broken page structure is refused', () async {
      final pages = pageOffsets(valid);
      await refuses(resealed(copy()..[0] = 0x50, 0), 'capture pattern');
      await refuses(resealed(copy()..[4] = 1, 0), 'structure version');
      await refuses(resealed(copy()..[5] = 0, 0), 'first page without BOS');
      await refuses(resealed(copy()..[pages[1] + 5] = 0x02, pages[1]), 'BOS');
      await refuses(
        resealed(copy()..[pages[2] + 5] = 0x01, pages[2]),
        'continued packet',
      );
      await refuses(
        resealed(copy()..[pages[1] + 14] ^= 1, pages[1]),
        'second logical stream',
      );
      await refuses(
        resealed(copy()..[pages[2] + 18] = 7, pages[2]),
        'sequence gap',
      );
    });

    test('a packet spilling into the next page is refused', () async {
      final stream = mux([
        packet(255),
        packet(10),
      ], m: muxer(packetsPerPage: 1));
      final audio = pageOffsets(stream)[2];
      // Lacing [255, 0] becomes [255, 255]: the packet no longer ends here.
      stream[audio + 28] = 255;
      final grown = Uint8List.fromList([
        ...stream.sublist(0, audio + 27 + 2),
        ...packet(510),
        ...stream.sublist(audio + 27 + 2 + 255),
      ]);
      await refuses(resealed(grown, audio), 'unterminated packet');
    });

    test(
      'headers that are not a mono or stereo Opus stream are refused',
      () async {
        Uint8List withHead(void Function(ByteData head) edit) {
          final stream = copy();
          final segments = stream[26];
          edit(ByteData.sublistView(stream, 27 + segments, 27 + segments + 19));
          return resealed(stream, 0);
        }

        await refuses(withHead((h) => h.setUint8(0, 0x58)), 'magic');
        await refuses(withHead((h) => h.setUint8(8, 0x10)), 'major version');
        await refuses(withHead((h) => h.setUint8(9, 0)), 'no channels');
        await refuses(withHead((h) => h.setUint8(9, 3)), 'surround');
        await refuses(
          withHead((h) => h.setInt16(16, 256, Endian.little)),
          'gain',
        );
        await refuses(withHead((h) => h.setUint8(18, 1)), 'mapping family');

        final tagged = copy();
        final tagsAt = pageOffsets(tagged)[1];
        tagged[tagsAt + 27 + tagged[tagsAt + 26] + 4] = 0x58;
        await refuses(resealed(tagged, tagsAt), 'OpusTags magic');
      },
    );

    test(
      'audio packets must be Opus sized and granules must not go back',
      () async {
        final empty = mux([
          packet(10),
          Uint8List(0),
        ], m: muxer(packetsPerPage: 1));
        await refuses(empty, 'empty packet');

        final stream = mux([
          packet(10),
          packet(10),
          packet(10),
        ], m: muxer(packetsPerPage: 1));
        final pages = pageOffsets(stream);
        ByteData.sublistView(stream)
          ..setUint32(pages[3] + 6, 1, Endian.little)
          ..setUint32(pages[3] + 6 + 4, 0, Endian.little);
        await refuses(resealed(stream, pages[3]), 'granule went back');

        final hidden = mux([packet(10)], originalSamples: 0);
        final last = pageOffsets(hidden).last;
        ByteData.sublistView(hidden)
          ..setUint32(last + 6, 100, Endian.little)
          ..setUint32(last + 6 + 4, 0, Endian.little);
        await refuses(resealed(hidden, last), 'final granule inside pre-skip');
      },
    );

    test(
      'streams beyond the size limit are refused before buffering',
      () async {
        final big = mux([for (var i = 0; i < 40; i++) packet(200)]);
        await expectLater(
          const OggOpusDemuxer(maxBytes: 4096).read(pieces(big, 512)),
          throwsA(isA<MalformedBlobException>()),
        );
      },
    );

    test('an OpusHead with stray bytes is refused', () async {
      final head = BytesBuilder()
        ..add(ascii.encode('OpusHead'))
        ..add([1, 1, 0x38, 0x01, 0x80, 0xBB, 0, 0, 0, 0, 0, 0xFF]);
      final page = Uint8List.fromList([
        ...ascii.encode('OggS'),
        0,
        0x02,
        ...Uint8List(8),
        0xCD,
        0xAB,
        0x34,
        0x12,
        ...Uint8List(8),
        1,
        20,
        ...head.takeBytes(),
      ]);
      final stream = Uint8List.fromList([
        ...resealed(page, 0),
        ...valid.sublist(pageOffsets(valid)[1]),
      ]);
      await refuses(stream, 'head length');
    });

    // glados draws its numbers with `1 << 32`, which is 0 in JavaScript:
    // the property tests run on the VM, the cases above in the browser too.
    Glados(any.list(any.uint8))
        .test('random bytes are refused, never crash', (bytes) async {
          try {
            await demux(Uint8List.fromList(bytes));
            fail('random bytes demuxed');
          } on MalformedBlobException {
            // The only acceptable outcome.
          }
        }, testOn: 'vm');

    Glados2(any.intInRange(0, 2000), any.uint8).test(
      'a single corrupted byte is refused or harmless, never a crash',
      (position, value) async {
        final stream = copy();
        final at = position % stream.length;
        stream[at] = value;
        try {
          await demux(stream);
        } on MalformedBlobException {
          // Refused.
        }
      },
      testOn: 'vm',
    );
  });
}
