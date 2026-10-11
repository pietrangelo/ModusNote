import 'dart:typed_data';

import 'package:glados/glados.dart';
import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:identity_cryptography_adapters/identity_cryptography_adapters.dart';

import 'support.dart';

void main() {
  late IdentityService identities;
  late IdentityKeyPair alice;

  setUpAll(initSodium);
  setUp(() {
    identities = SodiumIdentityService(sodium);
    alice = identities.generateIdentity();
  });
  tearDown(() => alice.dispose());

  test('every identity has its own signing and encryption keys', () {
    final bob = identities.generateIdentity();
    addTearDown(bob.dispose);

    expect(bob.publicIdentity, isNot(alice.publicIdentity));
    expect(
      bob.publicIdentity.signingKey,
      isNot(alice.publicIdentity.signingKey),
    );
    expect(
      bob.publicIdentity.encryptionKey,
      isNot(alice.publicIdentity.encryptionKey),
    );
  });

  Glados(any.list(any.uint8))
      .test('verify(sign(m)) accepts any message', (message) {
        final bytes = Uint8List.fromList(message);
        final signature = identities.sign(bytes, signer: alice);

        identities.verify(
          bytes,
          signature: signature,
          signer: alice.publicIdentity.signingKey,
        );
      });

  test('the key pair never reveals itself through toString', () {
    expect(alice.toString(), 'IdentityKeyPair(redacted)');
  });

  test('dispose releases both private keys and is idempotent', () {
    final identity = identities.generateIdentity()
      ..dispose()
      ..dispose();

    expect(identity.isDisposed, isTrue);
    expect(
      () => identities.sign(utf8Bytes('x'), signer: identity),
      throwsA(isA<DisposedKeyException>()),
    );
  });

  group('storage under the MasterKey', () {
    late SymmetricKey masterKey;
    final slot = AssociatedData.forContext('identity', 'device-1');

    setUp(() => masterKey = SodiumEnvelopeEncryptor(sodium).generateKey());
    tearDown(() => masterKey.dispose());

    test('a stored identity comes back with the same keys', () {
      final sealed = identities.sealIdentity(
        alice,
        key: masterKey,
        associatedData: slot,
      );
      final restored = identities.openIdentity(
        EncryptedEnvelope.parse(sealed.toBytes()),
        key: masterKey,
        associatedData: slot,
      );
      addTearDown(restored.dispose);

      expect(restored.publicIdentity, alice.publicIdentity);
      final message = utf8Bytes('firmato dopo il riavvio');
      identities.verify(
        message,
        signature: identities.sign(message, signer: restored),
        signer: alice.publicIdentity.signingKey,
      );
      final kem = SodiumKeyEncapsulation(sodium);
      final groupKey = SodiumEnvelopeEncryptor(sodium).generateKey();
      addTearDown(groupKey.dispose);
      final opened = kem.open(
        kem.seal(
          groupKey,
          recipient: alice.publicIdentity.encryptionKey,
          associatedData: slot,
        ),
        recipient: restored,
        associatedData: slot,
      );
      opened.dispose();
    });

    test('the stored form is only seeds and tag: 64 + 16 bytes', () {
      final sealed = identities.sealIdentity(
        alice,
        key: masterKey,
        associatedData: slot,
      );

      expect(sealed.ciphertext, hasLength(64 + EncryptedEnvelope.tagLength));
    });

    test('a wrong MasterKey or slot does not open it', () {
      final sealed = identities.sealIdentity(
        alice,
        key: masterKey,
        associatedData: slot,
      );
      final other = SodiumEnvelopeEncryptor(sodium).generateKey();
      addTearDown(other.dispose);

      expect(
        () => identities.openIdentity(sealed, key: other, associatedData: slot),
        throwsA(isA<AuthenticationTagMismatchException>()),
      );
      expect(
        () => identities.openIdentity(
          sealed,
          key: masterKey,
          associatedData: AssociatedData.forContext('identity', 'device-2'),
        ),
        throwsA(isA<AuthenticationTagMismatchException>()),
      );
    });

    test('a disposed identity cannot be stored', () {
      final identity = identities.generateIdentity()..dispose();

      expect(
        () => identities.sealIdentity(
          identity,
          key: masterKey,
          associatedData: slot,
        ),
        throwsA(isA<DisposedKeyException>()),
      );
    });
  });

  group('adversary', () {
    test('flipping any single bit of the message breaks the signature', () {
      final message = utf8Bytes('MemberInvited bob editor');
      final signature = identities.sign(message, signer: alice);

      for (var bit = 0; bit < message.length * 8; bit++) {
        final tampered = Uint8List.fromList(message);
        tampered[bit ~/ 8] ^= 1 << (bit % 8);
        expect(
          () => identities.verify(
            tampered,
            signature: signature,
            signer: alice.publicIdentity.signingKey,
          ),
          throwsA(isA<InvalidSignatureException>()),
        );
      }
    });

    test('flipping any single bit of the signature is rejected', () {
      final message = utf8Bytes('KeyBundle epoch 3');
      final signature = identities.sign(message, signer: alice).bytes;

      for (var bit = 0; bit < signature.length * 8; bit++) {
        final tampered = Uint8List.fromList(signature);
        tampered[bit ~/ 8] ^= 1 << (bit % 8);
        expect(
          () => identities.verify(
            message,
            signature: Signature.fromBytes(tampered),
            signer: alice.publicIdentity.signingKey,
          ),
          throwsA(isA<InvalidSignatureException>()),
        );
      }
    });

    test("another identity's signature does not pass as Alice's", () {
      final mallory = identities.generateIdentity();
      addTearDown(mallory.dispose);
      final message = utf8Bytes('MemberInvited mallory owner');

      expect(
        () => identities.verify(
          message,
          signature: identities.sign(message, signer: mallory),
          signer: alice.publicIdentity.signingKey,
        ),
        throwsA(isA<InvalidSignatureException>()),
      );
    });

    test('an all-zero (small-order) key and signature are rejected', () {
      expect(
        () => identities.verify(
          utf8Bytes('x'),
          signature: Signature.fromBytes(Uint8List(Signature.length)),
          signer: PublicSigningKey.fromBytes(
            Uint8List(PublicSigningKey.length),
          ),
        ),
        throwsA(isA<InvalidSignatureException>()),
      );
    });
  });
}
