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
  LocalReminderScheduler({required this.channel, required this.description});

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
    final wanted = {for (final r in reminders) r.id: r};
    final pending = {
      for (final p in await _plugin.pendingNotificationRequests()) p.id: p,
    };
    for (final MapEntry(key: id, value: request) in pending.entries) {
      final keep = wanted[id];
      if (keep == null ||
          keep.title != request.title ||
          keep.body != request.body) {
        await _plugin.cancel(id: id);
      }
    }
    for (final reminder in reminders) {
      final request = pending[reminder.id];
      if (request != null &&
          request.title == reminder.title &&
          request.body == reminder.body) {
        continue;
      }
      await _plugin.zonedSchedule(
        id: reminder.id,
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
