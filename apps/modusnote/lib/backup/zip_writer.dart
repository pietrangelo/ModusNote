import 'dart:convert';
import 'dart:typed_data';

/// A ZIP archive of stored (uncompressed) files, written in memory: enough
/// for a folder of Markdown notes that any system opens, with no
/// dependency. Names are UTF-8 (flag bit 11), times in the archive's local
/// DOS format.
final class ZipWriter {
  ZipWriter({required this._at});

  final DateTime _at;
  final _files = BytesBuilder(copy: false);
  final _directory = BytesBuilder(copy: false);
  final _names = <String>{};
  var _count = 0;

  /// The most files, and the most bytes in all, a plain ZIP can hold.
  static const maxFiles = 0xFFFF;
  static const maxBytes = 0xFFFFFFFF;

  /// Adds [data] under [name], a relative path with `/` between folders.
  /// Throws [ArgumentError] for a name already used, and [StateError] past
  /// [maxFiles] or [maxBytes].
  void add(String name, List<int> data) {
    if (!_names.add(name)) {
      throw ArgumentError.value(name, 'name', 'already in the archive');
    }
    if (_count == maxFiles) throw StateError('too many files for a ZIP');
    final encoded = utf8.encode(name);
    final offset = _files.length;
    if (offset + 30 + encoded.length + data.length > maxBytes) {
      throw StateError('too large for a ZIP');
    }
    final crc = crc32(data);
    final time = _dosTime(_at);
    final date = _dosDate(_at);
    _files
      ..add(
        _le([
          (0x04034b50, 4),
          (20, 2), // version needed
          (_utf8Names, 2),
          (0, 2), // stored
          (time, 2),
          (date, 2),
          (crc, 4),
          (data.length, 4),
          (data.length, 4),
          (encoded.length, 2),
          (0, 2), // no extra field
        ]),
      )
      ..add(encoded)
      ..add(data);
    _directory
      ..add(
        _le([
          (0x02014b50, 4),
          (20, 2), // made by
          (20, 2), // needed
          (_utf8Names, 2),
          (0, 2),
          (time, 2),
          (date, 2),
          (crc, 4),
          (data.length, 4),
          (data.length, 4),
          (encoded.length, 2),
          (0, 2), // extra
          (0, 2), // comment
          (0, 2), // disk
          (0, 2), // internal attributes
          (0, 4), // external attributes
          (offset, 4),
        ]),
      )
      ..add(encoded);
    _count++;
  }

  /// The whole archive; the writer is spent afterwards.
  Uint8List finish() {
    final directoryAt = _files.length;
    final directorySize = _directory.length;
    if (directoryAt + directorySize + 22 > maxBytes) {
      throw StateError('too large for a ZIP');
    }
    return (BytesBuilder(copy: false)
          ..add(_files.takeBytes())
          ..add(_directory.takeBytes())
          ..add(
            _le([
              (0x06054b50, 4),
              (0, 2),
              (0, 2),
              (_count, 2),
              (_count, 2),
              (directorySize, 4),
              (directoryAt, 4),
              (0, 2), // comment
            ]),
          ))
        .takeBytes();
  }

  static const _utf8Names = 1 << 11;

  static int _dosTime(DateTime at) =>
      at.hour << 11 | at.minute << 5 | at.second ~/ 2;

  static int _dosDate(DateTime at) =>
      (at.year - 1980).clamp(0, 127) << 9 | at.month << 5 | at.day;

  static Uint8List _le(List<(int, int)> fields) {
    final out = BytesBuilder(copy: false);
    for (final (value, width) in fields) {
      for (var i = 0; i < width; i++) {
        out.addByte(value >> (8 * i) & 0xFF);
      }
    }
    return out.takeBytes();
  }

  /// CRC-32 (IEEE 802.3), as ZIP and PNG use it.
  static int crc32(List<int> data) {
    var crc = 0xFFFFFFFF;
    for (final byte in data) {
      crc = _table[(crc ^ byte) & 0xFF] ^ (crc >>> 8);
    }
    return crc ^ 0xFFFFFFFF;
  }

  static final _table = List<int>.generate(256, (n) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = c & 1 == 1 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1;
    }
    return c;
  });
}
