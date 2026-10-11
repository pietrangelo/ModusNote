import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modusnote/notes/note_editor.dart';
import 'package:modusnote/notes/note_library.dart';
import 'package:modusnote/notes/note_store.dart';
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

void main() {
  late InMemoryNoteStore store;

  setUp(() async {
    store = InMemoryNoteStore();
    await store.save(
      entry('s', SeedSchemas.songSketchV1, {
        'title': const TextValue('Notturno in La'),
      }, 1),
    );
    await store.save(
      entry('t', SeedSchemas.taskV1, {
        'description': const TextValue('Accordare la chitarra'),
        'completed': const BooleanValue(false),
      }, 2),
    );
    await store.save(
      entry('n', SeedSchemas.quickNoteV1, {
        'content': const TextValue('Idea per un riff'),
        'tags': TagListValue({'chitarra'}),
      }, 3),
    );
  });

  Future<void> open(WidgetTester tester) => pumpApp(
    tester,
    NoteLibraryScreen(schemas: SeedSchemas.all, store: store),
  );

  testWidgets('lists every note, newest first, with its type', (tester) async {
    await open(tester);

    final riff = tester.getTopLeft(find.text('Idea per un riff'));
    final song = tester.getTopLeft(find.text('Notturno in La'));
    expect(riff.dy, lessThanOrEqualTo(song.dy));
    expect(find.text('Canzone'), findsWidgets);
    expect(find.text('Accordare la chitarra'), findsOneWidget);
  });

  testWidgets('search matches text and tags without accents', (tester) async {
    await open(tester);

    await tester.enterText(find.byType(TextField), 'chitarra');
    await tester.pumpAndSettle();

    expect(find.text('Accordare la chitarra'), findsOneWidget);
    expect(find.text('Idea per un riff'), findsOneWidget);
    expect(find.text('Notturno in La'), findsNothing);
  });

  testWidgets('a type chip shows only notes of that type', (tester) async {
    await open(tester);

    await tester.tap(find.widgetWithText(ChoiceChip, 'Attività'));
    await tester.pumpAndSettle();

    expect(find.text('Accordare la chitarra'), findsOneWidget);
    expect(find.text('Idea per un riff'), findsNothing);
  });

  testWidgets('says so when the search finds nothing', (tester) async {
    await open(tester);

    await tester.enterText(find.byType(TextField), 'sassofono');
    await tester.pumpAndSettle();

    expect(find.text('Nessuna nota corrisponde alla ricerca.'), findsOneWidget);
  });

  testWidgets('an empty library invites to write the first note', (
    tester,
  ) async {
    store = InMemoryNoteStore();
    await open(tester);

    expect(find.textContaining('Ancora nessuna nota'), findsOneWidget);
  });

  testWidgets('new note opens the editor on the filtered type', (tester) async {
    await open(tester);

    await tester.tap(find.widgetWithText(ChoiceChip, 'Sogno'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Nuova nota'));
    await tester.pumpAndSettle();

    expect(find.byType(NoteEditorScreen), findsOneWidget);
    expect(fieldFinder('dream_date'), findsOneWidget);
  });

  testWidgets('saving in the editor shows the note in the list', (
    tester,
  ) async {
    store = InMemoryNoteStore();
    await open(tester);

    await tester.tap(find.text('Nuova nota'));
    await tester.pumpAndSettle();
    await tester.enterText(textInput('content'), 'Nota appena scritta');
    await tester.tap(find.text('Salva'));
    await tester.pumpAndSettle();

    expect(find.byType(NoteEditorScreen), findsNothing);
    expect(find.text('Nota appena scritta'), findsOneWidget);
  });

  testWidgets('cards keep the golden proportion φ : 1', (tester) async {
    await open(tester);

    final card = tester.getSize(find.byType(Card).first);
    expect(card.width / card.height, closeTo(1.618, 0.01));
  });
}
