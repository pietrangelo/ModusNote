import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modusnote/l10n/generated/app_localizations_it.dart';
import 'package:modusnote/notes/journal/journal_settings_sheet.dart';
import 'package:modusnote/notes/note_store.dart';
import 'package:modusnote/reminders/journal_reminder.dart';
import 'package:modusnote/reminders/password_reminders.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import '../notes/harness.dart';

final class FakeScheduler implements ReminderScheduler {
  final sent = <List<ScheduledReminder>>[];
  var asked = 0;

  @override
  Future<bool> ask() async {
    asked++;
    return true;
  }

  @override
  Future<void> replaceAll(List<ScheduledReminder> reminders) async =>
      sent.add(reminders);
}

DynamicEntry journalPage(DateValue day, {String text = 'Segreto'}) =>
    switch (DynamicEntry.create(
      schema: SeedSchemas.journalV1,
      id: EntryId('${day.day}'.padLeft(32, 'a')),
      attributes: {Journal.date: day, Journal.page: TextValue(text)},
      at: DateTime.utc(2026, 10, 14),
    )) {
      Valid(:final value) => value,
      Invalid(:final violations) => throw StateError('$violations'),
    };

void main() {
  group('the setting', () {
    test('is off at 21:00 unless chosen', () {
      const reminder = JournalReminder();
      expect(
        (reminder.enabled, reminder.hour, reminder.minute),
        (false, 21, 0),
      );
    });

    test('round-trips, and anything damaged is the default', () {
      const chosen = JournalReminder(enabled: true, hour: 7, minute: 30);
      expect(JournalReminder.fromBytes(chosen.toBytes()), chosen);
      for (final bytes in [
        null,
        Uint8List(0),
        Uint8List.fromList([2, 1, 7, 30]),
        Uint8List.fromList([1, 2, 7, 30]),
        Uint8List.fromList([1, 1, 24, 0]),
        Uint8List.fromList([1, 1, 7, 60]),
        Uint8List.fromList([1, 1, 7, 30, 0]),
      ]) {
        expect(JournalReminder.fromBytes(bytes), const JournalReminder());
      }
    });

    test('a change is kept, the same choice is not written again', () async {
      final kept = <Uint8List>[];
      final setting = JournalReminderSetting(
        const JournalReminder(),
        persist: (bytes) async => kept.add(bytes),
      );
      setting.value = const JournalReminder(enabled: true);
      setting.value = const JournalReminder(enabled: true);
      expect(kept, hasLength(1));
      expect(JournalReminder.fromBytes(kept.single).enabled, isTrue);
    });
  });

  group('the daily reminders', () {
    late InMemoryNoteStore store;
    late FakeScheduler scheduler;
    late JournalReminderSetting journal;
    late PasswordReminders reminders;
    var now = DateTime(2026, 10, 14, 15);

    setUp(() {
      now = DateTime(2026, 10, 14, 15);
      store = InMemoryNoteStore();
      scheduler = FakeScheduler();
      journal = JournalReminderSetting(
        const JournalReminder(),
        persist: (_) async {},
      );
      reminders = PasswordReminders(
        store: store,
        scheduler: scheduler,
        texts: ReminderTexts(AppLocalizationsIt()),
        journal: journal,
        clock: () => now,
      );
    });

    tearDown(() => reminders.dispose());

    test('none while off; nothing asked', () async {
      reminders.start();
      await reminders.settled;
      expect(scheduler.sent.last, isEmpty);
      expect(scheduler.asked, 0);
    });

    test('once on: one a day at its time, for the week ahead', () async {
      reminders.start();
      journal.value = const JournalReminder(enabled: true);
      await reminders.settled;
      final sent = scheduler.sent.last;
      expect(sent.map((r) => r.at), [
        for (var d = 14; d < 21; d++) DateTime(2026, 10, d, 21),
      ]);
      expect(sent.every((r) => r.topic == ReminderTopic.journal), isTrue);
      expect(sent.map((r) => r.id).toSet(), hasLength(7));
      expect(scheduler.asked, 1);
    });

    test('a day written rings no more; the text never says what', () async {
      journal.value = const JournalReminder(enabled: true, hour: 9);
      reminders.start();
      // 9:00 today has passed: tomorrow first.
      await reminders.settled;
      expect(scheduler.sent.last.first.at, DateTime(2026, 10, 15, 9));

      await store.save(
        journalPage(DateValue(2026, 10, 15), text: 'Il mio segreto'),
      );
      await reminders.settled;
      final sent = scheduler.sent.last;
      expect(sent.first.at, DateTime(2026, 10, 16, 9));
      for (final reminder in sent) {
        expect(reminder.title, 'Diario');
        expect(reminder.body, 'È il momento di scrivere nel diario.');
      }
    });

    test('turning it off withdraws them', () async {
      journal.value = const JournalReminder(enabled: true);
      reminders.start();
      await reminders.settled;
      journal.value = const JournalReminder();
      await reminders.settled;
      expect(scheduler.sent.last, isEmpty);
    });
  });

  testWidgets('the sheet turns the reminder on', (tester) async {
    final setting = JournalReminderSetting(
      const JournalReminder(),
      persist: (_) async {},
    );
    await pumpApp(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () => JournalSettingsSheet.show(context, setting),
          child: const Text('apri'),
        ),
      ),
    );
    await tester.tap(find.text('apri'));
    await tester.pumpAndSettle();
    expect(
      find.text('Alle 21:00, solo nei giorni senza pagina'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<ListTile>(find.byKey(const ValueKey('journal-reminder-time')))
          .enabled,
      isFalse,
    );
    await tester.tap(find.byKey(const ValueKey('journal-reminder')));
    await tester.pumpAndSettle();
    expect(setting.value.enabled, isTrue);
  });
}
