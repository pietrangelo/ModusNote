import 'dart:typed_data';

import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:test/test.dart';

Uint8List filled(int length, [int value = 7]) =>
    Uint8List(length)..fillRange(0, length, value);

void main() {
  group('PublicSigningKey', () {
    test('is 32 bytes (Ed25519)', () {
      expect(PublicSigningKey.fromBytes(filled(32)).bytes, hasLength(32));
      expect(
        () => PublicSigningKey.fromBytes(filled(31)),
        throwsA(isA<InvalidLengthException>()),
      );
    });

    test('copies its input and exposes an unmodifiable view', () {
      final source = filled(32);
      final key = PublicSigningKey.fromBytes(source);
      source[0] = 0;

      expect(key.bytes[0], 7);
      expect(() => key.bytes[0] = 1, throwsUnsupportedError);
    });

    test('has value equality and a stable hex form for ids', () {
      expect(
        PublicSigningKey.fromBytes(filled(32)),
        PublicSigningKey.fromBytes(filled(32)),
      );
      expect(PublicSigningKey.fromBytes(filled(32, 0xab)).hex, 'ab' * 32);
    });
  });

  group('PublicEncryptionKey', () {
    test('is an X-Wing public key (1216 bytes)', () {
      expect(PublicEncryptionKey.length, 1216);
      expect(
        () => PublicEncryptionKey.fromBytes(filled(32)),
        throwsA(isA<InvalidLengthException>()),
      );
    });
  });

  group('Signature', () {
    test('is 64 bytes (Ed25519)', () {
      expect(Signature.fromBytes(filled(64)).bytes, hasLength(64));
      expect(
        () => Signature.fromBytes(filled(65)),
        throwsA(isA<InvalidLengthException>()),
      );
    });
  });

  group('PublicIdentity', () {
    final identity = PublicIdentity(
      signingKey: PublicSigningKey.fromBytes(filled(32, 1)),
      encryptionKey: PublicEncryptionKey.fromBytes(
        filled(PublicEncryptionKey.length, 2),
      ),
    );

    test('round-trips through its fixed-length wire form', () {
      final wire = identity.toBytes();

      expect(wire, hasLength(PublicIdentity.length));
      expect(PublicIdentity.parse(wire), identity);
    });

    test('rejects a wire form of the wrong length', () {
      expect(
        () => PublicIdentity.parse(filled(PublicIdentity.length - 1)),
        throwsA(isA<InvalidLengthException>()),
      );
    });
  });

  group('SealedKey', () {
    SealedKey sample() => SealedKey(
      encapsulation: filled(SealedKey.encapsulationLength, 3),
      envelope: EncryptedEnvelope(
        nonce: Nonce.fromBytes(filled(Nonce.length, 4)),
        ciphertext: filled(32 + EncryptedEnvelope.tagLength, 5),
      ),
    );

    test('round-trips through its fixed-length wire form', () {
      final wire = sample().toBytes();

      expect(wire, hasLength(SealedKey.length));
      expect(SealedKey.parse(wire), sample());
    });

    test('carries exactly one 32-byte key, so any other length is refused', () {
      for (final length in [0, SealedKey.length - 1, SealedKey.length + 1]) {
        expect(
          () => SealedKey.parse(filled(length)),
          throwsA(isA<MalformedEnvelopeException>()),
          reason: '$length bytes',
        );
      }
      expect(
        () => SealedKey(
          encapsulation: filled(SealedKey.encapsulationLength),
          envelope: EncryptedEnvelope(
            nonce: Nonce.fromBytes(filled(Nonce.length)),
            ciphertext: filled(33 + EncryptedEnvelope.tagLength),
          ),
        ),
        throwsA(isA<MalformedEnvelopeException>()),
      );
    });
  });
}
