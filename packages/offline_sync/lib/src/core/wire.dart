import 'dart:typed_data';

import 'portable_int64.dart';
import 'sync_exception.dart';

/// Big-endian writer for the signed wire formats of this context.
final class WireWriter {
  final _bytes = BytesBuilder(copy: false);

  void uint8(int value) => _bytes.addByte(value);

  // ByteData truncates out-of-range values silently; a record written that
  // way would never parse again.
  void uint16(int value) => _bytes.add(
    Uint8List(2)..buffer.asByteData().setUint16(0, _range(value, 0xffff)),
  );

  void uint32(int value) => _bytes.add(
    Uint8List(4)..buffer.asByteData().setUint32(0, _range(value, 0xffffffff)),
  );

  static int _range(int value, int max) => value >= 0 && value <= max
      ? value
      : throw RangeError.range(value, 0, max);

  void int64(int value) {
    final bytes = Uint8List(8);
    setPortableInt64(ByteData.sublistView(bytes), 0, value);
    _bytes.add(bytes);
  }

  void bytes(List<int> value) => _bytes.add(value);

  /// Length-prefixed (uint32) bytes.
  void blob(List<int> value) {
    uint32(value.length);
    bytes(value);
  }

  Uint8List take() => _bytes.takeBytes();
}

/// Strict reader: bounds-checked reads and no trailing bytes, so parsers
/// built on it fail with [MalformedSyncDataException] and nothing else.
final class WireReader {
  WireReader(List<int> bytes) : _bytes = Uint8List.fromList(bytes);

  final Uint8List _bytes;
  var _offset = 0;

  int get remaining => _bytes.length - _offset;

  int uint8() => _take(1)[0];

  int uint16() => ByteData.sublistView(_take(2)).getUint16(0);

  int uint32() => ByteData.sublistView(_take(4)).getUint32(0);

  /// Values a browser cannot hold exactly (beyond ±(2^53 − 1)) are malformed.
  int int64() =>
      getPortableInt64(ByteData.sublistView(_take(8)), 0) ??
      (throw const MalformedSyncDataException('integer out of range'));

  Uint8List bytes(int length) => _take(length);

  Uint8List blob() => _take(uint32());

  void finish() {
    if (remaining != 0) {
      throw const MalformedSyncDataException('trailing bytes');
    }
  }

  Uint8List _take(int length) {
    if (length > remaining) {
      throw const MalformedSyncDataException('truncated');
    }
    final view = Uint8List.sublistView(_bytes, _offset, _offset + length);
    _offset += length;
    return view;
  }
}
