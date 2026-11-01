import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import 'blob_exception.dart';
import 'blob_metadata.dart';
import 'portable_int64.dart';

/// The video format a step can hold: MP4 (and QuickTime, its parent),
/// what phones record and browsers play. Anything else is refused before
/// it is sealed: the app never re-encodes.
enum VideoFormat {
  mp4('mp4', 'video/mp4');

  const VideoFormat(this.wireName, this.mimeType);

  /// Stable name for persisted metadata; independent of enum order.
  final String wireName;
  final String mimeType;

  static VideoFormat fromWireName(String wireName) {
    for (final format in values) {
      if (format.wireName == wireName) return format;
    }
    throw const InvalidBlobMetadataException('unknown video format');
  }
}

/// A video's format, size in pixels and length, as its own boxes state
/// them.
@immutable
final class VideoHeader {
  VideoHeader(this.format, this.width, this.height, this.duration) {
    if (width < 1 ||
        height < 1 ||
        width > VideoProbe.maxSide ||
        height > VideoProbe.maxSide ||
        duration.isNegative ||
        duration > VideoProbe.maxDuration) {
      throw const VideoTooLargeException();
    }
  }

  final VideoFormat format;
  final int width;
  final int height;
  final Duration duration;

  @override
  bool operator ==(Object other) =>
      other is VideoHeader &&
      other.format == format &&
      other.width == width &&
      other.height == height &&
      other.duration == duration;

  @override
  int get hashCode => Object.hash(format, width, height, duration);

  @override
  String toString() =>
      'VideoHeader(${format.wireName}, $width×$height, '
      '${duration.inMilliseconds} ms)';
}

/// Describes one encrypted video blob; like [BlobMetadata], it travels
/// only inside the sealed note.
@immutable
final class VideoMetadata {
  VideoMetadata({
    required this.blob,
    required this.info,
    required this.addedAt,
  }) {
    if (blob.plaintextLength > VideoProbe.maxBytes) {
      throw const InvalidBlobMetadataException('video too large');
    }
    if (!addedAt.isUtc) {
      throw const InvalidBlobMetadataException('addedAt must be UTC');
    }
  }

  final SealedBlob blob;
  final VideoHeader info;
  final DateTime addedAt;

  BlobId get id => blob.id;

  VideoFormat get format => info.format;

  @override
  bool operator ==(Object other) =>
      other is VideoMetadata &&
      other.blob == blob &&
      other.info == info &&
      other.addedAt == addedAt;

  @override
  int get hashCode => Object.hash(blob, info, addedAt);
}

/// One box of an ISO base media file: where it starts, where its content
/// starts and where it ends, in the file.
final class _Box {
  _Box(this.type, this.start, this.content, this.end);

  final String type;
  final int start;
  final int content;
  final int end;
}

/// Reads boxes defensively: every size is checked against its parent, so
/// hostile bytes can only be refused.
final class _Boxes {
  _Boxes(this.bytes) : _data = ByteData.sublistView(bytes);

  final Uint8List bytes;
  final ByteData _data;

  int u8(int at) => _check(at, 1, () => _data.getUint8(at));
  int u16(int at) => _check(at, 2, () => _data.getUint16(at));
  int u32(int at) => _check(at, 4, () => _data.getUint32(at));
  int u64(int at) => _check(
    at,
    8,
    () =>
        getPortableInt64(_data, at) ??
        (throw const UnsupportedVideoException()),
  );

  int _check(int at, int width, int Function() read) {
    if (at < 0 || at + width > bytes.length) {
      throw const UnsupportedVideoException();
    }
    return read();
  }

  /// The boxes between [from] and [to].
  List<_Box> children(int from, int to) {
    final out = <_Box>[];
    var at = from;
    while (at < to) {
      if (to - at < 8) throw const UnsupportedVideoException();
      var size = u32(at);
      var header = 8;
      final type = latin1.decode(bytes.sublist(at + 4, at + 8));
      if (size == 1) {
        size = u64(at + 8);
        header = 16;
      } else if (size == 0) {
        size = to - at;
      }
      if (size < header || size > to - at) {
        throw const UnsupportedVideoException();
      }
      out.add(_Box(type, at, at + header, at + size));
      at += size;
      if (out.length > 4096) throw const UnsupportedVideoException();
    }
    return out;
  }

  _Box? first(_Box parent, String type) {
    for (final box in children(parent.content, parent.end)) {
      if (box.type == type) return box;
    }
    return null;
  }

  _Box? path(_Box parent, List<String> types) {
    _Box? at = parent;
    for (final type in types) {
      if (at == null) return null;
      at = first(at, type);
    }
    return at;
  }

  /// A track's handler: `vide`, `soun`, or anything else.
  String handler(_Box trak) {
    final hdlr = path(trak, ['mdia', 'hdlr']);
    if (hdlr == null) return '';
    // version and flags (4), pre_defined (4), then the type.
    final at = hdlr.content + 8;
    if (at + 4 > hdlr.end) throw const UnsupportedVideoException();
    return latin1.decode(bytes.sublist(at, at + 4));
  }
}

/// Reads what a video says about itself, without decoding it.
abstract final class VideoProbe {
  /// serv.pub takes files of at most 21 MiB.
  static const maxBytes = 21 * 1024 * 1024;

  /// A short clip of a step; a camera asked for 60 s may give a few
  /// frames more.
  static const maxDuration = Duration(seconds: 61);
  static const maxSide = 8192;

  static const _brands = {
    'isom',
    'iso2',
    'iso4',
    'iso5',
    'iso6',
    'mp41',
    'mp42',
    'avc1',
    'M4V ',
    'qt  ',
  };

  /// Throws [UnsupportedVideoException] or [VideoTooLargeException].
  static VideoHeader probe(Uint8List bytes) {
    if (bytes.length > maxBytes) throw const VideoTooLargeException();
    final boxes = _Boxes(bytes);
    final top = boxes.children(0, bytes.length);
    if (top.isEmpty || top.first.type != 'ftyp') {
      throw const UnsupportedVideoException();
    }
    final ftyp = top.first;
    final brands = <String>{
      for (var at = ftyp.content; at + 4 <= ftyp.end; at += 4)
        if (at != ftyp.content + 4) latin1.decode(bytes.sublist(at, at + 4)),
    };
    if (brands.intersection(_brands).isEmpty) {
      throw const UnsupportedVideoException();
    }
    final moovs = top.where((b) => b.type == 'moov').toList();
    if (moovs.length != 1 ||
        !top.any((b) => b.type == 'mdat') ||
        top.any((b) => b.type == 'moof')) {
      throw const UnsupportedVideoException();
    }
    final moov = moovs.single;
    final mvhd =
        boxes.first(moov, 'mvhd') ?? (throw const UnsupportedVideoException());
    final v1 = boxes.u8(mvhd.content) == 1;
    final timescale = boxes.u32(mvhd.content + (v1 ? 20 : 12));
    final length = v1
        ? boxes.u64(mvhd.content + 24)
        : boxes.u32(mvhd.content + 16);
    if (timescale == 0) throw const UnsupportedVideoException();
    // Past the limit before the conversion can overflow.
    if (length ~/ timescale > maxDuration.inSeconds) {
      throw const VideoTooLargeException();
    }
    final duration = Duration(microseconds: length * 1000000 ~/ timescale);
    for (final trak in boxes.children(moov.content, moov.end)) {
      if (trak.type != 'trak' || boxes.handler(trak) != 'vide') continue;
      final tkhd =
          boxes.first(trak, 'tkhd') ??
          (throw const UnsupportedVideoException());
      final at = tkhd.content + (boxes.u8(tkhd.content) == 1 ? 88 : 76);
      final width = boxes.u32(at) >> 16;
      final height = boxes.u32(at + 4) >> 16;
      return VideoHeader(VideoFormat.mp4, width, height, duration);
    }
    throw const UnsupportedVideoException();
  }
}

/// Rewrites a video keeping only what plays it: the location, the date,
/// the device and every other note a phone writes into the file stay out.
///
/// The rewrite keeps an allowlist of boxes and drops the rest, failing
/// closed: at the top `ftyp`, `moov` and `mdat`; in `moov` the header and
/// the video and sound tracks (a timed-metadata, text or other track is
/// dropped and its samples zeroed in `mdat`, since that is where some
/// cameras put the GPS track); in each track only what decoding needs,
/// with a data reference that points at the file itself. The creation and
/// modification times of the movie, its tracks and their media are set
/// to zero. Chunk offsets are moved to where the samples now are.
abstract final class VideoScrubber {
  static const _moov = {'mvhd', 'trak'};
  static const _trak = {'tkhd', 'edts', 'mdia'};
  static const _edts = {'elst'};
  static const _mdia = {'mdhd', 'hdlr', 'minf'};
  static const _minf = {'vmhd', 'smhd', 'dinf', 'stbl'};
  static const _stbl = {
    'stsd',
    'stts',
    'ctts',
    'cslg',
    'stss',
    'stps',
    'sdtp',
    'stsc',
    'stsz',
    'stz2',
    'stco',
    'co64',
    'sgpd',
    'sbgp',
  };

  /// A `dinf` whose one reference is the file itself.
  static final _selfDinf = Uint8List.fromList([
    0, 0, 0, 36, ...latin1.encode('dinf'), //
    0, 0, 0, 28, ...latin1.encode('dref'), 0, 0, 0, 0, 0, 0, 0, 1,
    0, 0, 0, 12, ...latin1.encode('url '), 0, 0, 0, 1,
  ]);

  /// Throws [UnsupportedVideoException] or [VideoTooLargeException].
  static Uint8List scrub(Uint8List bytes) {
    VideoProbe.probe(bytes);
    final boxes = _Boxes(bytes);
    final top = boxes.children(0, bytes.length);
    final moov = top.firstWhere((b) => b.type == 'moov');
    final mdats = [
      for (final box in top)
        if (box.type == 'mdat') box,
    ];

    // The samples of dropped tracks, zeroed in the copies of mdat.
    final zeroed = <(int, int)>[];
    final kept = <int>{};
    for (final trak in boxes.children(moov.content, moov.end)) {
      if (trak.type != 'trak') continue;
      final handler = boxes.handler(trak);
      if (handler == 'vide' || handler == 'soun') {
        kept.add(trak.start);
      } else {
        zeroed.addAll(_chunks(boxes, trak));
      }
    }

    // The new moov, with the offset tables noted to patch them once the
    // file's new layout is known.
    final tables = <(int at, _Box table)>[];
    final out = BytesBuilder(copy: false);
    void copy(_Box box, Set<String> allowed) {
      final start = out.length;
      out.add(Uint8List(8)); // size and type, written below
      for (final child in boxes.children(box.content, box.end)) {
        if (!allowed.contains(child.type)) continue;
        if (box.type == 'moov' &&
            child.type == 'trak' &&
            !kept.contains(child.start)) {
          continue;
        }
        switch (child.type) {
          case 'trak':
            copy(child, _trak);
          case 'edts':
            copy(child, _edts);
          case 'mdia':
            copy(child, _mdia);
          case 'minf':
            copy(child, _minf);
          case 'stbl':
            copy(child, _stbl);
          case 'dinf':
            out.add(_selfDinf);
          case 'mvhd' || 'tkhd' || 'mdhd':
            out.add(_timeless(boxes, child));
          case 'stco' || 'co64':
            tables.add((out.length, child));
            out.add(_whole(bytes, child));
          default:
            out.add(_whole(bytes, child));
        }
      }
      _header(out, start, box.type);
    }

    copy(moov, _moov);
    final newMoov = out.takeBytes();

    // ftyp, moov, then each mdat (a 64-bit size kept as it was).
    final ftyp = top.first;
    final starts = <_Box, int>{};
    var at = ftyp.end - ftyp.start + newMoov.length;
    for (final mdat in mdats) {
      starts[mdat] = at;
      at += mdat.end - mdat.start;
    }
    int moved(int offset) {
      for (final mdat in mdats) {
        if (offset >= mdat.content && offset <= mdat.end) {
          return starts[mdat]! + (offset - mdat.start);
        }
      }
      throw const UnsupportedVideoException();
    }

    final moovData = ByteData.sublistView(newMoov);
    for (final (pos, table) in tables) {
      final wide = table.type == 'co64';
      final count = moovData.getUint32(pos + 12);
      final width = wide ? 8 : 4;
      if (16 + count * width > table.end - table.start) {
        throw const UnsupportedVideoException();
      }
      for (var i = 0; i < count; i++) {
        final entry = pos + 16 + i * width;
        if (wide) {
          final value =
              getPortableInt64(moovData, entry) ??
              (throw const UnsupportedVideoException());
          setPortableInt64(moovData, entry, moved(value));
        } else {
          final value = moved(moovData.getUint32(entry));
          if (value > 0xFFFFFFFF) throw const UnsupportedVideoException();
          moovData.setUint32(entry, value);
        }
      }
    }

    final file = BytesBuilder(copy: false)
      ..add(Uint8List.sublistView(bytes, ftyp.start, ftyp.end))
      ..add(newMoov);
    for (final mdat in mdats) {
      final copy = Uint8List.fromList(
        Uint8List.sublistView(bytes, mdat.start, mdat.end),
      );
      for (final (from, to) in zeroed) {
        final a = (from - mdat.start).clamp(
          mdat.content - mdat.start,
          copy.length,
        );
        final b = (to - mdat.start).clamp(
          mdat.content - mdat.start,
          copy.length,
        );
        if (a < b) copy.fillRange(a, b, 0);
      }
      file.add(copy);
    }
    return file.takeBytes();
  }

  static Uint8List _whole(Uint8List bytes, _Box box) =>
      Uint8List.sublistView(bytes, box.start, box.end);

  /// Writes the size and type of the box that started at [start].
  static void _header(BytesBuilder out, int start, String type) {
    final all = out.takeBytes();
    final data = ByteData.sublistView(all);
    final size = all.length - start;
    data.setUint32(start, size);
    all.setRange(start + 4, start + 8, latin1.encode(type));
    out.add(all);
  }

  /// A header box with its creation and modification times set to zero.
  static Uint8List _timeless(_Boxes boxes, _Box box) {
    final copy = Uint8List.fromList(_whole(boxes.bytes, box));
    final content = box.content - box.start;
    final v1 = boxes.u8(box.content) == 1;
    final width = v1 ? 16 : 8;
    if (content + 4 + width > copy.length) {
      throw const UnsupportedVideoException();
    }
    copy.fillRange(content + 4, content + 4 + width, 0);
    return copy;
  }

  /// Where each chunk of [trak] is in the file: its offset and the sum of
  /// its samples' sizes.
  static List<(int, int)> _chunks(_Boxes boxes, _Box trak) {
    final stbl = boxes.path(trak, ['mdia', 'minf', 'stbl']);
    if (stbl == null) return const [];
    final stco = boxes.first(stbl, 'stco');
    final co64 = boxes.first(stbl, 'co64');
    final stsc = boxes.first(stbl, 'stsc');
    final stsz = boxes.first(stbl, 'stsz');
    if ((stco == null && co64 == null) || stsc == null || stsz == null) {
      throw const UnsupportedVideoException();
    }
    final table = stco ?? co64!;
    final wide = stco == null;
    final chunks = boxes.u32(table.content + 4);
    if (chunks > (table.end - table.content) ~/ 4) {
      throw const UnsupportedVideoException();
    }
    final offsets = [
      for (var i = 0; i < chunks; i++)
        wide
            ? boxes.u64(table.content + 8 + i * 8)
            : boxes.u32(table.content + 8 + i * 4),
    ];
    final runs = boxes.u32(stsc.content + 4);
    if (runs > (stsc.end - stsc.content) ~/ 12) {
      throw const UnsupportedVideoException();
    }
    final uniform = boxes.u32(stsz.content + 4);
    final samples = boxes.u32(stsz.content + 8);
    if (uniform == 0 && samples > (stsz.end - stsz.content) ~/ 4) {
      throw const UnsupportedVideoException();
    }
    int sizeOf(int sample) => uniform != 0
        ? uniform
        : sample < samples
        ? boxes.u32(stsz.content + 12 + sample * 4)
        : 0;
    final out = <(int, int)>[];
    var sample = 0;
    for (var r = 0; r < runs; r++) {
      final first = boxes.u32(stsc.content + 8 + r * 12) - 1;
      final perChunk = boxes.u32(stsc.content + 12 + r * 12);
      final last = r + 1 < runs
          ? boxes.u32(stsc.content + 8 + (r + 1) * 12) - 1
          : chunks;
      if (first < 0 || last > chunks || first > last) {
        throw const UnsupportedVideoException();
      }
      for (var c = first; c < last; c++) {
        var size = 0;
        for (var s = 0; s < perChunk && sample < samples; s++) {
          size += sizeOf(sample++);
        }
        out.add((offsets[c], offsets[c] + size));
      }
    }
    return out;
  }
}
