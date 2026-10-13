import 'dart:typed_data';

/// The largest integer a browser holds exactly: 2^53 − 1.
const maxPortableInt = 9007199254740991;

const _twoTo32 = 4294967296;

/// Writes [value] as a signed 64-bit integer in [endian] order (big-endian
/// unless asked), as `ByteData.setInt64` would, but through two 32-bit halves: compiled to
/// JavaScript (the web build's fallback for browsers without WasmGC) Dart has
/// no 64-bit accessors. Values beyond ±[maxPortableInt] are refused, because
/// the browser could not read them back exactly.
void setPortableInt64(
  ByteData data,
  int offset,
  int value, [
  Endian endian = Endian.big,
]) {
  RangeError.checkValueInInterval(value, -maxPortableInt, maxPortableInt);
  var high = value ~/ _twoTo32;
  if (value < 0 && high * _twoTo32 != value) high -= 1;
  final (highAt, lowAt) = _halves(offset, endian);
  data
    ..setInt32(highAt, high, endian)
    ..setUint32(lowAt, value - high * _twoTo32, endian);
}

/// Reads what [setPortableInt64] writes; null when the bytes hold a value
/// beyond ±[maxPortableInt], so every platform reads the same number or
/// refuses the input.
int? getPortableInt64(ByteData data, int offset, [Endian endian = Endian.big]) {
  final (highAt, lowAt) = _halves(offset, endian);
  final high = data.getInt32(highAt, endian);
  if (high > 0x1FFFFF || high < -0x200000) return null;
  final value = high * _twoTo32 + data.getUint32(lowAt, endian);
  return value.abs() > maxPortableInt ? null : value;
}

/// Where the high and the low 32 bits of a 64-bit integer at [offset] sit.
(int, int) _halves(int offset, Endian endian) =>
    endian == Endian.big ? (offset, offset + 4) : (offset + 4, offset);
