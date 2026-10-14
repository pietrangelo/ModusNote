import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import '../l10n/generated/app_localizations.dart';
import '../notes/note_store.dart';

/// One notification the platform shows at [at], device time.
@immutable
final class ScheduledReminder {
  const ScheduledReminder({
    required this.id,
    required this.at,
    required this.title,
    required this.body,
  });

  /// [ReminderSlot.id]: the same for the same day and kind.
  final int id;
  final DateTime at;
  final String title;
  final String body;

  @override
  bool operator ==(Object other) =>
      other is ScheduledReminder &&
      other.id == id &&
      other.at == at &&
      other.title == title &&
      other.body == body;

  @override
  int get hashCode => Object.hash(id, at, title, body);
}

/// Where reminders are shown: the system's notifications on a phone.
///
/// What it is given replaces everything it held: reminders not in the
/// list are withdrawn, so a password changed, a credential deleted or a
/// date moved never rings for nothing.
abstract interface class ReminderScheduler {
  /// Asks the person, once, whether the app may show notifications;
  /// false if it may not.
  Future<bool> ask();

  Future<void> replaceAll(List<ScheduledReminder> reminders);
}

/// The words of the reminders, in the person's language. Generic on
/// purpose: a notification is seen on a locked screen and kept by the
/// system outside the vault, so it says how many passwords, never which.
final class ReminderTexts {
  ReminderTexts(this._l10n);

  final AppLocalizations _l10n;

  String get title => _l10n.reminderTitle;

  String body(ReminderSlot slot) => switch (slot.kind) {
    ExpiryReminderKind.weekBefore => _l10n.reminderWeekBefore(slot.count),
    ExpiryReminderKind.dayBefore => _l10n.reminderDayBefore(slot.count),
    ExpiryReminderKind.dayOf => _l10n.reminderDayOf(slot.count),
  };
}

/// Keeps the system's reminders in step with the credentials of an open
/// vault: a week before a password expires, the day before and on the
/// day, at [hour] in the morning.
///
/// It plans while the vault is open; what it planned stays with the
/// system after the vault locks, so a reminder still comes while the app
/// is closed. Nothing about a note leaves the vault but the day and the
/// count.
final class PasswordReminders {
  PasswordReminders({
    required this.store,
    required this.scheduler,
    required this.texts,
    this.clock = DateTime.now,
    this.hour = 9,
  });

  final NoteStore store;
  final ReminderScheduler scheduler;
  final ReminderTexts texts;
  final DateTime Function() clock;
  final int hour;

  List<ScheduledReminder>? _sent;
  bool? _allowed;
  Future<void> _queue = Future.value();
  var _disposed = false;

  /// Plans now and after every change to the notes.
  void start() {
    store.addListener(_changed);
    _changed();
  }

  /// Stops following the notes; the planned reminders stay.
  void dispose() {
    _disposed = true;
    store.removeListener(_changed);
  }

  /// Done when every plan asked for so far has reached the scheduler.
  Future<void> get settled => _queue;

  void _changed() {
    if (_disposed) return;
    final wanted = plan();
    // One plan at a time, in order: the last one wins.
    _queue = _queue.then((_) => _send(wanted));
  }

  /// The reminders the current notes call for, later than now.
  @visibleForTesting
  List<ScheduledReminder> plan() {
    final now = clock();
    return [
      for (final slot in PasswordExpiry.plan(
        store.entries,
        today: DateValue(now.year, now.month, now.day),
      ))
        if (DateTime(slot.day.year, slot.day.month, slot.day.day, hour)
            case final at when at.isAfter(now))
          ScheduledReminder(
            id: slot.id,
            at: at,
            title: texts.title,
            body: texts.body(slot),
          ),
    ];
  }

  Future<void> _send(List<ScheduledReminder> wanted) async {
    if (_sent != null && listEquals(_sent, wanted)) return;
    try {
      // Asked when there is something to remind, not at every unlock.
      if (wanted.isNotEmpty) _allowed ??= await scheduler.ask();
      await scheduler.replaceAll(wanted);
      _sent = wanted;
    } on Object catch (error) {
      // A reminder that cannot be set never stops the notes; the next
      // change or unlock tries again.
      debugPrint('password reminders: $error');
    }
  }
}
