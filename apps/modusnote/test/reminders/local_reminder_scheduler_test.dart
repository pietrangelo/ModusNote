import 'package:flutter_test/flutter_test.dart';
import 'package:modusnote/bootstrap/local_reminder_scheduler.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

void main() {
  group('reminder ids per vault', () {
    test('the first vault keeps the ids the app always used', () {
      expect(LocalReminderScheduler.systemId(0, 123456), 123456);
      expect(LocalReminderScheduler.owns(0, 123456), isTrue);
    });

    test('each vault owns only its own range', () {
      final id = LocalReminderScheduler.systemId(3, 123456);
      expect(LocalReminderScheduler.owns(3, id), isTrue);
      expect(LocalReminderScheduler.owns(0, id), isFalse);
      expect(LocalReminderScheduler.owns(4, id), isFalse);
      expect(
        LocalReminderScheduler.owns(3, LocalReminderScheduler.systemId(0, 1)),
        isFalse,
      );
    });

    test('ids stay within a 32-bit signed int for every vault', () {
      final largest = LocalReminderScheduler.systemId(19, (1 << 24) - 1);
      expect(largest, lessThan(1 << 31));
    });

    test('a reminder id that would spill into another range is refused', () {
      expect(
        () => LocalReminderScheduler.systemId(0, 1 << 24),
        throwsRangeError,
      );
      expect(() => LocalReminderScheduler.systemId(0, -1), throwsRangeError);
    });

    test('every slot until year 9999 fits the range', () {
      for (final kind in ExpiryReminderKind.values) {
        final slot = ReminderSlot(DateValue(9999, 12, 31), kind, 1);
        expect(LocalReminderScheduler.fits(slot.id), isTrue);
      }
      final beyond = ReminderSlot(
        DateValue(20000, 1, 1),
        ExpiryReminderKind.dayOf,
        1,
      );
      expect(LocalReminderScheduler.fits(beyond.id), isFalse);
    });
  });
}
