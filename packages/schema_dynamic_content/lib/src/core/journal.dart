import 'dynamic_entry.dart';
import 'field_value.dart';
import 'identifiers.dart';

/// The pages of a daily journal: notes of the `journal` type, each with
/// the day it is about. Told by the type's name, so a later version of the
/// journal is still a journal.
///
/// Pure dates, like [DateValue]: the app says which day is today.
abstract final class Journal {
  static const schema = 'journal';
  static final date = FieldKey('date');
  static final mood = FieldKey('mood');
  static final page = FieldKey('page');

  /// The moods a page may name, brightest first.
  static const moods = ['great', 'good', 'neutral', 'low', 'hard'];

  /// How many days ahead the reminder to write is planned: one
  /// notification a day, so the one for a day already written can go.
  static const reminderDays = 7;

  static bool isPage(DynamicEntry entry) => entry.schemaId.name == schema;

  /// The day [entry] is about; null for other types and for a page
  /// without one.
  static DateValue? dayOf(DynamicEntry entry) =>
      isPage(entry) && entry.attributes[date] is DateValue
      ? entry.attributes[date]! as DateValue
      : null;

  /// The mood [entry] names, if it is one of [moods].
  static String? moodOf(DynamicEntry entry) => switch (entry.attributes[mood]) {
    ChoiceValue(:final option) when isPage(entry) && moods.contains(option) =>
      option,
    _ => null,
  };

  /// Journal pages in [entries], the latest day first; pages of the same
  /// day most recently changed first.
  static List<DynamicEntry> byDay(Iterable<DynamicEntry> entries) {
    final pages = [
      for (final entry in entries)
        if (dayOf(entry) != null) entry,
    ];
    return pages..sort(_latestFirst);
  }

  /// The pages about [day], most recently changed first. Two devices
  /// offline may each have started one.
  static List<DynamicEntry> pagesOn(
    Iterable<DynamicEntry> entries,
    DateValue day,
  ) => [
    for (final entry in byDay(entries))
      if (dayOf(entry) == day) entry,
  ];

  /// The pages written on the same day as [day] in earlier years, the
  /// latest year first. In a year without 29 February, a page of 29
  /// February is looked for on the 28th.
  static List<DynamicEntry> onThisDay(
    Iterable<DynamicEntry> entries,
    DateValue day,
  ) => [
    for (final entry in byDay(entries))
      if (dayOf(entry) case final other?
          when other.year < day.year && _sameDayOfYear(other, day))
        entry,
  ];

  /// The days of the month [year]-[month] with a page, and the mood of
  /// the page most recently changed among those that name one.
  static Map<DateValue, String?> month(
    Iterable<DynamicEntry> entries,
    int year,
    int month,
  ) {
    final days = <DateValue, String?>{};
    // Latest changed last, so its mood stays.
    for (final entry in byDay(entries).reversed) {
      final day = dayOf(entry)!;
      if (day.year != year || day.month != month) continue;
      days[day] = moodOf(entry) ?? days[day];
    }
    return days;
  }

  /// The days, from [today] on, to remind the person to write: the next
  /// [reminderDays], without today once a page of today exists.
  static List<DateValue> reminders(
    Iterable<DynamicEntry> entries, {
    required DateValue today,
  }) {
    final written = pagesOn(entries, today).isNotEmpty;
    return [
      for (var i = written ? 1 : 0; i < reminderDays; i++) _plus(today, i),
    ];
  }

  /// Positive, below 2^31 and the same for the same day, so a platform
  /// can replace a reminder it already holds. Never one of a password's
  /// reminders (`ReminderSlot.id`), which leave this residue free.
  static int reminderId(DateValue day) => (_epochDay(day) + 30000) * 4;

  static bool _sameDayOfYear(DateValue earlier, DateValue day) {
    if (earlier.month == day.month && earlier.day == day.day) return true;
    // 29 February of [day], in a year that has none.
    return day.month == 2 &&
        day.day == 29 &&
        earlier.month == 2 &&
        earlier.day == 28 &&
        !_leap(earlier.year);
  }

  static bool _leap(int year) =>
      year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);

  static int _latestFirst(DynamicEntry a, DynamicEntry b) {
    final days = _epochDay(dayOf(b)!).compareTo(_epochDay(dayOf(a)!));
    if (days != 0) return days;
    final changed = b.audit.updatedAt.compareTo(a.audit.updatedAt);
    return changed != 0 ? changed : a.id.value.compareTo(b.id.value);
  }

  static DateValue _plus(DateValue day, int days) {
    final shifted = DateTime.utc(day.year, day.month, day.day + days);
    return DateValue(shifted.year, shifted.month, shifted.day);
  }
}

int _epochDay(DateValue day) =>
    DateTime.utc(day.year, day.month, day.day).millisecondsSinceEpoch ~/
    Duration.millisecondsPerDay;
