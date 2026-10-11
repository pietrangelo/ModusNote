import 'dart:typed_data';

import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:test/test.dart';

void main() {
  group('KeyContext', () {
    test('accepts exactly 8 printable ASCII characters', () {
      expect(KeyContext('mn-blob1').value, 'mn-blob1');
    });

    test('rejects any other length, since crypto_kdf binds 8 bytes', () {
      for (final value in ['', 'short', 'mn-blob12', 'mn-blob1 ']) {
        expect(
          () => KeyContext(value),
          throwsA(isA<InvalidKeyContextException>()),
          reason: '"$value"',
        );
      }
    });

    test('rejects non-ASCII, which would change the byte length', () {
      expect(
        () => KeyContext('mn-blòb'),
        throwsA(isA<InvalidKeyContextException>()),
      );
      expect(
        () => KeyContext('mn\u0000blob1'),
        throwsA(isA<InvalidKeyContextException>()),
      );
    });

    test('has value equality', () {
      expect(KeyContext('mn-blob1'), KeyContext('mn-blob1'));
      expect(KeyContext('mn-blob1'), isNot(KeyContext('mn-blob2')));
    });
  });

  group('SubkeyId', () {
    test('is 8 bytes (crypto_kdf uint64 subkey id)', () {
      final id = SubkeyId.fromBytes(Uint8List(8)..[7] = 1);

      expect(id.bytes, hasLength(8));
    });

    test('rejects any other length', () {
      for (final length in [0, 7, 9, 16]) {
        expect(
          () => SubkeyId.fromBytes(Uint8List(length)),
          throwsA(isA<InvalidLengthException>()),
          reason: '$length bytes',
        );
      }
    });

    test('is a defensive, read-only copy with value equality', () {
      final source = Uint8List(8);
      final id = SubkeyId.fromBytes(source);
      source[0] = 9;

      expect(id.bytes[0], 0);
      expect(() => id.bytes[0] = 1, throwsUnsupportedError);
      expect(id, SubkeyId.fromBytes(Uint8List(8)));
    });
  });
}
