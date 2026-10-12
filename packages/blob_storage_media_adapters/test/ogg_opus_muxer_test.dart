import 'dart:convert';
import 'dart:typed_data';

import 'package:blob_storage_media_adapters/audio_encoding.dart';
import 'package:test/test.dart';

import 'support/ogg_reader.dart';

Uint8List packet(int length, [int fill = 0xA5]) =>
    Uint8List(length)..fillRange(0, length, fill);

void main() {
  OggOpusMuxer muxer({int packetsPerPage = 3}) => OggOpusMuxer(
    serial: 0x1234ABCD,
    channels: 1,
    preSkip: 312,
    inputSampleRate: 48000,
    packetsPerPage: packetsPerPage,
  );

  Uint8List mux(OggOpusMuxer m, List<Uint8List> packets, int originalSamples) {
    final out = BytesBuilder()..add(m.header());
    for (final p in packets) {
      final page = m.addPacket(p, samples: 960);
      if (page != null) out.add(page);
    }
    out.add(m.finish(originalSamples: originalSamples));
    return out.takeBytes();
  }

  test('the table CRC matches the bit-by-bit reference', () {
    final data = utf8.encode('OggS ModusNote checksum vector');

    expect(OggOpusMuxer.crc(data), referenceCrc(data));
    expect(OggOpusMuxer.crc(const []), 0);
  });

  test('the first page holds only OpusHead, flagged beginning-of-stream', () {
    final pages = parsePages(mux(muxer(), const [], 0));
    final head = pages[0].packets.single;
    final view = ByteData.sublistView(head);

    expect(pages[0].isFirst, isTrue);
    expect(pages[0].granule, 0);
    expect(ascii.decode(head.sublist(0, 8)), 'OpusHead');
    expect(head[8], 1, reason: 'version');
    expect(head[9], 1, reason: 'channels');
    expect(view.getUint16(10, Endian.little), 312, reason: 'pre-skip');
    expect(view.getUint32(12, Endian.little), 48000);
    expect(view.getInt16(16, Endian.little), 0, reason: 'output gain');
    expect(head[18], 0, reason: 'mapping family');
    expect(head, hasLength(19));
  });

  test('the second page holds only OpusTags', () {
    final pages = parsePages(mux(muxer(), const [], 0));
    final tags = pages[1].packets.single;

    expect(pages[1].isFirst, isFalse);
    expect(pages[1].granule, 0);
    expect(ascii.decode(tags.sublist(0, 8)), 'OpusTags');
    final vendorLength = ByteData.sublistView(tags).getUint32(8, Endian.little);
    expect(
      ByteData.sublistView(tags).getUint32(12 + vendorLength, Endian.little),
      0,
      reason: 'no user comments: nothing about the user leaks into the file',
    );
  });

  test('audio packets come back intact, in order, across pages', () {
    final packets = [for (var i = 0; i < 7; i++) packet(40 + i * 50, i)];
    final pages = parsePages(mux(muxer(), packets, 7 * 960 - 312));

    expect([for (final p in pages.skip(2)) ...p.packets], packets);
    expect(pages.skip(2).map((p) => p.packets.length), [3, 3, 1]);
  });

  test('page sequence numbers count up and the serial is constant', () {
    final pages = parsePages(
      mux(muxer(), [for (var i = 0; i < 5; i++) packet(10)], 5 * 960 - 312),
    );

    expect([for (final p in pages) p.sequence], [0, 1, 2, 3]);
    expect({for (final p in pages) p.serial}, {0x1234ABCD});
  });

  test('granule positions count 48 kHz samples including pre-skip', () {
    final pages = parsePages(
      mux(muxer(), [for (var i = 0; i < 4; i++) packet(10)], 4 * 960 - 312),
    );

    expect(pages[2].granule, 3 * 960);
    expect(pages[3].granule, 4 * 960);
  });

  test('the last page is flagged end-of-stream and trims padding', () {
    final pages = parsePages(
      mux(muxer(), [for (var i = 0; i < 2; i++) packet(10)], 1500),
    );

    expect(pages.last.isLast, isTrue);
    expect(pages.where((p) => p.isLast), hasLength(1));
    expect(pages.last.granule, 312 + 1500);
  });

  test('the end-of-stream page always carries the last packet', () {
    // RFC 7845 forbids a granule going back; an empty final page after a
    // full one would have to, to trim the padding.
    final pages = parsePages(
      mux(muxer(), [for (var i = 0; i < 6; i++) packet(10)], 5000),
    );

    expect(pages.skip(2).map((p) => p.packets.length), [3, 3]);
    expect(pages[2].granule, 3 * 960);
    expect(pages.last.granule, 312 + 5000);
  });

  test('an empty recording still ends with an end-of-stream page', () {
    final pages = parsePages(mux(muxer(), const [], 0));

    expect(pages, hasLength(3));
    expect(pages.last.isLast, isTrue);
    expect(pages.last.packets, isEmpty);
    expect(pages.last.granule, 0);
  });

  test('packets of exactly 255 bytes get a terminating zero lacing value', () {
    final packets = [packet(255), packet(510), packet(1)];
    final pages = parsePages(mux(muxer(), packets, 3 * 960 - 312));

    expect([for (final p in pages.skip(2)) ...p.packets], packets);
  });

  group('adversary', () {
    test('an oversized packet is refused rather than split across pages', () {
      expect(
        () => muxer().addPacket(
          packet(OggOpusMuxer.maxPacketBytes + 1),
          samples: 960,
        ),
        throwsArgumentError,
      );
    });

    test('a final length beyond the decoded audio is refused', () {
      final m = muxer()..header();
      m.addPacket(packet(10), samples: 960);

      // 960 decoded samples cannot hold 312 pre-skip plus 960 of audio: the
      // caller forgot to flush the encoder's lookahead.
      expect(() => m.finish(originalSamples: 960), throwsArgumentError);
    });

    test('using the muxer after finish is a programming error', () {
      final m = muxer()..header();
      m.finish(originalSamples: 0);

      expect(() => m.addPacket(packet(1), samples: 960), throwsStateError);
      expect(() => m.finish(originalSamples: 0), throwsStateError);
    });
  });
}
