import 'package:flutter_test/flutter_test.dart';
import 'package:modusnote/vault/auto_lock.dart';

void main() {
  late DateTime now;
  late int locks;
  late AutoLock autoLock;

  void start() {
    now = DateTime.utc(2026, 10, 11, 9);
    locks = 0;
    autoLock = AutoLock(
      onLock: () => locks++,
      idle: const Duration(minutes: 5),
      background: const Duration(seconds: 30),
      clock: () => now,
    );
  }

  /// Timers must be gone before the test ends, which tear-downs are not.
  void lockTest(String name, Future<void> Function(WidgetTester) body) =>
      testWidgets(name, (tester) async {
        await body(tester);
        autoLock.dispose();
      });

  Future<void> wait(WidgetTester tester, Duration duration) async {
    now = now.add(duration);
    await tester.pump(duration);
  }

  lockTest('locks after five idle minutes, once', (tester) async {
    start();

    await wait(tester, const Duration(minutes: 4, seconds: 59));
    expect(locks, 0);
    await wait(tester, const Duration(seconds: 1));
    expect(locks, 1);
    await wait(tester, const Duration(minutes: 10));
    expect(locks, 1);
  });

  lockTest('every touch starts the idle countdown over', (tester) async {
    start();

    for (var i = 0; i < 5; i++) {
      await wait(tester, const Duration(minutes: 4));
      autoLock.touch();
    }

    expect(locks, 0);
  });

  lockTest('locks thirty seconds after the app goes out of sight', (
    tester,
  ) async {
    start();
    autoLock.hidden();

    await wait(tester, const Duration(seconds: 29));
    expect(locks, 0);
    await wait(tester, const Duration(seconds: 1));
    expect(locks, 1);
  });

  lockTest('coming back in time keeps the vault open', (tester) async {
    start();
    autoLock.hidden();
    await wait(tester, const Duration(seconds: 20));

    autoLock.shown();
    await wait(tester, const Duration(seconds: 20));

    expect(locks, 0);
  });

  lockTest('a hold keeps the vault open until it is released', (tester) async {
    start();
    final release = autoLock.hold();

    await wait(tester, const Duration(minutes: 20));
    expect(locks, 0);

    release();
    release(); // A second release changes nothing.
    await wait(tester, const Duration(minutes: 5));
    expect(locks, 1);
  });

  group('adversary', () {
    lockTest('a process frozen in the background locks on return', (
      tester,
    ) async {
      start();
      autoLock.hidden();
      // The OS froze the app: the clock moved, no timer ran.
      now = now.add(const Duration(hours: 2));

      autoLock.shown();

      expect(locks, 1);
    });

    lockTest('releasing a hold while away too long locks at once', (
      tester,
    ) async {
      start();
      final release = autoLock.hold();
      autoLock.hidden();
      await wait(tester, const Duration(minutes: 3));
      expect(locks, 0);

      release();
      await tester.pump(const Duration(milliseconds: 1));

      expect(locks, 1);
    });

    lockTest('nothing locks after dispose', (tester) async {
      start();
      autoLock
        ..hidden()
        ..dispose();

      await wait(tester, const Duration(hours: 1));
      autoLock.shown();

      expect(locks, 0);
    });
  });
}
