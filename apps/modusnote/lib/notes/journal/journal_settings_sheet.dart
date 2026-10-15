import 'package:flutter/material.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../reminders/journal_reminder.dart';
import '../../theme/golden_ratio.dart';

/// The journal's settings on this device: the daily reminder, off or on,
/// and its time.
abstract final class JournalSettingsSheet {
  static Future<void> show(
    BuildContext context,
    JournalReminderSetting setting,
  ) => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) => ValueListenableBuilder(
      valueListenable: setting,
      builder: (context, reminder, _) {
        final l10n = AppLocalizations.of(context);
        final time = TimeOfDay(hour: reminder.hour, minute: reminder.minute);
        final shown = MaterialLocalizations.of(context).formatTimeOfDay(
          time,
          alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
        );
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.only(bottom: Spacing.l),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SwitchListTile(
                  key: const ValueKey('journal-reminder'),
                  value: reminder.enabled,
                  title: Text(l10n.journalReminder),
                  subtitle: Text(l10n.journalReminderHint(shown)),
                  onChanged: (on) =>
                      setting.value = reminder.copyWith(enabled: on),
                ),
                ListTile(
                  key: const ValueKey('journal-reminder-time'),
                  enabled: reminder.enabled,
                  leading: const Icon(Icons.schedule),
                  title: Text(l10n.journalReminderTime),
                  trailing: Text(shown),
                  onTap: () async {
                    final picked = await showTimePicker(
                      context: context,
                      initialTime: time,
                    );
                    if (picked == null) return;
                    setting.value = setting.value.copyWith(
                      hour: picked.hour,
                      minute: picked.minute,
                    );
                  },
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}
