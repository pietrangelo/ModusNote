import 'dart:async';

import 'package:flutter/foundation.dart';

/// Whether this device reminds its person, each day, to write in the
/// journal, and at what time. Off unless turned on; 21:00 proposed.
@immutable
final class JournalReminder {
  const JournalReminder({this.enabled = false, this.hour = 21, this.minute = 0})
    : assert(hour >= 0 && hour < 24 && minute >= 0 && minute < 60);

  final bool enabled;
  final int hour;
  final int minute;

  JournalReminder copyWith({bool? enabled, int? hour, int? minute}) =>
      JournalReminder(
        enabled: enabled ?? this.enabled,
        hour: hour ?? this.hour,
        minute: minute ?? this.minute,
      );

  /// Version, on or off, hour, minute.
  Uint8List toBytes() =>
      Uint8List.fromList([1, if (enabled) 1 else 0, hour, minute]);

  /// What [toBytes] wrote; anything else, or nothing, is the default: a
  /// damaged setting never rings.
  static JournalReminder fromBytes(Uint8List? bytes) {
    if (bytes == null ||
        bytes.length != 4 ||
        bytes[0] != 1 ||
        bytes[1] > 1 ||
        bytes[2] > 23 ||
        bytes[3] > 59) {
      return const JournalReminder();
    }
    return JournalReminder(
      enabled: bytes[1] == 1,
      hour: bytes[2],
      minute: bytes[3],
    );
  }

  @override
  bool operator ==(Object other) =>
      other is JournalReminder &&
      other.enabled == enabled &&
      other.hour == hour &&
      other.minute == minute;

  @override
  int get hashCode => Object.hash(enabled, hour, minute);
}

/// The [JournalReminder] of an open vault: a change shows at once and is
/// kept by [persist] (a sealed setting of this device).
final class JournalReminderSetting extends ValueNotifier<JournalReminder> {
  JournalReminderSetting(super.value, {required this.persist});

  final Future<void> Function(Uint8List bytes) persist;

  @override
  set value(JournalReminder reminder) {
    if (reminder == value) return;
    super.value = reminder;
    unawaited(persist(reminder.toBytes()));
  }
}

/// The [reminder] while [journalOn] says the journal is offered on this
/// device: turning the journal's type off silences it, and turning it back
/// on brings the reminder back as it was set.
final class OfferedJournalReminder extends ChangeNotifier
    implements ValueListenable<JournalReminder> {
  OfferedJournalReminder(
    this.reminder, {
    required this.types,
    required this.journalOn,
  }) {
    reminder.addListener(notifyListeners);
    types.addListener(notifyListeners);
  }

  final ValueListenable<JournalReminder> reminder;

  /// Tells when the types offered change.
  final Listenable types;
  final bool Function() journalOn;

  @override
  JournalReminder get value =>
      journalOn() ? reminder.value : reminder.value.copyWith(enabled: false);

  @override
  void dispose() {
    reminder.removeListener(notifyListeners);
    types.removeListener(notifyListeners);
    super.dispose();
  }
}
