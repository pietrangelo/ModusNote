import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modusnote/notes/note_appearance.dart';
import 'package:modusnote/notes/note_editor.dart';
import 'package:modusnote/notes/note_library.dart';
import 'package:modusnote/notes/note_store.dart';
import 'package:modusnote/theme/modus_colors.dart';
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
      entry('t', SeedSchemas.taskV2, {
        'items': ChecklistValue([const ChecklistItem('Accordare la chitarra')]),
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
    // Tall enough for every card to be laid out at once.
    tester.view.physicalSize = const Size(1080, 4680);
    await tester.pumpAndSettle();

    final riff = tester.getTopLeft(find.text('Idea per un riff'));
    final song = tester.getTopLeft(find.text('Notturno in La'));
    expect(riff.dy, lessThanOrEqualTo(song.dy));
    expect(find.text('Canzone'), findsWidgets);
    expect(find.text('Accordare la chitarra'), findsOneWidget);
  });

  testWidgets('a Markdown title shows its words, not its markup', (
    tester,
  ) async {
    await store.save(
      entry('m', SeedSchemas.quickNoteV1, {
        'content': const TextValue('# Spesa **oggi**\n\n- [ ] latte'),
      }, 4),
    );

    await open(tester);

    expect(find.text('Spesa oggi\nlatte'), findsOneWidget);
  });

  testWidgets('each card wears its type\'s icon and colour', (tester) async {
    await open(tester);
    Finder cardOf(String text) =>
        find.ancestor(of: find.text(text), matching: find.byType(Card));

    final icon = tester.widget<Icon>(
      find.descendant(
        of: cardOf('Accordare la chitarra'),
        matching: find.byIcon(Icons.checklist),
      ),
    );
    expect(icon.color, ModusColors.cadenceCyan);
    for (final (text, tint) in [
      ('Accordare la chitarra', NoteTint.cyan),
      ('Notturno in La', NoteTint.violet),
      ('Idea per un riff', NoteTint.gold),
    ]) {
      expect(
        tester.widget<Card>(cardOf(text)).color,
        NoteAppearance.wash(tint),
        reason: text,
      );
    }
  });

  testWidgets('a list card counts what is done; an untitled one is named '
      'by what is left', (tester) async {
    await store.save(
      entry('l', SeedSchemas.taskV2, {
        'items': ChecklistValue([
          const ChecklistItem('latte', done: true),
          const ChecklistItem('pane'),
          const ChecklistItem('uova'),
        ]),
      }, 5),
    );

    await open(tester);

    expect(find.text('pane, uova'), findsOneWidget);
    expect(find.text('1/3'), findsOneWidget);
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

    await tester.tap(find.widgetWithText(ChoiceChip, 'To-do'));
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
    await tester.pump();
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    expect(find.byType(NoteEditorScreen), findsNothing);
    expect(find.text('Nota appena scritta'), findsOneWidget);
  });

  testWidgets('a long title shows only whole lines, ending in an ellipsis', (
    tester,
  ) async {
    await store.save(
      entry('l', SeedSchemas.quickNoteV1, {
        'content': const TextValue(
          'questo è il testo di una nota abbastanza lunga da non entrare '
          'nella card della libreria',
        ),
      }, 9),
    );

    // A small phone and a Pixel 7 Pro, at the system's text sizes.
    for (final (width, scale) in [
      for (final width in [360.0, 412.0])
        for (final scale in [1.0, 1.15, 1.3, 2.0]) (width, scale),
    ]) {
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await open(tester);
      tester.view.physicalSize = Size(width * 3, 2340);
      await tester.pumpAndSettle();

      final title = tester.renderObject<RenderParagraph>(
        find.textContaining('questo è il testo'),
      );
      final lines = title.getBoxesForSelection(
        TextSelection(
          baseOffset: 0,
          extentOffset: title.text.toPlainText().length,
        ),
      );
      expect(lines, isNotEmpty, reason: '$width dp, scale $scale');
      for (final line in lines) {
        expect(
          line.bottom,
          lessThanOrEqualTo(title.size.height + 0.5),
          reason: 'a line cut in half at $width dp, scale $scale',
        );
      }
      expect(
        title.didExceedMaxLines,
        isTrue,
        reason: '$width dp, scale $scale',
      );
    }
  });

  testWidgets('cards keep the golden proportion φ : 1', (tester) async {
    await open(tester);

    final card = tester.getSize(find.byType(Card).first);
    expect(card.width / card.height, closeTo(1.618, 0.01));
  });
}
