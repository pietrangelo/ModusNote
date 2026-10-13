import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modusnote/notes/editor/markdown_commands.dart';
import 'package:modusnote/notes/editor/markdown_controller.dart';
import 'package:modusnote/notes/markdown/markdown_document.dart';
import 'package:modusnote/notes/note_editor.dart';
import 'package:modusnote/notes/note_store.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import 'harness.dart';

final now = DateTime.utc(2026, 10, 13, 17);
final chapter = EntryId('c' * 32);
final hero = EntryId('e' * 32);
final draft = EntryId('d' * 32);

DynamicEntry quickNote(EntryId id, String content) =>
    switch (DynamicEntry.create(
      schema: SeedSchemas.quickNoteV1,
      id: id,
      attributes: {FieldKey('content'): TextValue(content)},
      at: now.subtract(const Duration(days: 1)),
    )) {
      Valid(:final value) => value,
      Invalid(:final violations) => throw StateError('$violations'),
    };

void main() {
  late InMemoryNoteStore store;

  setUp(() async {
    store = InMemoryNoteStore();
    await store.save(
      quickNote(chapter, 'Capitolo uno\n\nArriva ${link('Marta', hero)}.'),
    );
    await store.save(quickNote(hero, 'Marta, la protagonista'));
  });

  Future<void> open(WidgetTester tester, DynamicEntry? entry) async {
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
                    store: store,
                    entry: entry,
                    initialSchema: SeedSchemas.quickNoteV1,
                    clock: () => now,
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
  }

  MarkdownEditingController controllerOf(WidgetTester tester) =>
      tester.widget<EditableText>(textInput('content').first).controller
          as MarkdownEditingController;

  DynamicEntry note(EntryId id) =>
      store.entries.firstWhere((entry) => entry.id == id);

  testWidgets('the toolbar links the selected words to a picked note', (
    tester,
  ) async {
    await open(tester, null);
    await tester.enterText(textInput('content'), 'Rileggere il capitolo');
    final controller = controllerOf(tester)
      ..selection = const TextSelection(baseOffset: 13, extentOffset: 21);
    await tester.pump();

    await tester.tap(find.byTooltip('Collega una nota'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('note-picker-search')),
      'capitolo',
    );
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('pick-note-${hero.value}')), findsNothing);
    await tester.tap(find.byKey(ValueKey('pick-note-${chapter.value}')));
    await tester.pumpAndSettle();

    expect(controller.text, 'Rileggere il ${link('capitolo', chapter)}');
    expect(find.text('Collegamenti'), findsOneWidget);
    expect(find.byKey(ValueKey('link-${chapter.value}')), findsOneWidget);
  });

  testWidgets('with nothing selected the link reads the note title', (
    tester,
  ) async {
    await open(tester, null);
    await tester.enterText(textInput('content'), 'Vedi ');

    await tester.tap(find.byTooltip('Collega una nota'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('pick-note-${hero.value}')));
    await tester.pumpAndSettle();

    expect(
      controllerOf(tester).text,
      'Vedi ${link('Marta, la protagonista', hero)}',
    );
  });

  testWidgets('a note shows where it is mentioned, and opens it', (
    tester,
  ) async {
    await open(tester, note(hero));

    expect(find.text('Citata in'), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('backlink-${chapter.value}')));
    await tester.pumpAndSettle();

    expect(
      find.byType(NoteEditorScreen, skipOffstage: false),
      findsNWidgets(2),
    );
    expect(find.textContaining('Capitolo uno'), findsWidgets);
    // From the chapter, the link leads back to Marta.
    expect(find.byKey(ValueKey('link-${hero.value}')), findsOneWidget);
  });

  testWidgets('a link to a note that is gone stays, greyed', (tester) async {
    await store.moveToTrash(hero);

    await open(tester, note(chapter));

    expect(find.text('Nota non disponibile'), findsOneWidget);
    final tile = tester.widget<ListTile>(
      find.byKey(ValueKey('link-${hero.value}')),
    );
    expect(tile.enabled, isFalse);
  });

  testWidgets('a note without links shows no section', (tester) async {
    await store.save(quickNote(draft, 'Solo testo'));

    await open(tester, note(draft));

    expect(find.text('Collegamenti'), findsNothing);
    expect(find.text('Citata in'), findsNothing);
  });

  test('the command replaces the selection and puts the cursor after', () {
    const value = TextEditingValue(
      text: 'a b c',
      selection: TextSelection(baseOffset: 2, extentOffset: 3),
    );

    final next = MarkdownCommands.noteLink(
      value,
      title: 'Titolo',
      target: hero,
    );

    expect(next.text, 'a ${link('b', hero)} c');
    expect(next.selection.baseOffset, next.text.length - 2);
  });

  test('a card shows a link as its words only', () {
    expect(
      MarkdownDocument.parse('Arriva ${link('Marta', hero)}.').plainText,
      'Arriva Marta.',
    );
  });
}

String link(String label, EntryId target) => NoteLinks.markdown(label, target);
