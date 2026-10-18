import 'dart:typed_data';

import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:identity_cryptography_adapters/identity_cryptography_adapters.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  setUpAll(initSodium);

  Future<String> digest(List<Uint8List> pieces) async {
    final sink = SodiumContentHasher(sodium).start();
    pieces.forEach(sink.add);
    final bytes = (await sink.close()).bytes;
    return [for (final b in bytes) b.toRadixString(16).padLeft(2, '0')].join();
  }

  test('is BLAKE2b-256', () async {
    // RFC 7693 test vector for "abc", 32-byte output.
    expect(
      await digest([utf8Bytes('abc')]),
      'bddd813c634239723171ef3fee98579b94964e3bb1cb3e427262c8c068d52319',
    );
  });

  test('how the bytes are split does not matter', () async {
    expect(
      await digest([utf8Bytes('a'), utf8Bytes(''), utf8Bytes('bc')]),
      await digest([utf8Bytes('abc')]),
    );
    expect(
      await digest([utf8Bytes('abd')]),
      isNot(await digest([utf8Bytes('abc')])),
    );
  });

  test('a digest has exactly 32 bytes', () {
    expect(() => ContentDigest.fromBytes(Uint8List(31)), throwsA(anything));
  });
}
