import 'dart:typed_data';

import 'package:blob_storage_media/blob_storage_media.dart';

import 'ogg_opus_muxer.dart';

/// What an Ogg Opus stream holds once its container is taken apart: the
/// packets to decode and the two numbers that say which samples to keep.
final class OggOpusRecording {
  OggOpusRecording({
    required this.channels,
    required this.preSkip,
    required this.finalGranule,
    required List<Uint8List> packets,
  }) : packets = List.unmodifiable(packets);

  final int channels;

  /// Samples at 48 kHz the decoder emits before the first real one.
  final int preSkip;

  /// Pre-skip plus the playable samples; anything decoded past it is
  /// encoder padding.
  final int finalGranule;

  final List<Uint8List> packets;
}

/// Reads back what [OggOpusMuxer] writes (RFC 3533, RFC 7845), and only
/// that: one logical stream, one packet per header page, no packet split
/// across pages, mono or stereo with mapping family 0.
///
/// The bytes come out of an authenticated blob, so a hostile stream needs
/// a member's key; it is parsed strictly anyway, and anything off the
/// expected shape is a [MalformedBlobException], never another error.
final class OggOpusDemuxer {
  const OggOpusDemuxer({this.maxBytes = 32 << 20});

  /// Thirty minutes at 32 kbit/s is about 7 MB; the cap stops a stream
  /// from filling memory before it is parsed.
  final int maxBytes;

  static const _continued = 0x01;
  static const _beginningOfStream = 0x02;
  static const _endOfStream = 0x04;
  static const _headerBytes = 27;
  static const _opusHeadBytes = 19;

  Future<OggOpusRecording> read(Stream<Uint8List> stream) async {
    final buffer = BytesBuilder(copy: false);
    await for (final piece in stream) {
      if (buffer.length + piece.length > maxBytes) {
        throw const MalformedBlobException('Ogg stream too large');
      }
      buffer.add(piece);
    }
    return parse(buffer.takeBytes());
  }

  OggOpusRecording parse(Uint8List bytes) {
    final pages = _Pages(bytes);
    final first = pages.next();
    if (first == null || first.flags != _beginningOfStream) {
      throw const MalformedBlobException('missing OpusHead page');
    }
    final head = _single(first);
    final view = ByteData.sublistView(head);
    if (head.length != _opusHeadBytes ||
        !_startsWith(head, 'OpusHead') ||
        head[8] & 0xF0 != 0 ||
        head[9] < 1 ||
        head[9] > 2 ||
        view.getInt16(16, Endian.little) != 0 ||
        head[18] != 0) {
      throw const MalformedBlobException('unsupported OpusHead');
    }
    final channels = head[9];
    final preSkip = view.getUint16(10, Endian.little);
    if (first.granule != 0) {
      throw const MalformedBlobException('header page with a granule');
    }

    final tagsPage = pages.next();
    if (tagsPage == null ||
        tagsPage.flags != 0 ||
        tagsPage.granule != 0 ||
        !_startsWith(_single(tagsPage), 'OpusTags')) {
      throw const MalformedBlobException('missing OpusTags page');
    }

    final packets = <Uint8List>[];
    var granule = 0;
    while (true) {
      final page = pages.next();
      if (page == null) {
        throw const MalformedBlobException('Ogg stream without an end');
      }
      if (page.flags & ~_endOfStream != 0) {
        throw const MalformedBlobException('unsupported Ogg page flags');
      }
      if (page.granule < granule) {
        throw const MalformedBlobException('Ogg granule went back');
      }
      granule = page.granule;
      for (final packet in page.packets) {
        if (packet.isEmpty || packet.length > OggOpusMuxer.maxPacketBytes) {
          throw const MalformedBlobException('not an Opus packet');
        }
        packets.add(packet);
      }
      if (page.flags & _endOfStream != 0) break;
    }
    if (pages.next() != null) {
      throw const MalformedBlobException('data after the end of stream');
    }
    if (packets.isEmpty ? granule != 0 : granule < preSkip) {
      throw const MalformedBlobException('final granule out of range');
    }
    return OggOpusRecording(
      channels: channels,
      preSkip: preSkip,
      finalGranule: granule,
      packets: packets,
    );
  }

  static Uint8List _single(_Page page) {
    if (page.packets.length != 1) {
      throw const MalformedBlobException('header page with extra packets');
    }
    return page.packets.single;
  }

  static bool _startsWith(Uint8List bytes, String magic) {
    if (bytes.length < magic.length) return false;
    for (var i = 0; i < magic.length; i++) {
      if (bytes[i] != magic.codeUnitAt(i)) return false;
    }
    return true;
  }
}

final class _Page {
  _Page(this.flags, this.granule, this.packets);

  final int flags;
  final int granule;
  final List<Uint8List> packets;
}

/// Walks the pages of one logical stream, checking capture pattern,
/// version, checksum, serial and sequence as it goes.
final class _Pages {
  _Pages(this._bytes);

  final Uint8List _bytes;
  var _offset = 0;
  var _sequence = 0;
  int? _serial;

  /// The next page, or null at the end of the bytes.
  _Page? next() {
    if (_offset == _bytes.length) return null;
    final start = _offset;
    _need(OggOpusDemuxer._headerBytes);
    final view = ByteData.sublistView(_bytes, start);
    if (!OggOpusDemuxer._startsWith(
          Uint8List.sublistView(_bytes, start, start + 4),
          'OggS',
        ) ||
        view.getUint8(4) != 0) {
      throw const MalformedBlobException('not an Ogg page');
    }
    final flags = view.getUint8(5);
    final granule = view.getInt64(6, Endian.little);
    final serial = view.getUint32(14, Endian.little);
    final sequence = view.getUint32(18, Endian.little);
    final storedCrc = view.getUint32(22, Endian.little);
    final segments = view.getUint8(26);
    _need(OggOpusDemuxer._headerBytes + segments);
    final lacing = Uint8List.sublistView(
      _bytes,
      start + OggOpusDemuxer._headerBytes,
      start + OggOpusDemuxer._headerBytes + segments,
    );
    final bodyLength = lacing.fold<int>(0, (sum, value) => sum + value);
    final length = OggOpusDemuxer._headerBytes + segments + bodyLength;
    _need(length);

    final page = Uint8List.fromList(
      Uint8List.sublistView(_bytes, start, start + length),
    )..fillRange(22, 26, 0);
    if (OggOpusMuxer.crc(page) != storedCrc) {
      throw const MalformedBlobException('Ogg page checksum mismatch');
    }
    if ((_serial ??= serial) != serial || sequence != _sequence) {
      throw const MalformedBlobException('Ogg pages out of sequence');
    }
    if (flags & OggOpusDemuxer._continued != 0 ||
        (_sequence > 0 && flags & OggOpusDemuxer._beginningOfStream != 0) ||
        granule < 0) {
      throw const MalformedBlobException('unsupported Ogg page flags');
    }

    final packets = <Uint8List>[];
    var cursor = OggOpusDemuxer._headerBytes + segments;
    var packetStart = cursor;
    for (final value in lacing) {
      cursor += value;
      if (value < 255) {
        packets.add(Uint8List.sublistView(page, packetStart, cursor));
        packetStart = cursor;
      }
    }
    if (packetStart != cursor) {
      throw const MalformedBlobException('packet continues past its page');
    }
    _offset = start + length;
    _sequence++;
    return _Page(flags, granule, packets);
  }

  void _need(int count) {
    if (_offset + count > _bytes.length) {
      throw const MalformedBlobException('Ogg stream truncated');
    }
  }
}
