import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modusnote/appearance/appearance_scope.dart';
import 'package:modusnote/appearance/page_appearance.dart';
import 'package:modusnote/appearance/theme_memory.dart';
import 'package:modusnote/main.dart';
import 'package:modusnote/notes/note_editor.dart';
import 'package:modusnote/notes/note_library.dart';
import 'package:modusnote/notes/note_store.dart';
import 'package:modusnote/theme/modus_palette.dart';
import 'package:modusnote/theme/modus_themes.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';
import 'package:sqlite3/sqlite3.dart';

import '../notes/harness.dart';

/// What the screen is painted with: the nearest scaffold's background.
Color backgroundOf(WidgetTester tester, Finder screen) => Theme.of(
  tester.element(
    find.descendant(of: screen, matching: find.byType(Scaffold)).first,
  ),
).scaffoldBackgroundColor;

void main() {
  group('the theme the device remembers', () {
    late Database database;
    setUp(() => database = sqlite3.openInMemory());
    tearDown(() => database.close());

    test('is kept by name and read back', () async {
      final memory = SqliteThemeMemory(database);
      expect(memory.load(), isNull);
      await memory.save(AppTheme.paper);
      expect(SqliteThemeMemory(database).load(), AppTheme.paper);
    });

    test('an unknown name, from a newer app, is no theme', () {
      SqliteThemeMemory(database);
      database.execute(
        "INSERT INTO device_appearance (key, value) VALUES ('theme', 'neon')",
      );
      expect(SqliteThemeMemory(database).load(), isNull);
    });

    test('starts the app in it, and keeps a new choice', () async {
      await SqliteThemeMemory(database).save(AppTheme.restful);
      final settings = AppearanceSettings(
        themeMemory: SqliteThemeMemory(database),
      );
      expect(settings.theme, AppTheme.restful);

      settings.theme = AppTheme.paper;
      await pumpEventQueue();
      expect(SqliteThemeMemory(database).load(), AppTheme.paper);
    });

    test('without one the app is Modus', () {
      expect(AppearanceSettings().theme, AppTheme.modus);
    });

    test('closing the vault keeps the theme: it belongs to the device', () {
      final settings = AppearanceSettings()..theme = AppTheme.paper;
      settings.attach(const PageAppearance(), persist: (_) async {});
      settings.detach();
      expect(settings.theme, AppTheme.paper);
    });
  });

  testWidgets('the whole app takes the theme chosen', (tester) async {
    final settings = AppearanceSettings();
    await tester.pumpWidget(
      ModusNoteApp(
        home: NoteLibraryScreen(
          schemas: SeedSchemas.all,
          store: InMemoryNoteStore(),
        ),
        appearance: settings,
      ),
    );
    await tester.pumpAndSettle();
    final library = find.byType(NoteLibraryScreen);
    expect(backgroundOf(tester, library), ModusPalette.modus.background);

    settings.theme = AppTheme.paper;
    await tester.pumpAndSettle();
    expect(
      backgroundOf(tester, library),
      ModusThemes.palette(AppTheme.paper).background,
    );
    expect(Theme.of(tester.element(library)).brightness, Brightness.light);
  });

  group('the page of a note', () {
    late AppearanceSettings appearance;
    setUp(() => appearance = AppearanceSettings()..theme = AppTheme.restful);

    Future<void> open(WidgetTester tester, SchemaDefinition schema) => pumpApp(
      tester,
      NoteEditorScreen(
        schemas: SeedSchemas.all,
        store: InMemoryNoteStore(),
        initialSchema: schema,
      ),
      appearance: appearance,
    );

    final editor = find.byType(NoteEditorScreen);

    testWidgets('takes the mood of its type', (tester) async {
      await open(tester, SeedSchemas.bookChapterV1);
      expect(
        backgroundOf(tester, editor),
        ModusThemes.palette(AppTheme.restful, NoteMood.imagination).background,
      );
    });

    testWidgets('changes mood smoothly when the type changes', (tester) async {
      await open(tester, SeedSchemas.quickNoteV1);
      final concentration = ModusThemes.palette(
        AppTheme.restful,
        NoteMood.concentration,
      ).background;
      expect(backgroundOf(tester, editor), concentration);

      await tester.tap(find.byKey(const ValueKey('note-type')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('To-do').last);
      // Every frame until it settles: some fall between the two moods.
      final seen = <Color>{};
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        seen.add(backgroundOf(tester, editor));
      }
      await tester.pumpAndSettle();

      final order = ModusThemes.palette(
        AppTheme.restful,
        NoteMood.order,
      ).background;
      expect(backgroundOf(tester, editor), order);
      expect(seen.difference({concentration, order}), isNotEmpty);
    });

    testWidgets('keeps the app\'s theme when told not to follow the type', (
      tester,
    ) async {
      appearance.page = const PageAppearance(moods: false);
      await open(tester, SeedSchemas.dreamLogV1);
      expect(
        backgroundOf(tester, editor),
        ModusThemes.palette(AppTheme.restful).background,
      );
    });
  });

  group('the appearance sheet', () {
    testWidgets('the library opens it; a theme picked applies at once', (
      tester,
    ) async {
      final settings = AppearanceSettings();
      await tester.pumpWidget(
        ModusNoteApp(
          home: NoteLibraryScreen(
            schemas: SeedSchemas.all,
            store: InMemoryNoteStore(),
          ),
          appearance: settings,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Appearance'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('app-theme-paper')));
      await tester.pumpAndSettle();

      expect(settings.theme, AppTheme.paper);
      await tester.tap(find.byKey(const ValueKey('page-moods')));
      await tester.pumpAndSettle();
      expect(settings.page.moods, isFalse);
    });

    testWidgets('the palette switches theme by name', (tester) async {
      final settings = AppearanceSettings();
      await pumpApp(
        tester,
        NoteLibraryScreen(schemas: SeedSchemas.all, store: InMemoryNoteStore()),
        appearance: settings,
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'tema riposante');
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(settings.theme, AppTheme.restful);
    });
  });
}
