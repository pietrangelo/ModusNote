import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modusnote/notes/categories/categories_screen.dart';
import 'package:modusnote/notes/note_editor.dart';
import 'package:modusnote/notes/note_library.dart';
import 'package:modusnote/notes/note_store.dart';
import 'package:modusnote/notes/trash_screen.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import 'harness.dart';

/// From Android 15 the app draws edge to edge (and on older versions too,
/// MainActivity opts in): the system navigation bar lies over the bottom of
/// the window. Scrolled to the end, nothing may stay hidden under it.
const _navigationBar = 48.0;
const _screen = Size(360, 780);

DynamicEntry quickNote(String id, String content, int minute) =>
    switch (DynamicEntry.create(
      schema: SeedSchemas.quickNoteV1,
      id: EntryId(id),
      attributes: {FieldKey('content'): TextValue(content)},
      at: DateTime.utc(2026, 10, 13, 9, minute),
    )) {
      Valid(:final value) => value,
      Invalid(:final violations) => throw StateError('$violations'),
    };

Future<void> pumpEdgeToEdge(WidgetTester tester, Widget child) async {
  tester.view.padding = const FakeViewPadding(bottom: _navigationBar * 3);
  tester.view.viewPadding = const FakeViewPadding(bottom: _navigationBar * 3);
  addTearDown(tester.view.resetPadding);
  addTearDown(tester.view.resetViewPadding);
  await pumpApp(tester, child, size: _screen);
}

Future<void> scrollToEnd(WidgetTester tester, Finder scrollable) async {
  await tester.drag(scrollable, const Offset(0, -100000));
  await tester.pumpAndSettle();
}

void expectAboveNavigationBar(WidgetTester tester, Finder finder) => expect(
  tester.getRect(finder).bottom,
  lessThanOrEqualTo(_screen.height - _navigationBar),
);

/// Above the navigation bar, the floating button covers the end of a list too.
void expectAboveButton(WidgetTester tester, Finder finder) => expect(
  tester.getRect(finder).bottom,
  lessThanOrEqualTo(tester.getRect(find.byType(FloatingActionButton)).top),
);

void main() {
  late InMemoryNoteStore store;

  setUp(() => store = InMemoryNoteStore());

  testWidgets(
    'the last note in the library clears the button and the navigation bar',
    (tester) async {
      for (var i = 0; i < 20; i++) {
        await store.save(quickNote('n$i', 'Nota $i', i));
      }
      await pumpEdgeToEdge(
        tester,
        NoteLibraryScreen(schemas: SeedSchemas.all, store: store),
      );
      await scrollToEnd(tester, find.byType(CustomScrollView));

      // The oldest note is the last card.
      final card = find.ancestor(
        of: find.text('Nota 0').last,
        matching: find.byWidgetPredicate(
          (widget) => widget.runtimeType.toString() == '_NoteCard',
        ),
      );
      expectAboveButton(tester, card);
    },
  );

  testWidgets('the last note in the trash clears the navigation bar', (
    tester,
  ) async {
    for (var i = 0; i < 20; i++) {
      await store.save(quickNote('n$i', 'Nota $i', i));
      await store.moveToTrash(EntryId('n$i'));
    }
    await pumpEdgeToEdge(
      tester,
      TrashScreen(schemas: SeedSchemas.all, store: store),
    );
    await scrollToEnd(tester, find.byType(ListView));

    final last = find.byKey(ValueKey(store.trash.last.entry.id));
    expectAboveNavigationBar(tester, last);
  });

  testWidgets('the last category clears the button and the navigation bar', (
    tester,
  ) async {
    for (var i = 0; i < 30; i++) {
      await store.saveCategory(
        NoteCategory(
          id: CategoryId(i.toRadixString(16).padLeft(32, '0')),
          name: CategoryName('Categoria ${i.toString().padLeft(2, '0')}'),
        ),
      );
    }
    await pumpEdgeToEdge(tester, CategoriesScreen(store: store));
    await scrollToEnd(tester, find.byType(ListView));

    expectAboveButton(tester, find.text('Categoria 29'));
  });

  testWidgets('in focus mode the end of a long note clears the navigation '
      'bar', (tester) async {
    final long = List.filled(80, 'Una riga del testo.').join('\n');
    await store.save(quickNote('a', long, 1));
    await pumpEdgeToEdge(
      tester,
      NoteEditorScreen(
        schemas: SeedSchemas.all,
        store: store,
        initialSchema: SeedSchemas.quickNoteV1,
        entry: store.entries.single,
      ),
    );
    await tester.tap(find.byKey(const ValueKey('focus-mode')));
    await tester.pumpAndSettle();
    await scrollToEnd(tester, find.byKey(const ValueKey('note-page')));

    expectAboveNavigationBar(tester, textInput('content'));
  });
}
