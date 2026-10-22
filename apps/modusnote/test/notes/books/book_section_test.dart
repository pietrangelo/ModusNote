import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modusnote/notes/note_editor.dart';
import 'package:modusnote/notes/note_store.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import '../harness.dart';
import 'book_support.dart';

void main() {
  late InMemoryNoteStore store;

  setUp(() async {
    store = await bookStore();
  });

  DynamicEntry entry(EntryId id) =>
      store.entries.firstWhere((entry) => entry.id == id);

  Future<void> open(
    WidgetTester tester,
    SchemaDefinition schema, {
    DynamicEntry? entry,
    CategoryId? category,
    List<SchemaDefinition>? offered,
  }) async {
    await pumpApp(
      tester,
      Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => NoteEditorScreen(
                    schemas: SeedSchemas.all,
                    offered: offered,
                    store: store,
                    entry: entry,
                    category: category,
                    initialSchema: schema,
                  ),
                ),
              ),
              child: const Text('apri'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('apri'));
    await tester.pumpAndSettle();
    // Room for the whole book below the page.
    tester.view.physicalSize = const Size(1080, 6000);
    await tester.pumpAndSettle();
  }

  testWidgets('a book shows its progress, chapters, characters and places', (
    tester,
  ) async {
    await open(tester, SeedSchemas.bookV1, entry: entry(bookId));

    expect(find.text('6 di 80.000 parole'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    final rows = [
      for (final id in ['c1', 'c2', 'c3', 'a1', 'a2', 'f1'])
        find.byKey(ValueKey('book-${id * 16}')),
    ];
    for (final row in rows) {
      expect(row, findsOneWidget);
    }
    // In the book's order: chapters by number, the unnumbered last.
    final tops = [for (final row in rows) tester.getTopLeft(row).dy];
    expect(tops, orderedEquals([...tops]..sort()));
    expect(find.text('4 parole'), findsOneWidget);
    expect(find.text('Idee'), findsNothing);
  });

  testWidgets('a chapter written from the book lands in its category', (
    tester,
  ) async {
    await open(tester, SeedSchemas.bookV1, entry: entry(bookId));

    await tester.tap(find.text('Nuovo capitolo'));
    await tester.pumpAndSettle();
    expect(find.text('Capitolo'), findsWidgets);
    await tester.enterText(textInput('title'), 'Il ritorno');
    await tester.enterText(textInput('body'), 'Tornò. Era *tardi*.');
    await tester.pump(NoteEditorScreen.wordCountDelay);
    expect(find.text('3 parole'), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    final chapter = store.entries.firstWhere(
      (e) => e.valueOf(FieldKey('title')) == const TextValue('Il ritorno'),
    );
    expect(chapter.schemaId, SeedSchemas.bookChapterV1.id);
    expect(store.categoryOf(chapter.id), novel);
    // Back on the book, counted with the rest.
    expect(find.text('9 di 80.000 parole'), findsOneWidget);
  });

  testWidgets('a part of a type turned off has no button; its rows stay', (
    tester,
  ) async {
    await open(
      tester,
      SeedSchemas.bookV1,
      entry: entry(bookId),
      offered: [
        for (final schema in SeedSchemas.all)
          if (schema.id != SeedSchemas.bookChapterV1.id) schema,
      ],
    );
    expect(find.text('Nuovo capitolo'), findsNothing);
    expect(find.text('Nuovo personaggio'), findsOneWidget);
    expect(find.byKey(ValueKey('book-${'c1' * 16}')), findsOneWidget);
  });

  testWidgets('a book in no category says where its parts go', (tester) async {
    await open(tester, SeedSchemas.bookV1);
    await tester.enterText(textInput('title'), 'Senza scaffale');
    await tester.pump();

    expect(
      find.textContaining('Metti il libro in una categoria'),
      findsOneWidget,
    );
    expect(find.text('Nuovo capitolo'), findsNothing);
  });

  testWidgets('a new book started in a category gathers it at once', (
    tester,
  ) async {
    await open(tester, SeedSchemas.bookV1, category: partTwo);

    expect(find.text('2 parole'), findsWidgets);
    expect(find.byKey(ValueKey('book-${'f1' * 16}')), findsOneWidget);
  });
}
