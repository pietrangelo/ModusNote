import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modusnote/notes/journal/journal_days.dart';
import 'package:modusnote/notes/note_editor.dart';
import 'package:modusnote/notes/note_library.dart';
import 'package:modusnote/notes/note_store.dart';
import 'package:modusnote/notes/note_title.dart';
import 'package:modusnote/theme/golden_ratio.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import '../harness.dart';

final journal = SeedSchemas.journalV1;
final now = DateTime(2026, 10, 15, 10);
DateTime clock() => now;
final today = DateValue(2026, 10, 15);

var _ids = 0;

/// A journal page about [day], changed at [minute] past ten that day.
DynamicEntry page(
  DateValue day, {
  String? title,
  String? text,
  String? mood,
  int minute = 0,
}) => switch (DynamicEntry.create(
  schema: journal,
  id: EntryId((++_ids).toRadixString(16).padLeft(32, '0')),
  attributes: {
    Journal.date: day,
    if (title != null) FieldKey('title'): TextValue(title),
    if (text != null) Journal.page: TextValue(text),
    if (mood != null) Journal.mood: ChoiceValue(mood),
  },
  at: DateTime.utc(2026, 10, 15, 10, minute),
)) {
  Valid(:final value) => value,
  Invalid(:final violations) => throw StateError('$violations'),
};

Future<InMemoryNoteStore> storeWith(List<DynamicEntry> pages) async {
  final store = InMemoryNoteStore();
  for (final page in pages) {
    await store.save(page);
  }
  return store;
}

Finder key(String name) => find.byKey(ValueKey(name));

void main() {
  group('a new journal page', () {
    Future<InMemoryNoteStore> open(
      WidgetTester tester, {
      DateValue? day,
      List<DynamicEntry> pages = const [],
    }) async {
      final store = await storeWith(pages);
      await pumpApp(
        tester,
        NoteEditorScreen(
          schemas: SeedSchemas.all,
          store: store,
          initialSchema: journal,
          day: day,
          clock: clock,
        ),
      );
      return store;
    }

    testWidgets('is about today, and is no note until something is written', (
      tester,
    ) async {
      final store = await open(tester);
      expect(find.text('giovedì 15 ottobre 2026'), findsOneWidget);
      // Something written and taken back leaves only the day.
      await tester.enterText(textInput('page'), 'Forse');
      await tester.enterText(textInput('page'), '');
      await tester.pump(NoteEditorScreen.autosaveDelay);
      await tester.pumpAndSettle();
      expect(store.entries, isEmpty);
    });

    testWidgets('saves with its day, and counts its words', (tester) async {
      final store = await open(tester);
      await tester.enterText(
        textInput('page'),
        'Una giornata **lunga** al mare',
      );
      await tester.pump(NoteEditorScreen.wordCountDelay);
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('journal-words'), skipOffstage: false),
            )
            .data,
        '5 parole',
      );
      await tester.pump(NoteEditorScreen.autosaveDelay);
      await tester.pumpAndSettle();
      expect(Journal.dayOf(store.entries.single), today);
    });

    testWidgets('can be about another day', (tester) async {
      final store = await open(tester, day: DateValue(2026, 10, 12));
      expect(find.text('lunedì 12 ottobre 2026'), findsOneWidget);
      await tester.enterText(textInput('page'), 'Ieri sera');
      await tester.pump(NoteEditorScreen.autosaveDelay);
      await tester.pumpAndSettle();
      expect(Journal.dayOf(store.entries.single), DateValue(2026, 10, 12));
    });

    testWidgets('shows the same day in earlier years', (tester) async {
      final lastYear = page(
        DateValue(2025, 10, 15),
        text: 'Primo giorno di lavoro\n\naltro',
        mood: 'great',
      );
      await open(
        tester,
        pages: [
          lastYear,
          page(DateValue(2025, 10, 16), text: 'Il giorno dopo'),
        ],
      );
      await tester.scrollUntilVisible(
        key('on-this-day'),
        Spacing.xxl,
        scrollable: find
            .descendant(of: key('note-page'), matching: find.byType(Scrollable))
            .first,
      );
      expect(
        find.text('Un anno fa · mercoledì 15 ottobre 2025'),
        findsOneWidget,
      );
      expect(find.text('Ottimo · Primo giorno di lavoro'), findsOneWidget);
      expect(find.textContaining('Il giorno dopo'), findsNothing);
    });

    testWidgets('a day without earlier years shows no section', (tester) async {
      await open(tester);
      expect(key('on-this-day'), findsNothing);
    });

    testWidgets('switching to the journal starts on today', (tester) async {
      final store = InMemoryNoteStore();
      await pumpApp(
        tester,
        NoteEditorScreen(
          schemas: SeedSchemas.all,
          store: store,
          initialSchema: SeedSchemas.quickNoteV1,
          clock: clock,
        ),
      );
      await tester.tap(key('note-type'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Diario giornaliero').last);
      await tester.pumpAndSettle();
      expect(key('journal-day'), findsOneWidget);
    });
  });

  group('the title of a page', () {
    test('is its title, else its day', () {
      expect(NoteTitle.of(page(today, title: 'Mare'), journal), 'Mare');
      expect(NoteTitle.of(page(today), journal), '2026-10-15');
      expect(NoteTitle.of(page(today), journal, day: (d) => 'oggi'), 'oggi');
    });
  });

  test('a dot is as strong as the mood, in steps of φ', () {
    expect(JournalDays.strength(null), 1);
    expect(JournalDays.strength('great'), 1);
    expect(JournalDays.strength('good'), closeTo(1 / GoldenRatio.phi, 1e-9));
    expect(
      JournalDays.strength('hard'),
      closeTo(
        1 /
            (GoldenRatio.phi *
                GoldenRatio.phi *
                GoldenRatio.phi *
                GoldenRatio.phi),
        1e-9,
      ),
    );
  });

  group('the journal in the library', () {
    Future<InMemoryNoteStore> library(
      WidgetTester tester,
      List<DynamicEntry> pages, {
      Size size = const Size(360, 780),
    }) async {
      final store = await storeWith(pages);
      await pumpApp(
        tester,
        NoteLibraryScreen(schemas: SeedSchemas.all, store: store, clock: clock),
        size: size,
      );
      return store;
    }

    Future<void> pickJournal(WidgetTester tester) async {
      final chip = find.widgetWithText(ChoiceChip, 'Diario giornaliero');
      await tester.ensureVisible(chip);
      await tester.pumpAndSettle();
      await tester.tap(chip);
      await tester.pumpAndSettle();
    }

    testWidgets('goes by day, not by last change; untitled pages by date', (
      tester,
    ) async {
      final older = page(
        DateValue(2026, 10, 1),
        title: 'Settembre',
        minute: 30,
      );
      final newer = page(DateValue(2026, 10, 14), minute: 1);
      await library(tester, [older, newer]);
      await pickJournal(tester);
      final texts = [
        for (final e in find.byType(Text).evaluate()) (e.widget as Text).data,
      ];
      expect(
        texts.indexOf('mercoledì 14 ottobre 2026'),
        allOf(isNonNegative, lessThan(texts.indexOf('Settembre'))),
      );
    });

    testWidgets('on a phone: the week, today unwritten, a page a tap away', (
      tester,
    ) async {
      final monday = page(
        DateValue(2026, 10, 12),
        title: 'Lunedì',
        mood: 'hard',
      );
      await library(tester, [monday]);
      await pickJournal(tester);

      expect(key('journal-calendar'), findsOneWidget);
      expect(key('calendar-previous'), findsNothing);
      expect(key('not-written-today'), findsOneWidget);
      expect(key('calendar-dot-2026-10-12'), findsOneWidget);
      expect(key('calendar-dot-2026-10-13'), findsNothing);
      // Days still to come wait.
      final saturday = tester.widget<InkWell>(key('calendar-day-2026-10-17'));
      expect(saturday.onTap, isNull);

      await tester.tap(key('calendar-day-2026-10-12'));
      await tester.pumpAndSettle();
      expect(find.byType(NoteEditorScreen), findsOneWidget);
      expect(find.text('Lunedì'), findsWidgets);
    });

    testWidgets('the journal\'s settings are a tap away where there are any', (
      tester,
    ) async {
      var opened = 0;
      await pumpApp(
        tester,
        NoteLibraryScreen(
          schemas: SeedSchemas.all,
          store: InMemoryNoteStore(),
          clock: clock,
          journalSettings: () => opened++,
        ),
      );
      await pickJournal(tester);
      await tester.tap(key('journal-settings'));
      expect(opened, 1);
    });

    testWidgets('no settings button without reminders (the web)', (
      tester,
    ) async {
      await library(tester, const []);
      await pickJournal(tester);
      expect(key('journal-settings'), findsNothing);
    });

    testWidgets('a day without a page starts one on that day', (tester) async {
      await library(tester, const []);
      await pickJournal(tester);
      await tester.tap(key('calendar-day-2026-10-13'));
      await tester.pumpAndSettle();
      expect(find.text('martedì 13 ottobre 2026'), findsOneWidget);
    });

    testWidgets('«today» opens today\'s page, the one changed last', (
      tester,
    ) async {
      await library(tester, [
        page(today, title: 'Dal telefono'),
        page(today, title: 'Dal browser', minute: 5),
      ]);
      await pickJournal(tester);
      expect(key('not-written-today'), findsNothing);
      await tester.tap(key('journal-today'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(NoteEditorScreen),
          matching: find.text('Dal browser'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('a wide window shows the month, with a way through it', (
      tester,
    ) async {
      await library(tester, [
        page(DateValue(2026, 9, 3), mood: 'good'),
      ], size: const Size(1440, 1000));
      await tester.tap(key('nav-journal'));
      await tester.pumpAndSettle();
      expect(find.text('ottobre 2026'), findsOneWidget);
      expect(key('calendar-day-2026-10-31'), findsOneWidget);
      expect(key('calendar-today'), findsNothing);

      await tester.tap(key('calendar-previous'));
      await tester.pumpAndSettle();
      expect(find.text('settembre 2026'), findsOneWidget);
      expect(key('calendar-dot-2026-09-03'), findsOneWidget);
      await tester.tap(key('calendar-today'));
      await tester.pumpAndSettle();
      expect(find.text('ottobre 2026'), findsOneWidget);

      await tester.tap(key('calendar-day-2026-10-02'));
      await tester.pumpAndSettle();
      expect(find.text('venerdì 2 ottobre 2026'), findsOneWidget);
    });

    Future<void> run(WidgetTester tester, String query) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, query);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
    }

    testWidgets('the palette opens this day in an earlier year', (
      tester,
    ) async {
      await library(tester, [
        page(DateValue(2024, 10, 15), title: 'Due anni fa'),
      ]);
      await run(tester, 'in questo giorno');
      expect(
        find.descendant(
          of: find.byType(NoteEditorScreen),
          matching: find.text('Due anni fa'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('the palette starts today\'s page', (tester) async {
      await library(tester, const []);
      await run(tester, 'diario di oggi');
      expect(find.text('giovedì 15 ottobre 2026'), findsOneWidget);
    });
  });
}
