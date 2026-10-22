import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modusnote/l10n/generated/app_localizations_it.dart';
import 'package:modusnote/notes/command_palette.dart';
import 'package:modusnote/notes/note_editor.dart';
import 'package:modusnote/notes/note_library.dart';
import 'package:modusnote/notes/note_store.dart';
import 'package:modusnote/notes/note_types.dart';
import 'package:modusnote/reminders/journal_reminder.dart';
import 'package:modusnote/reminders/password_reminders.dart';
import 'package:modusnote/theme/golden_ratio.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import 'harness.dart';

const song = '0000000000000000000000000000000a';

DynamicEntry songNote() => switch (DynamicEntry.create(
  schema: SeedSchemas.songSketchV1,
  id: EntryId(song),
  attributes: {FieldKey('title'): const TextValue('Notturno in La')},
  at: DateTime.utc(2026, 10, 22, 9),
)) {
  Valid(:final value) => value,
  Invalid(:final violations) => throw StateError('$violations'),
};

Finder key(String name) => find.byKey(ValueKey(name));

final class FakeScheduler implements ReminderScheduler {
  final sent = <List<ScheduledReminder>>[];

  @override
  Future<bool> ask() async => true;

  @override
  Future<void> replaceAll(List<ScheduledReminder> reminders) async =>
      sent.add(reminders);
}

void main() {
  final schemas = SeedSchemas.all;
  late List<Uint8List> kept;
  late NoteTypeSetting setting;

  setUp(() {
    kept = [];
    setting = NoteTypeSetting(
      const NoteTypeChoice(),
      persist: (bytes) async => kept.add(bytes),
    );
  });

  test('a change is kept, the same choice is not written again', () {
    final off = setting.value.turnedOff('song_sketch', schemas);
    setting.value = off;
    setting.value = off;
    expect(kept, hasLength(1));
    expect(NoteTypeChoice.fromBytes(kept.single), off);
  });

  group('the sheet', () {
    Future<void> show(WidgetTester tester) async {
      await pumpApp(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => NoteTypesSheet.show(
              context,
              schemas: schemas,
              setting: setting,
            ),
            child: const Text('apri'),
          ),
        ),
      );
      await tester.tap(find.text('apri'));
      await tester.pumpAndSettle();
    }

    testWidgets('a switch per type; one turned off is kept', (tester) async {
      await show(tester);
      expect(find.text('Tipi di nota'), findsOneWidget);
      // The sheet scrolls: the last type is there too.
      await tester.scrollUntilVisible(
        key('note-type-${schemas.last.id.name}'),
        Spacing.xl,
        scrollable: find.descendant(
          of: key('note-types-sheet'),
          matching: find.byType(Scrollable),
        ),
      );
      final last = schemas.last.id.name;
      await tester.ensureVisible(key('note-type-$last'));
      await tester.pumpAndSettle();
      await tester.tap(key('note-type-$last'));
      await tester.pumpAndSettle();
      expect(setting.value.isOn(last), isFalse);
      expect(
        tester.widget<SwitchListTile>(key('note-type-$last')).value,
        isFalse,
      );
      await tester.tap(key('note-type-$last'));
      await tester.pumpAndSettle();
      expect(setting.value, const NoteTypeChoice());
    });

    testWidgets('the last type on cannot be turned off', (tester) async {
      var choice = const NoteTypeChoice();
      for (final schema in schemas.skip(1)) {
        choice = choice.turnedOff(schema.id.name, schemas);
      }
      setting.value = choice;
      await show(tester);
      final last = schemas.first.id.name;
      expect(
        tester.widget<SwitchListTile>(key('note-type-$last')).onChanged,
        isNull,
      );
    });
  });

  group('the library', () {
    late InMemoryNoteStore store;

    setUp(() async {
      store = InMemoryNoteStore();
      await store.save(songNote());
      setting.value = setting.value.turnedOff('song_sketch', schemas);
    });

    Future<void> library(WidgetTester tester, {bool wide = false}) async {
      await pumpApp(
        tester,
        NoteLibraryScreen(schemas: schemas, store: store, noteTypes: setting),
        size: wide ? const Size(1440, 900) : const Size(360, 780),
      );
    }

    testWidgets('no filter for a type turned off; its notes stay and open', (
      tester,
    ) async {
      await library(tester);
      expect(find.widgetWithText(ChoiceChip, 'Canzone'), findsNothing);
      expect(find.widgetWithText(ChoiceChip, 'Appunto'), findsOneWidget);
      expect(find.text('Notturno in La'), findsOneWidget);
      await tester.tap(find.text('Notturno in La'));
      await tester.pumpAndSettle();
      expect(find.byType(NoteEditorScreen), findsOneWidget);
    });

    testWidgets('a new note offers only the types on', (tester) async {
      await library(tester);
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      await tester.tap(key('note-type'));
      await tester.pumpAndSettle();
      expect(
        find.widgetWithText(PopupMenuItem<SchemaDefinition>, 'Canzone'),
        findsNothing,
      );
      expect(
        find.widgetWithText(PopupMenuItem<SchemaDefinition>, 'Sogno'),
        findsOneWidget,
      );
    });

    testWidgets('the palette offers no new note of a type turned off', (
      tester,
    ) async {
      await library(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byType(CommandPalette),
          matching: find.byType(TextField),
        ),
        'nuova nota',
      );
      await tester.pumpAndSettle();
      expect(find.text('Nuova nota: Canzone'), findsNothing);
      expect(find.text('Nuova nota: Sogno'), findsOneWidget);
    });

    testWidgets('a filter by a type just turned off goes', (tester) async {
      setting.value = const NoteTypeChoice();
      await library(tester);
      await tester.tap(find.widgetWithText(ChoiceChip, 'Canzone'));
      await tester.pumpAndSettle();
      setting.value = setting.value.turnedOff('song_sketch', schemas);
      await tester.pumpAndSettle();
      final all = tester.widget<ChoiceChip>(
        find.widgetWithText(ChoiceChip, 'Tutte'),
      );
      expect(all.selected, isTrue);
      expect(find.text('Notturno in La'), findsOneWidget);
    });

    testWidgets('the button opens the sheet, on a phone and wide', (
      tester,
    ) async {
      await library(tester);
      await tester.tap(key('note-types-settings'));
      await tester.pumpAndSettle();
      expect(key('note-types-sheet'), findsOneWidget);
    });

    testWidgets('wide: the side column lists only the types on', (
      tester,
    ) async {
      await library(tester, wide: true);
      expect(key('nav-song_sketch'), findsNothing);
      expect(key('nav-quick_note'), findsOneWidget);
      await tester.tap(key('note-types-settings'));
      await tester.pumpAndSettle();
      expect(key('note-types-sheet'), findsOneWidget);
    });

    testWidgets('the journal turned off takes its calendar along', (
      tester,
    ) async {
      setting.value = setting.value.turnedOff('journal', schemas);
      await library(tester);
      expect(
        find.widgetWithText(ChoiceChip, 'Diario giornaliero'),
        findsNothing,
      );
      expect(key('journal-calendar'), findsNothing);
    });
  });

  test(
    'the journal turned off rings no more, and back on rings again',
    () async {
      final store = InMemoryNoteStore();
      final scheduler = FakeScheduler();
      final journal = JournalReminderSetting(
        const JournalReminder(enabled: true),
        persist: (_) async {},
      );
      final offered = OfferedJournalReminder(
        journal,
        types: setting,
        journalOn: () => setting.value.isOn(Journal.schema),
      );
      final reminders = PasswordReminders(
        store: store,
        scheduler: scheduler,
        texts: ReminderTexts(AppLocalizationsIt()),
        journal: offered,
        clock: () => DateTime(2026, 10, 22, 15),
      )..start();
      addTearDown(() {
        reminders.dispose();
        offered.dispose();
      });
      await reminders.settled;
      expect(scheduler.sent.last, hasLength(Journal.reminderDays));

      setting.value = setting.value.turnedOff(Journal.schema, schemas);
      await reminders.settled;
      expect(scheduler.sent.last, isEmpty);
      // The reminder itself is still set, for when the journal comes back.
      expect(journal.value.enabled, isTrue);

      setting.value = setting.value.turnedOn(Journal.schema);
      await reminders.settled;
      expect(scheduler.sent.last, hasLength(Journal.reminderDays));
    },
  );
}
