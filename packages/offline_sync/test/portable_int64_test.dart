import 'dart:typed_data';

import 'package:offline_sync/src/core/portable_int64.dart';
import 'package:test/test.dart';

/// Runs on the VM and, in CI, compiled to JavaScript (`dart test -p chrome`):
/// the same bytes must mean the same number on the phone and in a browser
/// without WasmGC, where dart2js has no Int64 accessors.
void main() {
  Uint8List write(int value) {
    final bytes = Uint8List(8);
    setPortableInt64(ByteData.sublistView(bytes), 0, value);
    return bytes;
  }

  int? read(List<int> bytes) =>
      getPortableInt64(ByteData.sublistView(Uint8List.fromList(bytes)), 0);

  const vectors = <int, List<int>>{
    0: [0, 0, 0, 0, 0, 0, 0, 0],
    1: [0, 0, 0, 0, 0, 0, 0, 1],
    -1: [255, 255, 255, 255, 255, 255, 255, 255],
    4294967296: [0, 0, 0, 1, 0, 0, 0, 0],
    -4294967296: [255, 255, 255, 255, 0, 0, 0, 0],
    // A timestamp in microseconds, as the formats store it.
    1760252400000000: [0, 6, 64, 240, 179, 4, 92, 0],
    maxPortableInt: [0, 31, 255, 255, 255, 255, 255, 255],
    -maxPortableInt: [255, 224, 0, 0, 0, 0, 0, 1],
  };

  test('big-endian two\'s complement, like ByteData.setInt64', () {
    vectors.forEach((value, bytes) {
      expect(write(value), bytes, reason: '$value');
      expect(read(bytes), value, reason: '$value');
    });
  });

  test('round-trips values around the 32-bit boundaries', () {
    for (final value in [
      2147483647,
      2147483648,
      4294967295,
      4294967297,
      -2147483648,
      -2147483649,
      -4294967295,
      -4294967297,
      123456789012345,
      -123456789012345,
    ]) {
      expect(read(write(value)), value, reason: '$value');
    }
  });

  group('adversary', () {
    test('values a browser cannot hold exactly are refused when read', () {
      expect(read([0, 32, 0, 0, 0, 0, 0, 0]), isNull); // 2^53
      expect(read([255, 224, 0, 0, 0, 0, 0, 0]), isNull); // -2^53
      expect(read([127, 255, 255, 255, 255, 255, 255, 255]), isNull);
      expect(read([128, 0, 0, 0, 0, 0, 0, 0]), isNull);
    });

    test('and never written', () {
      expect(() => write(maxPortableInt + 1), throwsRangeError);
      expect(() => write(-maxPortableInt - 1), throwsRangeError);
    });
  });
}
