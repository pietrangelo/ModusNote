import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modusnote/notes/note_editor.dart';
import 'package:modusnote/notes/note_library.dart';
import 'package:modusnote/notes/note_store.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import 'harness.dart';

DynamicEntry entry(String id, String content, int minute) =>
    switch (DynamicEntry.create(
      schema: SeedSchemas.quickNoteV1,
      id: EntryId(id),
      attributes: {FieldKey('content'): TextValue(content)},
      at: DateTime.utc(2026, 10, 11, 9, minute),
    )) {
      Valid(:final value) => value,
      Invalid(:final violations) => throw StateError('$violations'),
    };

const a = '0000000000000000000000000000000a';
const b = '0000000000000000000000000000000b';
const c = '0000000000000000000000000000000c';

Finder row(String id) => find.byKey(ValueKey('note-row-$id'));
Finder button(String name) => find.byKey(ValueKey('selection-$name'));

void main() {
  late InMemoryNoteStore store;

  setUp(() async {
    store = InMemoryNoteStore();
    // Most recent first: c, b, a.
    await store.save(entry(a, 'Prima idea', 1));
    await store.save(entry(b, 'Seconda idea', 2));
    await store.save(entry(c, 'Terza idea', 3));
  });

  Future<void> openWide(WidgetTester tester) async {
    await pumpApp(
      tester,
      NoteLibraryScreen(schemas: SeedSchemas.all, store: store),
    );
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(1440, 900);
    await tester.pumpAndSettle();
  }

  Future<void> clickWith(
    WidgetTester tester,
    LogicalKeyboardKey key,
    Finder target,
  ) async {
    await tester.sendKeyDownEvent(key);
    await tester.tap(target);
    await tester.sendKeyUpEvent(key);
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, Finder target) async {
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  Set<String> trashed() => {for (final n in store.trash) n.entry.id.value};

  testWidgets('Ctrl+click picks notes without opening them', (tester) async {
    await openWide(tester);

    await clickWith(tester, LogicalKeyboardKey.controlLeft, row(a));
    await clickWith(tester, LogicalKeyboardKey.controlLeft, row(c));

    expect(find.text('2 note selezionate'), findsOneWidget);
    expect(find.byType(NoteEditorScreen), findsNothing);
    expect(
      tester
          .widget<Checkbox>(
            find.descendant(of: row(a), matching: find.byType(Checkbox)),
          )
          .value,
      isTrue,
    );
    expect(
      tester
          .widget<Checkbox>(
            find.descendant(of: row(b), matching: find.byType(Checkbox)),
          )
          .value,
      isFalse,
    );

    await clickWith(tester, LogicalKeyboardKey.controlLeft, row(a));
    expect(find.text('1 nota selezionata'), findsOneWidget);
  });

  testWidgets('Shift+click picks every note in between', (tester) async {
    await openWide(tester);

    await clickWith(tester, LogicalKeyboardKey.controlLeft, row(c));
    await clickWith(tester, LogicalKeyboardKey.shiftLeft, row(a));

    expect(find.text('3 note selezionate'), findsOneWidget);
  });

  testWidgets('the selected notes go to the trash, and come back on undo', (
    tester,
  ) async {
    await openWide(tester);
    await clickWith(tester, LogicalKeyboardKey.controlLeft, row(a));
    await clickWith(tester, LogicalKeyboardKey.controlLeft, row(b));

    await tap(tester, button('trash'));

    expect(trashed(), {a, b});
    expect(row(a), findsNothing);
    expect(row(c), findsOneWidget);
    expect(find.text('2 note spostate nel cestino.'), findsOneWidget);
    expect(find.textContaining('selezionat'), findsNothing);

    await tap(tester, find.text('Annulla'));
    expect(trashed(), isEmpty);
    expect(row(a), findsOneWidget);
  });

  testWidgets('the selected notes move to a category together', (tester) async {
    final songs = CategoryId('d' * 32);
    await store.saveCategory(
      NoteCategory(id: songs, name: CategoryName('Canzoni')),
    );
    await openWide(tester);
    await clickWith(tester, LogicalKeyboardKey.controlLeft, row(b));
    await clickWith(tester, LogicalKeyboardKey.controlLeft, row(c));

    await tap(tester, button('file'));
    await tap(tester, find.byKey(ValueKey('pick-${songs.value}')));

    expect(store.categoryOf(EntryId(b)), songs);
    expect(store.categoryOf(EntryId(c)), songs);
    expect(store.categoryOf(EntryId(a)), isNull);
    expect(find.text('2 note spostate in «Canzoni».'), findsOneWidget);
  });

  testWidgets('the select button lets a plain click pick, Escape ends it', (
    tester,
  ) async {
    await openWide(tester);

    await tap(tester, find.byTooltip('Seleziona note'));
    expect(find.text('0 note selezionate'), findsOneWidget);
    await tap(tester, row(b));
    expect(find.text('1 nota selezionata'), findsOneWidget);
    expect(find.byType(NoteEditorScreen), findsNothing);

    await tap(tester, button('all'));
    expect(find.text('3 note selezionate'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.textContaining('selezionat'), findsNothing);

    await tap(tester, row(b));
    expect(find.byType(NoteEditorScreen), findsOneWidget);
  });

  testWidgets('trashing the open note saves what was written and closes it', (
    tester,
  ) async {
    await openWide(tester);
    await tap(tester, row(a));
    await tester.enterText(textInput('content'), 'Prima idea, rivista');

    await clickWith(tester, LogicalKeyboardKey.controlLeft, row(a));
    await tap(tester, button('trash'));

    expect(find.byType(NoteEditorScreen), findsNothing);
    final note = store.trash.single;
    expect(
      note.entry.attributes[FieldKey('content')],
      const TextValue('Prima idea, rivista'),
    );
  });

  testWidgets('a note that leaves the list leaves the selection', (
    tester,
  ) async {
    await openWide(tester);
    await clickWith(tester, LogicalKeyboardKey.controlLeft, row(a));
    await clickWith(tester, LogicalKeyboardKey.controlLeft, row(b));

    await tester.enterText(find.byType(TextField).first, 'Seconda');
    await tester.pumpAndSettle();
    await tap(tester, button('trash'));

    expect(trashed(), {b}, reason: 'only what the list shows is acted on');
  });
}
