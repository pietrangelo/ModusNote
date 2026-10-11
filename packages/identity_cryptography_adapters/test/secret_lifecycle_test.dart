import 'dart:async';
import 'dart:typed_data';

import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:identity_cryptography_adapters/identity_cryptography_adapters.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late EnvelopeEncryptor encryptor;
  final context = AssociatedData.empty;

  setUpAll(initSodium);
  setUp(() => encryptor = SodiumEnvelopeEncryptor(sodium));

  group('zeroization', () {
    test('a passphrase buffer is wiped as soon as it is taken in', () {
      final buffer = utf8Bytes('correct horse');
      final secret = SodiumPasswordSecret.fromUtf8Bytes(sodium, buffer);
      addTearDown(secret.dispose);

      expect(buffer, everyElement(0));
    });

    test('disposing a key disposes (zeroes and frees) its native memory', () {
      final native = _SpySecureKey(sodium.secureRandom(32));
      SodiumSymmetricKey.wrap(native).dispose();

      expect(native.disposeCount, 1);
    });

    test('disposing a passphrase disposes its native memory', () {
      final native = _SpySecureKey(sodium.secureRandom(8));
      SodiumPasswordSecret.wrap(native).dispose();

      expect(native.disposeCount, 1);
    });

    test('dispose is idempotent and never double-frees', () {
      final native = _SpySecureKey(sodium.secureRandom(32));
      final key = SodiumSymmetricKey.wrap(native)
        ..dispose()
        ..dispose();

      expect(key.isDisposed, isTrue);
      expect(native.disposeCount, 1);
    });
  });

  group('adversary', () {
    test('a disposed key cannot seal', () {
      final key = encryptor.generateKey()..dispose();

      expect(
        () => encryptor.seal(utf8Bytes('x'), key: key, associatedData: context),
        throwsA(isA<DisposedKeyException>()),
      );
    });

    test('a disposed key cannot open', () {
      final key = encryptor.generateKey();
      final envelope = encryptor.seal(
        utf8Bytes('x'),
        key: key,
        associatedData: context,
      );
      key.dispose();

      expect(
        () => encryptor.open(envelope, key: key, associatedData: context),
        throwsA(isA<DisposedKeyException>()),
      );
    });

    test('a disposed passphrase cannot be stretched', () async {
      final secret = password('correct horse')..dispose();

      await expectLater(
        SodiumKeyDerivationService(sodium).deriveKey(
          password: secret,
          salt: Salt.fromBytes(Uint8List(16)),
          parameters: KdfParameters.interactive,
        ),
        throwsA(isA<DisposedKeyException>()),
      );
    });

    test('secrets never print their bytes', () {
      final key = encryptor.generateKey();
      final secret = password('correct horse');
      addTearDown(key.dispose);
      addTearDown(secret.dispose);

      expect(key.toString(), 'SymmetricKey(redacted)');
      expect(secret.toString(), 'PasswordSecret(redacted)');
    });

    test('a key from a foreign adapter is refused, not trusted', () {
      expect(
        () => encryptor.seal(
          utf8Bytes('x'),
          key: _ForeignKey(),
          associatedData: context,
        ),
        throwsArgumentError,
      );
    });
  });
}

final class _ForeignKey implements SymmetricKey {
  @override
  bool get isDisposed => false;

  @override
  void dispose() {}
}

final class _SpySecureKey implements SecureKey {
  _SpySecureKey(this._inner);

  final SecureKey _inner;
  int disposeCount = 0;

  @override
  void dispose() {
    disposeCount++;
    _inner.dispose();
  }

  @override
  int get length => _inner.length;

  @override
  T runUnlockedSync<T>(SecureCallbackFn<T> callback, {bool writable = false}) =>
      _inner.runUnlockedSync(callback, writable: writable);

  @override
  FutureOr<T> runUnlockedAsync<T>(
    SecureCallbackFn<FutureOr<T>> callback, {
    bool writable = false,
  }) => _inner.runUnlockedAsync(callback, writable: writable);

  @override
  Uint8List extractBytes() => _inner.extractBytes();

  @override
  SecureKey copy() => _inner.copy();
}
