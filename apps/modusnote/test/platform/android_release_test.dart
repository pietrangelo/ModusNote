import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The build that goes to Google Play differs from the one `flutter run`
/// installs: these read the Android sources, so a refactor that breaks the
/// release fails here instead of on testers' phones.
void main() {
  final manifest = File('android/app/src/main/AndroidManifest.xml')
      .readAsStringSync();
  final gradle = File('android/app/build.gradle.kts').readAsStringSync();

  test('the release build may reach the network', () {
    // Flutter declares INTERNET only in the debug and profile manifests.
    expect(
      manifest,
      contains('<uses-permission android:name="android.permission.INTERNET"'),
    );
  });

  test('adversary: the vault is never in an Android backup', () {
    expect(manifest, contains('android:allowBackup="false"'));
    expect(
      manifest,
      contains('android:dataExtractionRules="@xml/data_extraction_rules"'),
    );
    final rules = File('android/app/src/main/res/xml/data_extraction_rules.xml')
        .readAsStringSync();
    for (final section in ['cloud-backup', 'device-transfer']) {
      final body = RegExp(
        '<$section>(.*?)</$section>',
        dotAll: true,
      ).firstMatch(rules)![1]!;
      for (final domain in ['root', 'file', 'database', 'sharedpref']) {
        expect(body, contains('<exclude domain="$domain" />'));
      }
      expect(body, isNot(contains('<include')));
    }
  });

  test('Google Play gets at least target API 36', () {
    expect(gradle, contains('targetSdk = maxOf(flutter.targetSdkVersion, 36)'));
  });

  test('the release is signed with the upload key when there is one', () {
    expect(gradle, contains('rootProject.file("key.properties")'));
    expect(
      gradle,
      contains(
        'signingConfigs.getByName(if (hasUploadKey) "upload" else "debug")',
      ),
    );
  });

  test('adversary: no key material is ever committed', () {
    final ignored = File('android/.gitignore').readAsStringSync();
    expect(ignored, contains('key.properties'));
    expect(ignored, contains('**/*.jks'));
    final tracked = Process.runSync('git', ['ls-files', 'android']);
    final files = (tracked.stdout as String).split('\n');
    expect(
      files.where(
        (f) =>
            f.endsWith('key.properties') ||
            f.endsWith('.jks') ||
            f.endsWith('.keystore'),
      ),
      isEmpty,
    );
  });
}
