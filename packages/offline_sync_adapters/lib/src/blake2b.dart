import 'dart:typed_data';

/// BLAKE2b-256 (RFC 7693, unkeyed) in plain Dart, for the proof of work on
/// native platforms: about a million hashes, where each call through
/// libsodium's FFI leaves a guarded allocation for the garbage collector to
/// free, and the process runs out of memory mappings first.
///
/// Native and WebAssembly only: it relies on 64-bit integers that wrap,
/// which JavaScript does not have. The web build hashes with libsodium.js.
Uint8List blake2b256(Uint8List message) {
  final h = Int64List.fromList(_iv);
  // Parameter block: digest length 32, no key, fanout 1, depth 1.
  h[0] ^= 0x01010000 ^ 32;
  final block = Uint8List(128);
  final blockWords = ByteData.sublistView(block);
  final m = Int64List(16);
  final v = Int64List(16);
  var offset = 0;
  var counter = 0;
  do {
    final remaining = message.length - offset;
    final last = remaining <= 128;
    final take = last ? remaining : 128;
    block.fillRange(0, 128, 0);
    block.setRange(0, take, message, offset);
    offset += take;
    counter += take;
    for (var i = 0; i < 16; i++) {
      m[i] = blockWords.getInt64(i * 8, Endian.little);
    }
    _compress(h, m, v, counter, last);
  } while (offset < message.length);
  final out = ByteData(32);
  for (var i = 0; i < 4; i++) {
    out.setInt64(i * 8, h[i], Endian.little);
  }
  return out.buffer.asUint8List();
}

void _compress(Int64List h, Int64List m, Int64List v, int counter, bool last) {
  for (var i = 0; i < 8; i++) {
    v[i] = h[i];
    v[i + 8] = _iv[i];
  }
  v[12] ^= counter;
  if (last) v[14] = ~v[14];
  for (var round = 0; round < 12; round++) {
    final s = _sigma[round % 10];
    _g(v, 0, 4, 8, 12, m[s[0]], m[s[1]]);
    _g(v, 1, 5, 9, 13, m[s[2]], m[s[3]]);
    _g(v, 2, 6, 10, 14, m[s[4]], m[s[5]]);
    _g(v, 3, 7, 11, 15, m[s[6]], m[s[7]]);
    _g(v, 0, 5, 10, 15, m[s[8]], m[s[9]]);
    _g(v, 1, 6, 11, 12, m[s[10]], m[s[11]]);
    _g(v, 2, 7, 8, 13, m[s[12]], m[s[13]]);
    _g(v, 3, 4, 9, 14, m[s[14]], m[s[15]]);
  }
  for (var i = 0; i < 8; i++) {
    h[i] ^= v[i] ^ v[i + 8];
  }
}

void _g(Int64List v, int a, int b, int c, int d, int x, int y) {
  v[a] = v[a] + v[b] + x;
  v[d] = _rotr(v[d] ^ v[a], 32);
  v[c] = v[c] + v[d];
  v[b] = _rotr(v[b] ^ v[c], 24);
  v[a] = v[a] + v[b] + y;
  v[d] = _rotr(v[d] ^ v[a], 16);
  v[c] = v[c] + v[d];
  v[b] = _rotr(v[b] ^ v[c], 63);
}

int _rotr(int x, int n) => (x >>> n) | (x << (64 - n));

const _iv = [
  0x6a09e667f3bcc908,
  -0x4498517a7b3558c5, // 0xbb67ae8584caa73b
  0x3c6ef372fe94f82b,
  -0x5ab00ac5a0e2c90f, // 0xa54ff53a5f1d36f1
  0x510e527fade682d1,
  -0x64fa9773d4c193e1, // 0x9b05688c2b3e6c1f
  0x1f83d9abfb41bd6b,
  0x5be0cd19137e2179,
];

const _sigma = [
  [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
  [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
  [11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4],
  [7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8],
  [9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13],
  [2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9],
  [12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11],
  [13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10],
  [6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5],
  [10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0],
];
