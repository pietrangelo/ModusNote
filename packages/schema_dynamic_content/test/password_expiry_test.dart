import 'package:schema_dynamic_content/schema_dynamic_content.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

DynamicEntry credential(String id, {DateValue? expiry}) =>
    switch (DynamicEntry.create(
      schema: SeedSchemas.credentialV1,
      id: EntryId(id.padLeft(32, '0')),
      attributes: {
        key('description'): const TextValue('Posta'),
        key('password_expiry'): ?expiry,
      },
      at: at,
    )) {
      Valid(:final value) => value,
      Invalid(:final violations) => throw StateError('$violations'),
    };

DynamicEntry quickNote() => switch (DynamicEntry.create(
  schema: SeedSchemas.quickNoteV1,
  id: EntryId('f' * 32),
  attributes: {key('content'): const TextValue('2026-12-01')},
  at: at,
)) {
  Valid(:final value) => value,
  Invalid() => throw StateError('fixture'),
};

DateValue day(DateTime d) => DateValue(d.year, d.month, d.day);

void main() {
  final today = DateValue(2026, 10, 14);

  group('reminders of one expiry', () {
    test('a week before, the day before and the day itself', () {
      expect(
        PasswordExpiry.remindersFor(DateValue(2026, 11, 2), today: today),
        [
          ExpiryReminder(
            DateValue(2026, 10, 26),
            ExpiryReminderKind.weekBefore,
          ),
          ExpiryReminder(DateValue(2026, 11, 1), ExpiryReminderKind.dayBefore),
          ExpiryReminder(DateValue(2026, 11, 2), ExpiryReminderKind.dayOf),
        ],
      );
    });

    test('across months and leap days', () {
      expect(
        PasswordExpiry.remindersFor(
          DateValue(2028, 3, 1),
          today: today,
        ).map((r) => r.day),
        [DateValue(2028, 2, 23), DateValue(2028, 2, 29), DateValue(2028, 3, 1)],
      );
    });

    test('drops the days already gone, keeps today', () {
      expect(
        PasswordExpiry.remindersFor(DateValue(2026, 10, 15), today: today),
        [
          ExpiryReminder(DateValue(2026, 10, 14), ExpiryReminderKind.dayBefore),
          ExpiryReminder(DateValue(2026, 10, 15), ExpiryReminderKind.dayOf),
        ],
      );
      expect(
        PasswordExpiry.remindersFor(DateValue(2026, 10, 13), today: today),
        isEmpty,
      );
    });
  });

  group('expiry of a note', () {
    test('only a credential has one', () {
      expect(
        PasswordExpiry.of(credential('1', expiry: DateValue(2026, 12, 1))),
        DateValue(2026, 12, 1),
      );
      expect(PasswordExpiry.of(credential('2')), isNull);
      expect(PasswordExpiry.of(quickNote()), isNull);
    });

    test('days left, negative once expired', () {
      expect(PasswordExpiry.daysLeft(DateValue(2026, 10, 21), today: today), 7);
      expect(PasswordExpiry.daysLeft(today, today: today), 0);
      expect(
        PasswordExpiry.daysLeft(DateValue(2026, 10, 10), today: today),
        -4,
      );
    });

    test('soon: within a week, or already expired', () {
      expect(
        PasswordExpiry.isSoon(DateValue(2026, 10, 21), today: today),
        isTrue,
      );
      expect(
        PasswordExpiry.isSoon(DateValue(2026, 10, 22), today: today),
        isFalse,
      );
      expect(
        PasswordExpiry.isSoon(DateValue(2026, 1, 1), today: today),
        isTrue,
      );
    });
  });

  group('plan of many notes', () {
    test('one slot per day and kind, with how many passwords it is about', () {
      final plan = PasswordExpiry.plan([
        credential('1', expiry: DateValue(2026, 11, 2)),
        credential('2', expiry: DateValue(2026, 11, 2)),
        credential('3', expiry: DateValue(2026, 10, 27)),
        credential('4'),
        quickNote(),
      ], today: today);
      expect(plan, [
        ReminderSlot(DateValue(2026, 10, 20), ExpiryReminderKind.weekBefore, 1),
        ReminderSlot(DateValue(2026, 10, 26), ExpiryReminderKind.weekBefore, 2),
        ReminderSlot(DateValue(2026, 10, 26), ExpiryReminderKind.dayBefore, 1),
        ReminderSlot(DateValue(2026, 10, 27), ExpiryReminderKind.dayOf, 1),
        ReminderSlot(DateValue(2026, 11, 1), ExpiryReminderKind.dayBefore, 2),
        ReminderSlot(DateValue(2026, 11, 2), ExpiryReminderKind.dayOf, 2),
      ]);
    });

    test('keeps only the earliest slots, within what a platform holds', () {
      final plan = PasswordExpiry.plan([
        for (var i = 0; i < 100; i++)
          credential('$i', expiry: day(DateTime.utc(2027, 1, 1 + i))),
      ], today: today);
      expect(plan, hasLength(PasswordExpiry.maxSlots));
      expect(plan.first.day, DateValue(2026, 12, 25));
    });

    test('every slot has a stable id, distinct per day and kind', () {
      final a = ReminderSlot(
        DateValue(2026, 10, 26),
        ExpiryReminderKind.weekBefore,
        1,
      );
      final b = ReminderSlot(
        DateValue(2026, 10, 26),
        ExpiryReminderKind.dayBefore,
        1,
      );
      final c = ReminderSlot(
        DateValue(2026, 10, 27),
        ExpiryReminderKind.weekBefore,
        3,
      );
      expect({a.id, b.id, c.id}, hasLength(3));
      expect(
        ReminderSlot(
          DateValue(2026, 10, 26),
          ExpiryReminderKind.weekBefore,
          5,
        ).id,
        a.id,
      );
      expect(
        ReminderSlot(DateValue(2200, 12, 31), ExpiryReminderKind.dayOf, 1).id,
        lessThan(1 << 31),
      );
      expect(
        ReminderSlot(
          DateValue(1900, 1, 1),
          ExpiryReminderKind.weekBefore,
          1,
        ).id,
        greaterThan(0),
      );
    });
  });
}
