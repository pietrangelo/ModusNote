import 'dart:typed_data';

import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:test/test.dart';

Uint8List _bytes(int length, [int fill = 7]) =>
    Uint8List(length)..fillRange(0, length, fill);

void main() {
  group('PrfSalt', () {
    test('accepts exactly 32 bytes', () {
      expect(PrfSalt.fromBytes(_bytes(32)).bytes, _bytes(32));
    });

    test('rejects any other length', () {
      for (final length in [0, 16, 31, 33, 64]) {
        expect(
          () => PrfSalt.fromBytes(_bytes(length)),
          throwsA(isA<InvalidLengthException>()),
          reason: '$length bytes',
        );
      }
    });

    test('is a defensive copy behind a read-only view', () {
      final source = _bytes(32);
      final salt = PrfSalt.fromBytes(source);
      source[0] = 99;

      expect(salt.bytes[0], 7);
      expect(() => salt.bytes[0] = 1, throwsUnsupportedError);
    });

    test('has value equality', () {
      expect(PrfSalt.fromBytes(_bytes(32)), PrfSalt.fromBytes(_bytes(32)));
      expect(
        PrfSalt.fromBytes(_bytes(32)),
        isNot(PrfSalt.fromBytes(_bytes(32, 8))),
      );
    });
  });

  group('PasskeyCredentialId', () {
    test('accepts the lengths WebAuthn allows, 16 to 1023 bytes', () {
      for (final length in [16, 64, 1023]) {
        expect(
          PasskeyCredentialId.fromBytes(_bytes(length)).bytes,
          hasLength(length),
        );
      }
    });

    test('rejects ids shorter or longer than WebAuthn allows', () {
      for (final length in [0, 15, 1024, 4096]) {
        expect(
          () => PasskeyCredentialId.fromBytes(_bytes(length)),
          throwsA(isA<InvalidPasskeyCredentialException>()),
          reason: '$length bytes',
        );
      }
    });

    test('is a defensive copy behind a read-only view', () {
      final source = _bytes(16);
      final id = PasskeyCredentialId.fromBytes(source);
      source[0] = 99;

      expect(id.bytes[0], 7);
      expect(() => id.bytes[0] = 1, throwsUnsupportedError);
    });

    test('has value equality', () {
      expect(
        PasskeyCredentialId.fromBytes(_bytes(20)),
        PasskeyCredentialId.fromBytes(_bytes(20)),
      );
      expect(
        PasskeyCredentialId.fromBytes(_bytes(20)),
        isNot(PasskeyCredentialId.fromBytes(_bytes(21))),
      );
    });
  });

  group('passkey failures', () {
    test('carry fixed messages', () {
      expect(
        const PasskeyCancelledException().toString(),
        'PasskeyCancelledException: passkey request cancelled or timed out',
      );
      expect(
        const PasskeyUnsupportedException().toString(),
        'PasskeyUnsupportedException: passkey cannot derive a key here',
      );
    });
  });
}
