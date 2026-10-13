import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modusnote/notes/command_palette.dart';
import 'package:modusnote/notes/note_editor.dart';
import 'package:modusnote/notes/note_library.dart';
import 'package:modusnote/notes/note_store.dart';
import 'package:modusnote/notes/trash_screen.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import 'harness.dart';

DynamicEntry entry(
  String id,
  SchemaDefinition schema,
  Map<String, FieldValue> attributes,
  int minute,
) => switch (DynamicEntry.create(
  schema: schema,
  id: EntryId(id),
  attributes: {for (final e in attributes.entries) FieldKey(e.key): e.value},
  at: DateTime.utc(2026, 10, 11, 9, minute),
)) {
  Valid(:final value) => value,
  Invalid(:final violations) => throw StateError('$violations'),
};

const song = '0000000000000000000000000000000a';
const riff = '0000000000000000000000000000000b';

final palette = find.byType(CommandPalette);

void main() {
  late InMemoryNoteStore store;

  setUp(() async {
    store = InMemoryNoteStore();
    await store.save(
      entry(song, SeedSchemas.songSketchV1, {
        'title': const TextValue('Notturno in La'),
      }, 1),
    );
    await store.save(
      entry(riff, SeedSchemas.quickNoteV1, {
        'content': const TextValue('Idea per un riff'),
      }, 2),
    );
  });

  Future<void> openLibrary(WidgetTester tester, {required bool wide}) async {
    await pumpApp(
      tester,
      NoteLibraryScreen(schemas: SeedSchemas.all, store: store),
    );
    if (wide) {
      tester.view
        ..devicePixelRatio = 1
        ..physicalSize = const Size(1440, 900);
      await tester.pumpAndSettle();
    }
  }

  Future<void> ctrlP(WidgetTester tester) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
  }

  Future<void> query(WidgetTester tester, String text) async {
    await tester.enterText(
      find.descendant(of: palette, matching: find.byType(TextField)),
      text,
    );
    await tester.pumpAndSettle();
  }

  Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await tester.pumpAndSettle();
  }

  testWidgets('Ctrl+P opens it; Enter opens the note found beside the list', (
    tester,
  ) async {
    await openLibrary(tester, wide: true);

    await ctrlP(tester);
    expect(palette, findsOneWidget);

    await query(tester, 'riff');
    expect(
      find.descendant(of: palette, matching: find.text('Idea per un riff')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: palette, matching: find.text('Notturno in La')),
      findsNothing,
    );
    await press(tester, LogicalKeyboardKey.enter);

    expect(palette, findsNothing);
    expect(fieldFinder('content'), findsOneWidget);
    expect(find.text('Idea per un riff'), findsWidgets);
  });

  testWidgets('the arrows move the choice', (tester) async {
    await openLibrary(tester, wide: true);
    await ctrlP(tester);

    await query(tester, 'cestino');
    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.arrowUp);
    await press(tester, LogicalKeyboardKey.enter);

    expect(find.byType(TrashScreen), findsOneWidget);
  });

  testWidgets('a new note of any type is a command', (tester) async {
    await openLibrary(tester, wide: true);
    await ctrlP(tester);

    await query(tester, 'nuova canzone');
    expect(
      find.descendant(of: palette, matching: find.text('Nuova nota: Canzone')),
      findsOneWidget,
    );
    await press(tester, LogicalKeyboardKey.enter);

    expect(find.byType(NoteEditorScreen), findsOneWidget);
    expect(fieldFinder('title'), findsOneWidget);
    expect(fieldFinder('lyrics'), findsOneWidget);
  });

  testWidgets('a tap runs a command too, Escape closes it', (tester) async {
    await openLibrary(tester, wide: true);
    await ctrlP(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(palette, findsNothing);

    await tester.tap(find.byTooltip('Cerca e comandi (Ctrl+P)'));
    await tester.pumpAndSettle();
    await query(tester, 'notturno');
    await tester.tap(
      find.descendant(of: palette, matching: find.text('Notturno in La')),
    );
    await tester.pumpAndSettle();
    expect(fieldFinder('title'), findsOneWidget);
  });

  testWidgets('it works while a note is being written', (tester) async {
    await openLibrary(tester, wide: true);
    await tester.tap(find.byKey(const ValueKey('note-row-$riff')));
    await tester.pumpAndSettle();
    await tester.enterText(textInput('content'), 'Idea per un riff in Mi');

    await ctrlP(tester);
    await query(tester, 'notturno');
    await press(tester, LogicalKeyboardKey.enter);

    expect(fieldFinder('title'), findsOneWidget);
    final saved = store.entries.firstWhere((e) => e.id.value == riff);
    expect(
      saved.attributes[FieldKey('content')],
      const TextValue('Idea per un riff in Mi'),
    );
  });

  testWidgets('on a narrow window a note opens on its page', (tester) async {
    await openLibrary(tester, wide: false);

    await ctrlP(tester);
    await query(tester, 'riff');
    await press(tester, LogicalKeyboardKey.enter);

    expect(find.byType(BackButton), findsOneWidget);
    expect(fieldFinder('content'), findsOneWidget);
  });
}
