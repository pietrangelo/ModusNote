import 'dart:typed_data';

import 'package:glados/glados.dart';
import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:identity_cryptography_adapters/identity_cryptography_adapters.dart';

import 'support.dart';

void main() {
  late EnvelopeEncryptor encryptor;
  late SymmetricKey key;
  final entry = AssociatedData.forContext('entry', 'a1');

  setUpAll(initSodium);
  setUp(() {
    encryptor = SodiumEnvelopeEncryptor(sodium);
    key = encryptor.generateKey();
  });
  tearDown(() => key.dispose());

  Glados(any.list(any.uint8)).test('open(seal(m)) == m for any plaintext', (
    message,
  ) {
    final plaintext = Uint8List.fromList(message);
    final envelope = encryptor.seal(plaintext, key: key, associatedData: entry);

    expect(
      encryptor.open(envelope, key: key, associatedData: entry),
      plaintext,
    );
  });

  test('ciphertext is plaintext plus the 16-byte tag', () {
    final envelope = encryptor.seal(
      utf8Bytes('ciao'),
      key: key,
      associatedData: entry,
    );

    expect(envelope.ciphertext, hasLength(4 + EncryptedEnvelope.tagLength));
  });

  test('sealing the same plaintext twice never repeats a nonce', () {
    final nonces = {
      for (var i = 0; i < 1000; i++)
        encryptor.seal(utf8Bytes('x'), key: key, associatedData: entry).nonce,
    };

    expect(nonces, hasLength(1000));
  });

  test('survives the wire format', () {
    final wire = encryptor
        .seal(utf8Bytes('ciao'), key: key, associatedData: entry)
        .toBytes();

    expect(
      encryptor.open(
        EncryptedEnvelope.parse(wire),
        key: key,
        associatedData: entry,
      ),
      utf8Bytes('ciao'),
    );
  });

  group('adversary', () {
    final plaintext = utf8Bytes('canzone segreta');
    late EncryptedEnvelope envelope;

    setUp(
      () =>
          envelope = encryptor.seal(plaintext, key: key, associatedData: entry),
    );

    Matcher rejects() => throwsA(isA<AuthenticationTagMismatchException>());

    test('flipping any single bit of the ciphertext fails authentication', () {
      final ciphertext = envelope.ciphertext;
      for (var bit = 0; bit < ciphertext.length * 8; bit++) {
        final tampered = Uint8List.fromList(ciphertext);
        tampered[bit ~/ 8] ^= 1 << (bit % 8);

        expect(
          () => encryptor.open(
            EncryptedEnvelope(nonce: envelope.nonce, ciphertext: tampered),
            key: key,
            associatedData: entry,
          ),
          rejects(),
          reason: 'bit $bit',
        );
      }
    });

    test('flipping any single bit of the nonce fails authentication', () {
      for (var bit = 0; bit < Nonce.length * 8; bit++) {
        final tampered = Uint8List.fromList(envelope.nonce.bytes);
        tampered[bit ~/ 8] ^= 1 << (bit % 8);

        expect(
          () => encryptor.open(
            EncryptedEnvelope(
              nonce: Nonce.fromBytes(tampered),
              ciphertext: envelope.ciphertext,
            ),
            key: key,
            associatedData: entry,
          ),
          rejects(),
          reason: 'bit $bit',
        );
      }
    });

    test('a truncated ciphertext fails authentication', () {
      final truncated = envelope.ciphertext.sublist(
        0,
        envelope.ciphertext.length - 1,
      );

      expect(
        () => encryptor.open(
          EncryptedEnvelope(nonce: envelope.nonce, ciphertext: truncated),
          key: key,
          associatedData: entry,
        ),
        rejects(),
      );
    });

    test('an envelope replayed onto another entry fails authentication', () {
      expect(
        () => encryptor.open(
          envelope,
          key: key,
          associatedData: AssociatedData.forContext('entry', 'a2'),
        ),
        rejects(),
      );
    });

    test('dropping the associated data fails authentication', () {
      expect(
        () => encryptor.open(
          envelope,
          key: key,
          associatedData: AssociatedData.empty,
        ),
        rejects(),
      );
    });

    test('the wrong key fails authentication', () {
      final other = encryptor.generateKey();
      addTearDown(other.dispose);

      expect(
        () => encryptor.open(envelope, key: other, associatedData: entry),
        rejects(),
      );
    });

    Glados(any.list(any.uint8))
        .test('random bytes posing as a ciphertext never decrypt', (garbage) {
          final ciphertext = Uint8List.fromList([...Uint8List(16), ...garbage]);

          expect(
            () => encryptor.open(
              EncryptedEnvelope(nonce: envelope.nonce, ciphertext: ciphertext),
              key: key,
              associatedData: entry,
            ),
            rejects(),
          );
        });
  });
}
