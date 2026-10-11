import 'dart:typed_data';

import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:identity_cryptography_adapters/identity_cryptography_adapters.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late IdentityService identities;
  late KeyEncapsulation kem;
  late EnvelopeEncryptor encryptor;
  late IdentityKeyPair bob;
  late SymmetricKey groupKey;
  final grant = AssociatedData.forContext('groupkey', 'ws1:0:bob');

  setUpAll(initSodium);
  setUp(() {
    identities = SodiumIdentityService(sodium);
    kem = SodiumKeyEncapsulation(sodium);
    encryptor = SodiumEnvelopeEncryptor(sodium);
    bob = identities.generateIdentity();
    groupKey = encryptor.generateKey();
  });
  tearDown(() {
    bob.dispose();
    groupKey.dispose();
  });

  SealedKey sealToBob([AssociatedData? associatedData]) => kem.seal(
    groupKey,
    recipient: bob.publicIdentity.encryptionKey,
    associatedData: associatedData ?? grant,
  );

  /// Two keys are the same key when one opens what the other sealed.
  void expectSameKey(SymmetricKey actual, SymmetricKey expected) {
    final envelope = encryptor.seal(
      utf8Bytes('nota'),
      key: expected,
      associatedData: AssociatedData.empty,
    );
    expect(
      encryptor.open(
        envelope,
        key: actual,
        associatedData: AssociatedData.empty,
      ),
      utf8Bytes('nota'),
    );
  }

  test('the recipient recovers the same key', () {
    final opened = kem.open(sealToBob(), recipient: bob, associatedData: grant);
    addTearDown(opened.dispose);

    expectSameKey(opened, groupKey);
  });

  test('the recovered key is independent of the sealed one', () {
    final opened = kem.open(sealToBob(), recipient: bob, associatedData: grant);
    groupKey.dispose();
    addTearDown(opened.dispose);

    expect(opened.isDisposed, isFalse);
    expect(opened.toString(), 'SymmetricKey(redacted)');
  });

  test('survives the wire format', () {
    final wire = sealToBob().toBytes();
    final opened = kem.open(
      SealedKey.parse(wire),
      recipient: bob,
      associatedData: grant,
    );
    addTearDown(opened.dispose);

    expectSameKey(opened, groupKey);
  });

  test('sealing the same key twice gives unrelated ciphertexts', () {
    expect(sealToBob().toBytes(), isNot(sealToBob().toBytes()));
  });

  group('adversary', () {
    test('another identity cannot open a key sealed to Bob', () {
      final mallory = identities.generateIdentity();
      addTearDown(mallory.dispose);

      expect(
        () => kem.open(sealToBob(), recipient: mallory, associatedData: grant),
        throwsA(isA<AuthenticationTagMismatchException>()),
      );
    });

    test(
      'a key granted for one epoch or member cannot be replayed as another',
      () {
        final sealed = sealToBob();
        for (final other in [
          AssociatedData.forContext('groupkey', 'ws1:1:bob'),
          AssociatedData.forContext('groupkey', 'ws2:0:bob'),
          AssociatedData.empty,
        ]) {
          expect(
            () => kem.open(sealed, recipient: bob, associatedData: other),
            throwsA(isA<AuthenticationTagMismatchException>()),
          );
        }
      },
    );

    test('flipping a bit anywhere in the sealed key fails fast', () {
      final wire = sealToBob().toBytes();
      // Every byte of the envelope, and a spread over the KEM ciphertext:
      // ML-KEM's implicit rejection turns a bad ciphertext into a random
      // shared secret, which the envelope's tag then refuses.
      final positions = {
        for (var i = 0; i < SealedKey.encapsulationLength; i += 37) i,
        for (var i = SealedKey.encapsulationLength; i < wire.length; i++) i,
      };
      for (final position in positions) {
        final tampered = Uint8List.fromList(wire);
        tampered[position] ^= 0x01;
        expect(
          () => kem.open(
            SealedKey.parse(tampered),
            recipient: bob,
            associatedData: grant,
          ),
          throwsA(
            anyOf(
              isA<AuthenticationTagMismatchException>(),
              isA<MalformedEnvelopeException>(),
            ),
          ),
          reason: 'byte $position',
        );
      }
    });

    test('a disposed identity cannot open anything', () {
      final sealed = sealToBob();
      bob.dispose();

      expect(
        () => kem.open(sealed, recipient: bob, associatedData: grant),
        throwsA(isA<DisposedKeyException>()),
      );
    });

    test('a disposed key cannot be sealed', () {
      groupKey.dispose();

      expect(sealToBob, throwsA(isA<DisposedKeyException>()));
    });
  });
}
