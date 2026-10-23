import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:modusnote/vault/android_biometric_prf.dart';
import 'package:offline_sync/offline_sync.dart';

import 'support.dart';

/// `BiometricKeys.kt` in memory: one HMAC-like answer per alias, or the
/// error code the prompt would end with.
final class FakeKeystore {
  final keys = <String>{};
  final calls = <MethodCall>[];
  String? failWith;

  Future<Object?> handle(MethodCall call) async {
    calls.add(call);
    final arguments = (call.arguments as Map?)?.cast<String, Object?>();
    final alias = arguments?['alias'] as String?;
    switch (call.method) {
      case 'isSupported':
        return true;
      case 'create':
        keys.add(alias!);
        return null;
      case 'evaluate':
        if (failWith case final code?) {
          throw PlatformException(code: code, message: 'from the prompt');
        }
        if (!keys.contains(alias)) {
          throw PlatformException(code: 'missing');
        }
        final salt = arguments!['salt']! as Uint8List;
        final answer = Uint8List.fromList([
          for (var i = 0; i < 32; i++) (salt[i] ^ alias!.codeUnitAt(i)) & 0xff,
        ]);
        return answer;
      case 'forget':
        keys.remove(alias);
        return null;
    }
    throw MissingPluginException();
  }
}

void main() {
  setUpAll(loadSodium);
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeKeystore keystore;

  setUp(() {
    keystore = FakeKeystore();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          AndroidBiometricPrf.defaultChannel,
          keystore.handle,
        );
  });

  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AndroidBiometricPrf.defaultChannel, null),
  );

  AndroidBiometricPrf prf() => AndroidBiometricPrf(
    sodium,
    words: () => (title: 'Apri', subtitle: 'Conferma', cancel: 'Annulla'),
  );

  final salt = PrfSalt.fromBytes(List.generate(PrfSalt.length, (i) => i));

  test('registering makes a key and takes the first output from a use of '
      'it', () async {
    final registered = await prf().register(salt: salt);
    addTearDown(registered.key.dispose);

    expect(keystore.calls.map((c) => c.method), ['create', 'evaluate']);
    final alias = keystore.keys.single;
    expect(alias, startsWith(AndroidBiometricPrf.aliasPrefix));
    expect(alias, hasLength(AndroidBiometricPrf.aliasPrefix.length + 32));
    expect(
      (keystore.calls.last.arguments as Map)['title'],
      'Apri',
      reason: 'the prompt speaks the person\'s language',
    );
  });

  test('a dismissed prompt is a cancellation', () async {
    final registered = await prf().register(salt: salt);
    addTearDown(registered.key.dispose);
    keystore.failWith = 'cancelled';

    await expectLater(
      prf().evaluate(registered.credential, salt: salt),
      throwsA(isA<PasskeyCancelledException>()),
    );
  });

  test('a cancelled first prompt leaves no key behind', () async {
    keystore.failWith = 'cancelled';

    await expectLater(
      prf().register(salt: salt),
      throwsA(isA<PasskeyCancelledException>()),
    );
    expect(keystore.keys, isEmpty);
  });

  test('a key a new fingerprint invalidated opens nothing', () async {
    final registered = await prf().register(salt: salt);
    addTearDown(registered.key.dispose);
    keystore.failWith = 'invalidated';

    await expectLater(
      prf().evaluate(registered.credential, salt: salt),
      throwsA(isA<PasskeyRejectedException>()),
    );
  });

  test(
    'anything else is unsupported, and forgetting deletes the key',
    () async {
      final registered = await prf().register(salt: salt);
      addTearDown(registered.key.dispose);
      await prf().forget(registered.credential);
      expect(keystore.keys, isEmpty);

      keystore.failWith = 'unavailable';
      await expectLater(
        prf().evaluate(registered.credential, salt: salt),
        throwsA(isA<PasskeyUnsupportedException>()),
      );
    },
  );

  test('adversary: an answer of the wrong length is refused', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          AndroidBiometricPrf.defaultChannel,
          (call) async => call.method == 'evaluate' ? Uint8List(16) : null,
        );

    await expectLater(
      prf().register(salt: salt),
      throwsA(isA<PasskeyUnsupportedException>()),
    );
  });
}
