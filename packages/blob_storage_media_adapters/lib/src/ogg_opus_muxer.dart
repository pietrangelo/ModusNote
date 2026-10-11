import 'dart:convert';
import 'dart:typed_data';

/// Writes Opus packets into an Ogg container (RFC 3533, RFC 7845), so a
/// recording decrypts to a standard `.opus` file any player can open.
///
/// Pure Dart and incremental: pages come out as packets go in, so the
/// container never needs the whole recording in memory. OpusTags carries
/// no user comments, so nothing about the user ends up inside the file.
final class OggOpusMuxer {
  OggOpusMuxer({
    required this._serial,
    required this._channels,
    required this._preSkip,
    required this._inputSampleRate,
    this.packetsPerPage = 50,
  });

  /// RFC 6716 caps one Opus packet at 1275 bytes per frame and 120 ms;
  /// anything larger is not Opus and would need spanning pages.
  static const maxPacketBytes = 1275 * 6;

  /// One second of 20 ms packets per page keeps container overhead under
  /// half a percent at voice bitrates.
  final int packetsPerPage;

  final int _serial;
  final int _channels;
  final int _preSkip;
  final int _inputSampleRate;

  final _pending = <Uint8List>[];
  var _sequence = 0;
  var _decodedSamples = 0;
  var _finished = false;

  static const _beginningOfStream = 0x02;
  static const _endOfStream = 0x04;

  /// The OpusHead and OpusTags pages, which must open the stream.
  Uint8List header() {
    final head = BytesBuilder()
      ..add(ascii.encode('OpusHead'))
      ..addByte(1)
      ..addByte(_channels)
      ..add(_uint16(_preSkip))
      ..add(_uint32(_inputSampleRate))
      ..add(_uint16(0))
      ..addByte(0);
    final vendor = utf8.encode('ModusNote');
    final tags = BytesBuilder()
      ..add(ascii.encode('OpusTags'))
      ..add(_uint32(vendor.length))
      ..add(vendor)
      ..add(_uint32(0));
    return Uint8List.fromList([
      ..._page([head.takeBytes()], granule: 0, flags: _beginningOfStream),
      ..._page([tags.takeBytes()], granule: 0, flags: 0),
    ]);
  }

  /// Queues one packet of [samples] 48 kHz samples; returns the previous
  /// page once [packetsPerPage] packets are full and another one arrives,
  /// otherwise null. Holding a full page back means the end-of-stream page
  /// always carries the last packet, so its trimming granule never goes
  /// below the page before it (RFC 7845, section 4).
  Uint8List? addPacket(Uint8List packet, {required int samples}) {
    _checkOpen();
    if (packet.length > maxPacketBytes) {
      throw ArgumentError.value(packet.length, 'packet', 'larger than Opus');
    }
    final page = _pending.length < packetsPerPage ? null : _flush(flags: 0);
    _pending.add(Uint8List.fromList(packet));
    _decodedSamples += samples;
    return page;
  }

  /// Flushes the remaining packets in a final end-of-stream page whose
  /// granule trims the encoder padding down to [originalSamples].
  Uint8List finish({required int originalSamples}) {
    _checkOpen();
    final granule = _decodedSamples == 0 ? 0 : _preSkip + originalSamples;
    if (granule > _decodedSamples) {
      throw ArgumentError.value(
        originalSamples,
        'originalSamples',
        'more than the encoded packets can decode to',
      );
    }
    _finished = true;
    return _flush(flags: _endOfStream, granule: granule);
  }

  void _checkOpen() {
    if (_finished) throw StateError('muxer already finished');
  }

  Uint8List _flush({required int flags, int? granule}) {
    // A flushed page holds every packet decoded so far.
    final page = _page(
      List.of(_pending),
      granule: granule ?? _decodedSamples,
      flags: flags,
    );
    _pending.clear();
    return page;
  }

  Uint8List _page(
    List<Uint8List> packets, {
    required int granule,
    required int flags,
  }) {
    final lacing = <int>[
      for (final packet in packets) ...[
        ...List.filled(packet.length ~/ 255, 255),
        packet.length % 255,
      ],
    ];
    final bodyLength = packets.fold<int>(0, (sum, p) => sum + p.length);
    final page = Uint8List(27 + lacing.length + bodyLength);
    final view = ByteData.sublistView(page);
    page.setAll(0, ascii.encode('OggS'));
    view
      ..setUint8(4, 0)
      ..setUint8(5, flags)
      ..setInt64(6, granule, Endian.little)
      ..setUint32(14, _serial, Endian.little)
      ..setUint32(18, _sequence++, Endian.little)
      ..setUint8(26, lacing.length);
    page.setAll(27, lacing);
    var offset = 27 + lacing.length;
    for (final packet in packets) {
      page.setAll(offset, packet);
      offset += packet.length;
    }
    view.setUint32(22, crc(page), Endian.little);
    return page;
  }

  /// Ogg's CRC-32: polynomial 0x04C11DB7, not reflected, no final xor.
  static int crc(List<int> bytes) {
    var crc = 0;
    for (final byte in bytes) {
      crc = ((crc << 8) & 0xFFFFFFFF) ^ _crcTable[((crc >> 24) ^ byte) & 0xFF];
    }
    return crc;
  }

  static final _crcTable = List<int>.generate(256, (index) {
    var value = index << 24;
    for (var bit = 0; bit < 8; bit++) {
      value = (value & 0x80000000) != 0
          ? ((value << 1) ^ 0x04C11DB7) & 0xFFFFFFFF
          : (value << 1) & 0xFFFFFFFF;
    }
    return value;
  }, growable: false);

  static Uint8List _uint16(int value) =>
      Uint8List(2)..buffer.asByteData().setUint16(0, value, Endian.little);

  static Uint8List _uint32(int value) =>
      Uint8List(4)..buffer.asByteData().setUint32(0, value, Endian.little);
}
