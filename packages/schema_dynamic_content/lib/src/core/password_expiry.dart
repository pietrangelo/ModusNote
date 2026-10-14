import 'package:meta/meta.dart';

import 'dynamic_entry.dart';
import 'field_value.dart';
import 'identifiers.dart';

/// When the app reminds that a password expires.
enum ExpiryReminderKind { weekBefore, dayBefore, dayOf }

/// One reminder of one password: [kind], due on [day].
@immutable
final class ExpiryReminder {
  const ExpiryReminder(this.day, this.kind);

  final DateValue day;
  final ExpiryReminderKind kind;

  @override
  bool operator ==(Object other) =>
      other is ExpiryReminder && other.day == day && other.kind == kind;

  @override
  int get hashCode => Object.hash(day, kind);

  @override
  String toString() => 'ExpiryReminder(${_iso(day)}, ${kind.name})';
}

/// The reminders of one [day] and [kind], for [count] passwords: one
/// notification, whatever the number, so a day with ten expiries does not
/// ring ten times.
@immutable
final class ReminderSlot {
  const ReminderSlot(this.day, this.kind, this.count);

  final DateValue day;
  final ExpiryReminderKind kind;
  final int count;

  /// Positive, below 2^31 and the same for the same day and kind, so a
  /// platform can replace a slot it already holds. It names no note.
  int get id => (_epochDay(day) + _epochOffset) * 4 + kind.index + 1;

  // Keeps every day from 1900 on positive.
  static const _epochOffset = 30000;

  @override
  bool operator ==(Object other) =>
      other is ReminderSlot &&
      other.day == day &&
      other.kind == kind &&
      other.count == count;

  @override
  int get hashCode => Object.hash(day, kind, count);

  @override
  String toString() => 'ReminderSlot(${_iso(day)}, ${kind.name}, $count)';
}

/// When the password of a credential note expires and when to say so: a
/// week before, the day before and on the day.
///
/// Pure dates, like [DateValue]: the app picks the hour and the zone.
abstract final class PasswordExpiry {
  static const schema = 'credential';
  static final field = FieldKey('password_expiry');

  /// Days of warning the reminders give; [isSoon] uses the longest.
  static const _before = {
    ExpiryReminderKind.weekBefore: 7,
    ExpiryReminderKind.dayBefore: 1,
    ExpiryReminderKind.dayOf: 0,
  };

  /// The most slots [plan] returns: iOS keeps 64 pending notifications per
  /// app, and later ones come back at the next plan.
  static const maxSlots = 60;

  /// The expiry of [entry]'s password; null for other types and for a
  /// credential without one.
  static DateValue? of(DynamicEntry entry) =>
      entry.schemaId.name == schema && entry.attributes[field] is DateValue
      ? entry.attributes[field]! as DateValue
      : null;

  static int daysLeft(DateValue expiry, {required DateValue today}) =>
      _epochDay(expiry) - _epochDay(today);

  /// Expired, or expiring within a week.
  static bool isSoon(DateValue expiry, {required DateValue today}) =>
      daysLeft(expiry, today: today) <= _before[ExpiryReminderKind.weekBefore]!;

  /// The reminders of [expiry] still to come, today included.
  static List<ExpiryReminder> remindersFor(
    DateValue expiry, {
    required DateValue today,
  }) => [
    for (final MapEntry(key: kind, value: days) in _before.entries)
      if (daysLeft(expiry, today: today) >= days)
        ExpiryReminder(_minus(expiry, days), kind),
  ];

  /// The reminders of every credential in [entries], one slot per day and
  /// kind, earliest first, at most [maxSlots].
  static List<ReminderSlot> plan(
    Iterable<DynamicEntry> entries, {
    required DateValue today,
  }) {
    final counts = <ExpiryReminder, int>{};
    for (final entry in entries) {
      final expiry = of(entry);
      if (expiry == null) continue;
      for (final reminder in remindersFor(expiry, today: today)) {
        counts[reminder] = (counts[reminder] ?? 0) + 1;
      }
    }
    final slots = [
      for (final MapEntry(key: reminder, value: count) in counts.entries)
        ReminderSlot(reminder.day, reminder.kind, count),
    ]..sort((a, b) => a.id.compareTo(b.id));
    return slots.length > maxSlots ? slots.sublist(0, maxSlots) : slots;
  }

  static DateValue _minus(DateValue day, int days) {
    final shifted = DateTime.utc(day.year, day.month, day.day - days);
    return DateValue(shifted.year, shifted.month, shifted.day);
  }
}

int _epochDay(DateValue day) =>
    DateTime.utc(day.year, day.month, day.day).millisecondsSinceEpoch ~/
    Duration.millisecondsPerDay;

String _iso(DateValue day) => '${day.year}-${day.month}-${day.day}';
