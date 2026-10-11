import 'dart:typed_data';

import 'package:glados/glados.dart';
import 'package:identity_cryptography/identity_cryptography.dart';

Uint8List _bytes(int length, [int fill = 7]) =>
    Uint8List(length)..fillRange(0, length, fill);

void main() {
  group('Salt', () {
    test('accepts exactly 16 bytes', () {
      expect(Salt.fromBytes(_bytes(16)).bytes, _bytes(16));
    });

    test('rejects any other length', () {
      for (final length in [0, 15, 17, 32]) {
        expect(
          () => Salt.fromBytes(_bytes(length)),
          throwsA(isA<InvalidLengthException>()),
          reason: '$length bytes',
        );
      }
    });

    test('is a defensive copy: mutating the source changes nothing', () {
      final source = _bytes(16);
      final salt = Salt.fromBytes(source);
      source[0] = 99;

      expect(salt.bytes[0], 7);
    });

    test('exposes a read-only view', () {
      final salt = Salt.fromBytes(_bytes(16));

      expect(() => salt.bytes[0] = 1, throwsUnsupportedError);
    });

    test('has value equality', () {
      expect(Salt.fromBytes(_bytes(16)), Salt.fromBytes(_bytes(16)));
      expect(Salt.fromBytes(_bytes(16)), isNot(Salt.fromBytes(_bytes(16, 8))));
    });
  });

  group('Nonce', () {
    test('accepts exactly 24 bytes (XChaCha20)', () {
      expect(Nonce.fromBytes(_bytes(24)).bytes, hasLength(24));
    });

    test('rejects the 12-byte IETF ChaCha20 size', () {
      expect(
        () => Nonce.fromBytes(_bytes(12)),
        throwsA(isA<InvalidLengthException>()),
      );
    });
  });

  group('KdfParameters', () {
    test('interactive preset is libsodium INTERACTIVE: 2 passes, 64 MiB', () {
      expect(KdfParameters.interactive.opsLimit, 2);
      expect(KdfParameters.interactive.memLimitBytes, 64 * 1024 * 1024);
    });

    test('moderate preset is libsodium MODERATE: 3 passes, 256 MiB', () {
      expect(KdfParameters.moderate.opsLimit, 3);
      expect(KdfParameters.moderate.memLimitBytes, 256 * 1024 * 1024);
    });

    test('refuses parameters weaker than the interactive floor', () {
      expect(
        () => KdfParameters.custom(opsLimit: 1, memLimitBytes: 64 << 20),
        throwsA(isA<WeakKdfParametersException>()),
      );
      expect(
        () => KdfParameters.custom(opsLimit: 2, memLimitBytes: 32 << 20),
        throwsA(isA<WeakKdfParametersException>()),
      );
    });

    test('accepts stronger custom parameters', () {
      final params = KdfParameters.custom(opsLimit: 4, memLimitBytes: 1 << 30);
      expect(params.opsLimit, 4);
    });
  });

  group('AssociatedData', () {
    test('binds a context label to an identifier', () {
      final a = AssociatedData.forContext('entry', 'id-1');
      final b = AssociatedData.forContext('entry', 'id-2');
      final c = AssociatedData.forContext('schema', 'id-1');

      expect(a, isNot(b));
      expect(a, isNot(c));
      expect(a, AssociatedData.forContext('entry', 'id-1'));
    });

    test('is length-prefixed, so ("ab","c") never equals ("a","bc")', () {
      expect(
        AssociatedData.forContext('ab', 'c'),
        isNot(AssociatedData.forContext('a', 'bc')),
      );
    });
  });

  group('EncryptedEnvelope', () {
    final nonce = Nonce.fromBytes(_bytes(24, 1));
    final ciphertext = _bytes(16 + 5, 2);

    test('serializes as version | nonce | ciphertext', () {
      final envelope = EncryptedEnvelope(nonce: nonce, ciphertext: ciphertext);
      final bytes = envelope.toBytes();

      expect(bytes[0], EncryptedEnvelope.currentVersion);
      expect(bytes.sublist(1, 25), nonce.bytes);
      expect(bytes.sublist(25), ciphertext);
    });

    test('rejects a ciphertext shorter than the 16-byte tag', () {
      expect(
        () => EncryptedEnvelope(nonce: nonce, ciphertext: _bytes(15)),
        throwsA(isA<MalformedEnvelopeException>()),
      );
    });

    Glados(any.list(any.uint8))
        .test('parse(toBytes(e)) == e for any payload', (payload) {
          final envelope = EncryptedEnvelope(
            nonce: nonce,
            ciphertext: Uint8List.fromList([...ciphertext, ...payload]),
          );

          expect(EncryptedEnvelope.parse(envelope.toBytes()), envelope);
        });

    group('adversary', () {
      Glados(any.list(any.uint8)).test(
        'parse never throws anything but MalformedEnvelopeException',
        (garbage) {
          try {
            EncryptedEnvelope.parse(Uint8List.fromList(garbage));
          } on MalformedEnvelopeException {
            // The only acceptable failure.
          }
        },
      );

      test('an unknown version byte is rejected, not reinterpreted', () {
        final bytes = EncryptedEnvelope(
          nonce: nonce,
          ciphertext: ciphertext,
        ).toBytes()..[0] = 0xFF;

        expect(
          () => EncryptedEnvelope.parse(bytes),
          throwsA(isA<MalformedEnvelopeException>()),
        );
      });

      test(
        'parsing copies: mutating the wire buffer later changes nothing',
        () {
          final bytes = EncryptedEnvelope(
            nonce: nonce,
            ciphertext: ciphertext,
          ).toBytes();
          final envelope = EncryptedEnvelope.parse(bytes);
          bytes.fillRange(0, bytes.length, 0);

          expect(envelope.nonce, nonce);
          expect(envelope.ciphertext, ciphertext);
        },
      );
    });
  });

  group('CryptographyException', () {
    test('messages never carry payload bytes', () {
      const exceptions = <CryptographyException>[
        AuthenticationTagMismatchException(),
        DisposedKeyException(),
      ];
      for (final e in exceptions) {
        expect(e.toString(), isNot(matches(RegExp(r'\d{2,}'))));
      }
    });
  });
}
