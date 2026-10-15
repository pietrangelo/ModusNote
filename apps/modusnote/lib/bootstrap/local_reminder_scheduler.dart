import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;

import '../reminders/password_reminders.dart';

/// The password reminders as the system's local notifications, on Android
/// and iOS. Nothing goes through a server: the system keeps them, with
/// their generic text and their time, and shows them when the app is
/// closed too.
///
/// Times are sent as instants in UTC, computed from the device's own zone
/// when the plan is made; the plan is made again at every unlock, so a
/// change of zone moves them then.
final class LocalReminderScheduler implements ReminderScheduler {
  LocalReminderScheduler({
    required this.channel,
    required this.description,
    this.scope = 0,
  }) : assert(scope >= 0 && scope < 1 << 7);

  /// The vault's place on the device (`ShelfEntry.scope`): each vault's
  /// reminders take their own range of notification ids, and a vault
  /// replaces only its own. The first vault's range is the ids the app
  /// always used.
  final int scope;

  static const _scopeShift = 24;

  /// The system's id for [reminder] in [scope]; reminder ids stay well
  /// below 2^24 (a day count and a kind).
  static int systemId(int scope, int reminder) {
    if (!fits(reminder)) {
      throw RangeError.range(reminder, 0, (1 << _scopeShift) - 1, 'reminder');
    }
    return scope << _scopeShift | reminder;
  }

  /// Whether [reminder] has an id in a vault's range.
  static bool fits(int reminder) =>
      reminder >= 0 && reminder < 1 << _scopeShift;

  /// Whether the system's notification [id] belongs to [scope].
  static bool owns(int scope, int id) => id >> _scopeShift == scope;

  /// The Android notification channel's name and description, in the
  /// person's language.
  final String channel;
  final String description;

  final _plugin = FlutterLocalNotificationsPlugin();
  Future<void>? _ready;

  Future<void> _init() => _ready ??= _plugin
      .initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('ic_notification'),
          iOS: DarwinInitializationSettings(
            requestAlertPermission: false,
            requestBadgePermission: false,
            requestSoundPermission: false,
          ),
        ),
      )
      .then((_) {});

  @override
  Future<bool> ask() async {
    await _init();
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (android != null) {
      return await android.requestNotificationsPermission() ?? false;
    }
    final ios = _plugin
        .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin
        >();
    return await ios?.requestPermissions(alert: true, sound: true) ?? false;
  }

  @override
  Future<void> replaceAll(List<ScheduledReminder> reminders) async {
    await _init();
    final wanted = {
      for (final r in reminders)
        // A date tens of millennia away has no id in the range.
        if (fits(r.id)) systemId(scope, r.id): r,
    };
    final pending = {
      for (final p in await _plugin.pendingNotificationRequests())
        if (owns(scope, p.id)) p.id: p,
    };
    for (final MapEntry(key: id, value: request) in pending.entries) {
      final keep = wanted[id];
      if (keep == null ||
          keep.title != request.title ||
          keep.body != request.body) {
        await _plugin.cancel(id: id);
      }
    }
    for (final MapEntry(key: id, value: reminder) in wanted.entries) {
      final request = pending[id];
      if (request != null &&
          request.title == reminder.title &&
          request.body == reminder.body) {
        continue;
      }
      await _plugin.zonedSchedule(
        id: id,
        title: reminder.title,
        body: reminder.body,
        scheduledDate: tz.TZDateTime.from(reminder.at, tz.UTC),
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            'password_expiry',
            channel,
            channelDescription: description,
            icon: 'ic_notification',
            category: AndroidNotificationCategory.reminder,
          ),
          iOS: const DarwinNotificationDetails(),
        ),
        // No exact-alarm permission: a few minutes late is fine.
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      );
    }
  }
}
