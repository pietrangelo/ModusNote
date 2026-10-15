import 'package:schema_dynamic_content/schema_dynamic_content.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

var _ids = 0;

DynamicEntry page(
  DateValue? day, {
  String? mood,
  DateTime? changed,
  SchemaDefinition? schema,
}) {
  final id = (_ids++).toRadixString(16).padLeft(32, '0');
  final result = DynamicEntry.create(
    schema: schema ?? SeedSchemas.journalV1,
    id: EntryId(id),
    attributes: {
      key('date'): ?day,
      if (mood != null) key('mood'): ChoiceValue(mood),
      if (day == null) key('content'): const TextValue('x'),
    },
    at: changed ?? at,
  );
  return switch (result) {
    Valid(:final value) => value,
    Invalid(:final violations) => throw StateError('$violations'),
  };
}

void main() {
  group('the journal type', () {
    final schema = SeedSchemas.journalV1;

    test('has a day, an optional title, a page and a mood', () {
      expect(schema.fields.map((f) => f.key.value), [
        'title',
        'date',
        'page',
        'mood',
        'recording',
        'attachments',
        'tags',
      ]);
      expect(schema.fieldFor(key('date'))!.required, isTrue);
      expect(schema.fieldFor(key('title'))!.required, isFalse);
      expect(schema.fieldFor(key('page'))!.type, isA<MarkdownFieldType>());
      expect(
        (schema.fieldFor(key('mood'))!.type as ChoiceFieldType).options,
        Journal.moods,
      );
      expect((schema.icon, schema.tint), (NoteIcon.calendar, NoteTint.rose));
    });

    test('a page needs only its day', () {
      expect(Journal.dayOf(page(DateValue(2026, 10, 15))), isNotNull);
      final empty = DynamicEntry.create(
        schema: schema,
        id: EntryId('f' * 32),
        attributes: const {},
        at: at,
      );
      expect(empty, isA<Invalid<DynamicEntry>>());
    });
  });

  test('only a journal page has a day and a mood', () {
    final other = page(null, schema: SeedSchemas.quickNoteV1);
    expect(Journal.isPage(other), isFalse);
    expect(Journal.dayOf(other), isNull);
    expect(Journal.moodOf(other), isNull);
    expect(Journal.moodOf(page(DateValue(2026, 1, 1), mood: 'good')), 'good');
  });

  test('pages go by day, the latest first, not by last change', () {
    final old = page(DateValue(2025, 3, 1), changed: later);
    final recent = page(DateValue(2026, 10, 14));
    final newest = page(DateValue(2026, 10, 15));
    final note = page(null, schema: SeedSchemas.quickNoteV1);
    expect(Journal.byDay([old, note, newest, recent]), [newest, recent, old]);
  });

  test('two pages of one day: the one changed last first', () {
    final day = DateValue(2026, 10, 15);
    final a = page(day);
    final b = page(day, changed: later);
    expect(Journal.pagesOn([a, b, page(DateValue(2026, 10, 14))], day), [b, a]);
  });

  group('on this day', () {
    test('finds the same day in earlier years, the latest first', () {
      final today = DateValue(2026, 10, 15);
      final lastYear = page(DateValue(2025, 10, 15));
      final longAgo = page(DateValue(2019, 10, 15));
      final pages = [
        longAgo,
        lastYear,
        page(today),
        page(DateValue(2025, 10, 16)),
        page(DateValue(2027, 10, 15)),
      ];
      expect(Journal.onThisDay(pages, today), [lastYear, longAgo]);
    });

    test('29 February looks for the 28th in years without one', () {
      final leap = page(DateValue(2024, 2, 29));
      final plain = page(DateValue(2027, 2, 28));
      final pages = [leap, plain, page(DateValue(2024, 2, 28))];
      expect(Journal.onThisDay(pages, DateValue(2028, 2, 29)), [plain, leap]);
      expect(Journal.onThisDay(pages, DateValue(2028, 2, 28)), [
        plain,
        pages[2],
      ]);
    });
  });

  test('a month: the days written and the mood of each', () {
    final day = DateValue(2026, 10, 3);
    final days = Journal.month(
      [
        page(day, mood: 'low'),
        page(day, mood: 'great', changed: later),
        page(DateValue(2026, 10, 9)),
        page(DateValue(2026, 9, 30), mood: 'good'),
        page(DateValue(2025, 10, 3), mood: 'hard'),
      ],
      2026,
      10,
    );
    expect(days, {day: 'great', DateValue(2026, 10, 9): null});
  });

  group('reminders', () {
    final today = DateValue(2026, 12, 29);

    test('one a day for the week ahead, today first', () {
      final days = Journal.reminders(const [], today: today);
      expect(days, hasLength(Journal.reminderDays));
      expect(days.first, today);
      expect(days.last, DateValue(2027, 1, 4));
    });

    test('a day already written has none', () {
      final days = Journal.reminders([
        page(DateValue(2026, 12, 31)),
        page(DateValue(2027, 2, 1)),
      ], today: today);
      expect(days, isNot(contains(DateValue(2026, 12, 31))));
      expect(days, hasLength(Journal.reminderDays - 1));
    });

    test('today goes once today is written', () {
      final days = Journal.reminders([page(today)], today: today);
      expect(days.first, DateValue(2026, 12, 30));
      expect(days, hasLength(Journal.reminderDays - 1));
    });

    test('ids are the same for the same day and never a password\'s', () {
      expect(
        Journal.reminderId(today),
        Journal.reminderId(DateValue(2026, 12, 29)),
      );
      final passwords = {
        for (final kind in ExpiryReminderKind.values)
          for (var d = 1; d < 40; d++)
            ReminderSlot(DateValue(2026, 12, d % 28 + 1), kind, 1).id,
      };
      final journal = {
        for (var d = 1; d < 29; d++) Journal.reminderId(DateValue(2026, 12, d)),
      };
      expect(journal.intersection(passwords), isEmpty);
      expect(journal.every((id) => id > 0 && id < 1 << 31), isTrue);
    });
  });
}
