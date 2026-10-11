import 'dart:convert';
import 'dart:typed_data';

import 'collaboration_exception.dart';

/// Big-endian writer for the signed wire formats of this context.
final class WireWriter {
  final _bytes = BytesBuilder(copy: false);

  void label(String text) => _bytes.add(ascii.encode(text));

  void uint8(int value) => _bytes.addByte(value);

  void uint16(int value) =>
      _bytes.add(Uint8List(2)..buffer.asByteData().setUint16(0, value));

  void uint32(int value) =>
      _bytes.add(Uint8List(4)..buffer.asByteData().setUint32(0, value));

  void bytes(List<int> value) => _bytes.add(value);

  Uint8List take() => _bytes.takeBytes();
}

/// Strict reader: every read is bounds-checked and [finish] refuses trailing
/// bytes, so a parser built on it fails with
/// [MalformedWorkspaceDataException] and nothing else.
final class WireReader {
  WireReader(this._bytes);

  final Uint8List _bytes;
  var _offset = 0;

  int get remaining => _bytes.length - _offset;

  int uint8() => _take(1)[0];

  int uint16() => ByteData.sublistView(_take(2)).getUint16(0);

  int uint32() => ByteData.sublistView(_take(4)).getUint32(0);

  Uint8List bytes(int length) => _take(length);

  void finish() {
    if (remaining != 0) {
      throw const MalformedWorkspaceDataException('trailing bytes');
    }
  }

  Uint8List _take(int length) {
    if (length > remaining) {
      throw const MalformedWorkspaceDataException('truncated');
    }
    final view = Uint8List.sublistView(_bytes, _offset, _offset + length);
    _offset += length;
    return view;
  }
}
