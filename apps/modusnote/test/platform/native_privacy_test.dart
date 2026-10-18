import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Native settings no Dart test can exercise: these read the sources, so a
/// refactor that drops one fails here.
void main() {
  final appDelegate = File('ios/Runner/AppDelegate.swift').readAsStringSync();
  final mainActivity = File(
    'android/app/src/main/kotlin/run/serv/modus/MainActivity.kt',
  ).readAsStringSync();

  test('adversary: the vault is never in an iCloud or computer backup', () {
    expect(appDelegate, contains('excludeVaultsFromBackup()'));
    expect(appDelegate, contains('.applicationSupportDirectory'));
    expect(appDelegate, contains('isExcludedFromBackup = true'));
  });

  test('adversary: a copied password is sensitive and stays here', () {
    expect(mainActivity, contains('"run.serv.modus/clipboard"'));
    expect(mainActivity, contains('android.content.extra.IS_SENSITIVE'));
    expect(appDelegate, contains('"run.serv.modus/clipboard"'));
    expect(appDelegate, contains('.localOnly: true'));
    expect(appDelegate, contains('.expirationDate'));
  });
}
