import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';

/// Independent reader used to check what the muxer writes: a bit-by-bit
/// CRC (the muxer uses a table) and a plain RFC 3533 page parser.
final class Page {
  Page(this.headerType, this.granule, this.serial, this.sequence, this.packets);

  final int headerType;
  final int granule;
  final int serial;
  final int sequence;
  final List<Uint8List> packets;

  bool get isFirst => headerType & 0x02 != 0;
  bool get isLast => headerType & 0x04 != 0;
}

int referenceCrc(List<int> bytes) {
  var crc = 0;
  for (final byte in bytes) {
    crc ^= byte << 24;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc & 0x80000000) != 0
          ? ((crc << 1) ^ 0x04C11DB7) & 0xFFFFFFFF
          : (crc << 1) & 0xFFFFFFFF;
    }
  }
  return crc;
}

List<Page> parsePages(Uint8List stream) {
  final pages = <Page>[];
  var offset = 0;
  while (offset < stream.length) {
    final view = ByteData.sublistView(stream, offset);
    expect(ascii.decode(stream.sublist(offset, offset + 4)), 'OggS');
    expect(view.getUint8(4), 0, reason: 'stream structure version');
    final segments = view.getUint8(26);
    final lacing = stream.sublist(offset + 27, offset + 27 + segments);
    final bodyLength = lacing.fold<int>(0, (a, b) => a + b);
    final end = offset + 27 + segments + bodyLength;
    final page = Uint8List.fromList(stream.sublist(offset, end));
    final storedCrc = ByteData.sublistView(page).getUint32(22, Endian.little);
    page.setRange(22, 26, [0, 0, 0, 0]);
    expect(storedCrc, referenceCrc(page), reason: 'page CRC');

    final packets = <Uint8List>[];
    var cursor = offset + 27 + segments;
    var packetStart = cursor;
    for (final value in lacing) {
      cursor += value;
      if (value < 255) {
        packets.add(Uint8List.fromList(stream.sublist(packetStart, cursor)));
        packetStart = cursor;
      }
    }
    expect(packetStart, cursor, reason: 'no packet continues past a page');
    pages.add(
      Page(
        view.getUint8(5),
        view.getInt64(6, Endian.little),
        view.getUint32(14, Endian.little),
        view.getUint32(18, Endian.little),
        packets,
      ),
    );
    offset = end;
  }
  return pages;
}
