import 'dart:typed_data';

/// The largest integer a browser holds exactly: 2^53 − 1.
const maxPortableInt = 9007199254740991;

const _twoTo32 = 4294967296;

/// Writes [value] as a big-endian signed 64-bit integer, as
/// `ByteData.setInt64` would, but through two 32-bit halves: compiled to
/// JavaScript (the web build's fallback for browsers without WasmGC) Dart has
/// no 64-bit accessors. Values beyond ±[maxPortableInt] are refused, because
/// the browser could not read them back exactly.
void setPortableInt64(ByteData data, int offset, int value) {
  RangeError.checkValueInInterval(value, -maxPortableInt, maxPortableInt);
  var high = value ~/ _twoTo32;
  if (value < 0 && high * _twoTo32 != value) high -= 1;
  data
    ..setInt32(offset, high)
    ..setUint32(offset + 4, value - high * _twoTo32);
}

/// Reads what [setPortableInt64] writes; null when the bytes hold a value
/// beyond ±[maxPortableInt], so every platform reads the same number or
/// refuses the input.
int? getPortableInt64(ByteData data, int offset) {
  final high = data.getInt32(offset);
  if (high > 0x1FFFFF || high < -0x200000) return null;
  final value = high * _twoTo32 + data.getUint32(offset + 4);
  return value.abs() > maxPortableInt ? null : value;
}
