import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:modusnote/theme/modus_colors.dart';

/// The native shells have no Flutter tests of their own, so these checks
/// read their sources: a refactor that drops the protection fails here.
void main() {
  group('Android', () {
    final activity = File(
      'android/app/src/main/kotlin/run/serv/modus/MainActivity.kt',
    ).readAsStringSync();

    test('the window is secure before Flutter draws anything', () {
      final secure = activity.indexOf('FLAG_SECURE');
      final superCreate = activity.indexOf('super.onCreate(');
      expect(secure, isNonNegative);
      expect(superCreate, isNonNegative);
      expect(secure, lessThan(superCreate));
    });

    test('adversary: nothing ever clears the flag', () {
      expect(activity, isNot(contains('clearFlags')));
    });
  });

  group('iOS', () {
    final delegate = File('ios/Runner/AppDelegate.swift').readAsStringSync();

    test('a cover goes up when the scene stops being active', () {
      expect(delegate, contains('UIScene.willDeactivateNotification'));
      expect(delegate, contains('UIScene.didActivateNotification'));
      expect(delegate, contains('privacyCover.start()'));
    });

    test('the cover is Deep Void, like the app behind it', () {
      final rgb = RegExp(
        r'red: 0x([0-9A-F]{2}).*green: 0x([0-9A-F]{2}).*blue: 0x([0-9A-F]{2})',
      ).firstMatch(delegate);
      expect(rgb, isNotNull);
      final hex = int.parse('${rgb![1]}${rgb[2]}${rgb[3]}', radix: 16);
      expect(0xFF000000 | hex, ModusColors.deepVoid.toARGB32());
    });

    test('adversary: the scene lifecycle is not overridden', () {
      // FlutterSceneDelegate forwards these to the engine; overriding
      // them without calling super would hide "paused" from AutoLock.
      final scene = File('ios/Runner/SceneDelegate.swift').readAsStringSync();
      expect(scene, isNot(contains('sceneWillResignActive')));
      expect(scene, isNot(contains('sceneDidBecomeActive')));
    });
  });
}
