import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:modusnote/vault/android_biometric_prf.dart';

/// The Keystore side of fingerprint unlock has no Flutter test of its own:
/// these checks read its source, so a refactor that weakens the key fails
/// here.
void main() {
  final keys = File(
    'android/app/src/main/kotlin/run/serv/modus/BiometricKeys.kt',
  ).readAsStringSync();
  final activity = File(
    'android/app/src/main/kotlin/run/serv/modus/MainActivity.kt',
  ).readAsStringSync();
  final manifest = File('android/app/src/main/AndroidManifest.xml')
      .readAsStringSync();

  test('every use of the key asks for a strong biometric', () {
    expect(keys, contains('setUserAuthenticationRequired(true)'));
    expect(
      keys,
      contains(
        'setUserAuthenticationParameters(0, KeyProperties.AUTH_BIOMETRIC_STRONG)',
      ),
    );
    expect(
      keys,
      contains(
        'setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_STRONG)',
      ),
    );
    expect(keys, contains('BiometricPrompt.CryptoObject(mac)'));
  });

  test('adversary: the screen PIN alone never opens the vault', () {
    expect(keys, isNot(contains('DEVICE_CREDENTIAL')));
    expect(keys, isNot(contains('AUTH_DEVICE_CREDENTIAL')));
    expect(keys, isNot(contains('BIOMETRIC_WEAK')));
  });

  test('adversary: a fingerprint added to the phone invalidates the key', () {
    expect(keys, contains('setInvalidatedByBiometricEnrollment(true)'));
  });

  test('only the vault\'s own keys are used or deleted', () {
    expect(keys, contains('PREFIX = "${AndroidBiometricPrf.aliasPrefix}"'));
  });

  test('the activity answers on the channel the app calls', () {
    expect(keys, contains('"${AndroidBiometricPrf.defaultChannel.name}"'));
    expect(activity, contains('BiometricKeys.CHANNEL'));
    expect(manifest, contains('android.permission.USE_BIOMETRIC'));
  });
}
