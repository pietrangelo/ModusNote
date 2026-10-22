@TestOn('vm')
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:offline_sync_adapters/offline_sync_adapters.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:test/test.dart';

void main() {
  late SodiumSumo sodium;

  setUpAll(() async => sodium = await SodiumSumoInit.init());

  test('the RFC 7693 test vector, truncated to 256 bits by its parameter', () {
    // BLAKE2b-256("abc"), as libsodium and every other implementation give.
    expect(
      _hex(blake2b256(Uint8List.fromList('abc'.codeUnits))),
      'bddd813c634239723171ef3fee98579b94964e3bb1cb3e427262c8c068d52319',
    );
  });

  test('matches libsodium for every length across block boundaries', () {
    final random = Random(7);
    for (var length = 0; length <= 400; length++) {
      final message = Uint8List.fromList([
        for (var i = 0; i < length; i++) random.nextInt(256),
      ]);
      expect(
        blake2b256(message),
        sodium.crypto.genericHash(message: message, outLen: 32),
        reason: 'length $length',
      );
    }
  });

  test('fast enough for a proof of work', () {
    final message = Uint8List(54);
    final watch = Stopwatch()..start();
    for (var i = 0; i < 100000; i++) {
      message[53] = i;
      blake2b256(message);
    }
    // A million hashes in well under a minute even on a slow runner.
    expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
  });
}

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
