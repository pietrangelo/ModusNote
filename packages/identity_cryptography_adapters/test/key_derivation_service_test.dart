import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:identity_cryptography_adapters/identity_cryptography_adapters.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late KeyDerivationService kdf;
  late EnvelopeEncryptor encryptor;
  final context = AssociatedData.forContext('vault', 'v1');

  setUpAll(initSodium);
  setUp(() {
    kdf = SodiumKeyDerivationService(sodium);
    encryptor = SodiumEnvelopeEncryptor(sodium);
  });

  // Keys are opaque, so equality is observed the only way the domain can:
  // whether one key opens what the other sealed.
  Future<bool> sameKey(SymmetricKey a, SymmetricKey b) async {
    final envelope = encryptor.seal(
      utf8Bytes('probe'),
      key: a,
      associatedData: context,
    );
    try {
      encryptor.open(envelope, key: b, associatedData: context);
      return true;
    } on AuthenticationTagMismatchException {
      return false;
    } finally {
      a.dispose();
      b.dispose();
    }
  }

  Future<SymmetricKey> derive(String text, Salt salt) async {
    final secret = password(text);
    try {
      return await kdf.deriveKey(
        password: secret,
        salt: salt,
        parameters: KdfParameters.interactive,
      );
    } finally {
      secret.dispose();
    }
  }

  test('the same passphrase and salt always derive the same key', () async {
    final salt = kdf.newSalt();

    expect(
      await sameKey(
        await derive('correct horse', salt),
        await derive('correct horse', salt),
      ),
      isTrue,
    );
  });

  test('a different salt derives a different key', () async {
    expect(
      await sameKey(
        await derive('correct horse', kdf.newSalt()),
        await derive('correct horse', kdf.newSalt()),
      ),
      isFalse,
    );
  });

  test('a different passphrase derives a different key', () async {
    final salt = kdf.newSalt();

    expect(
      await sameKey(
        await derive('correct horse', salt),
        await derive('correct horsf', salt),
      ),
      isFalse,
    );
  });

  test('salts are unique', () {
    final salts = {for (var i = 0; i < 1000; i++) kdf.newSalt()};

    expect(salts, hasLength(1000));
  });

  test('non-ASCII passphrases are supported', () async {
    final salt = kdf.newSalt();

    expect(
      await sameKey(
        await derive('perché città', salt),
        await derive('perché città', salt),
      ),
      isTrue,
    );
  });
}
