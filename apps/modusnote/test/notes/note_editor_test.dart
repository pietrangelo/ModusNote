import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modusnote/notes/editor/markdown_controller.dart';
import 'package:modusnote/notes/note_editor.dart';
import 'package:modusnote/notes/note_store.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import 'harness.dart';

final now = DateTime.utc(2026, 10, 11, 14);

DynamicEntry existing(
  SchemaDefinition schema,
  Map<String, FieldValue> attributes,
) => switch (DynamicEntry.create(
  schema: schema,
  id: EntryId('0123456789abcdef0123456789abcdef'),
  attributes: {for (final e in attributes.entries) FieldKey(e.key): e.value},
  at: now.subtract(const Duration(days: 1)),
)) {
  Valid(:final value) => value,
  Invalid(:final violations) => throw StateError('$violations'),
};

void main() {
  late InMemoryNoteStore store;

  setUp(() => store = InMemoryNoteStore());

  /// The editor pushed over a page, so that leaving it can be tested.
  Future<void> open(
    WidgetTester tester, {
    DynamicEntry? entry,
    SchemaDefinition? schema,
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
                    store: store,
                    entry: entry,
                    initialSchema: schema ?? SeedSchemas.quickNoteV1,
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

  Future<void> pause(WidgetTester tester) async {
    await tester.pump(NoteEditorScreen.autosaveDelay);
    await tester.pumpAndSettle();
  }

  Future<void> back(WidgetTester tester) async {
    await tester.pump();
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
  }

  final saved = find.byKey(const ValueKey('save-state'));
  String? state(WidgetTester tester) =>
      saved.evaluate().isEmpty ? null : tester.widget<Text>(saved).data;

  group('saving', () {
    testWidgets('typing saves the note a moment later, with no button', (
      tester,
    ) async {
      await open(tester);

      await tester.enterText(textInput('content'), 'Idea per il ponte');
      expect(store.entries, isEmpty);
      await pause(tester);

      final entry = store.entries.single;
      expect(
        entry.valueOf(FieldKey('content')),
        const TextValue('Idea per il ponte'),
      );
      expect(entry.audit.createdAt, now);
      expect(entry.id.value, matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(state(tester), 'Salvata');
      expect(find.text('Salva'), findsNothing);
    });

    testWidgets('each pause saves the same note again', (tester) async {
      await open(tester);

      await tester.enterText(textInput('content'), 'uno');
      await pause(tester);
      await tester.enterText(textInput('content'), 'uno e due');
      await pause(tester);

      final entry = store.entries.single;
      expect(entry.valueOf(FieldKey('content')), const TextValue('uno e due'));
      expect(entry.audit.revision, 2);
    });

    testWidgets('leaving saves what is pending at once', (tester) async {
      await open(tester);

      await tester.enterText(textInput('content'), 'appena scritto');
      await back(tester);

      expect(find.byType(NoteEditorScreen), findsNothing);
      expect(
        store.entries.single.valueOf(FieldKey('content')),
        const TextValue('appena scritto'),
      );
    });

    testWidgets('going to the background saves at once', (tester) async {
      await open(tester);

      await tester.enterText(textInput('content'), 'prima di uscire');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await tester.pump();

      expect(store.entries, hasLength(1));
      tester.binding
        ..handleAppLifecycleStateChanged(AppLifecycleState.inactive)
        ..handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    });

    testWidgets('an empty new note is never saved', (tester) async {
      await open(tester);

      await tester.enterText(textInput('content'), 'x');
      await tester.enterText(textInput('content'), '');
      await back(tester);

      expect(find.byType(NoteEditorScreen), findsNothing);
      expect(store.entries, isEmpty);
    });

    testWidgets('a missing required field stops saving, and leaving asks', (
      tester,
    ) async {
      await open(tester, schema: SeedSchemas.dreamLogV1);

      await tester.enterText(textInput('title'), 'Volavo');
      await pause(tester);
      expect(store.entries, isEmpty);
      expect(state(tester), 'Non salvata: mancano dei campi');

      await back(tester);
      expect(find.text('Questa nota non si può ancora salvare'), findsOne);
      await tester.tap(find.text('Continua a scrivere'));
      await tester.pumpAndSettle();
      expect(find.byType(NoteEditorScreen), findsOneWidget);
      expect(
        find.descendant(
          of: fieldFinder('dream_date'),
          matching: find.text('Obbligatorio'),
        ),
        findsOneWidget,
      );

      await back(tester);
      await tester.tap(find.text('Scarta'));
      await tester.pumpAndSettle();
      expect(find.byType(NoteEditorScreen), findsNothing);
      expect(store.entries, isEmpty);
    });

    testWidgets('an unreadable number blocks saving and is flagged', (
      tester,
    ) async {
      await open(tester, schema: SeedSchemas.songSketchV1);

      await tester.enterText(textInput('title'), 'Riff');
      await tester.enterText(textInput('bpm'), 'veloce');
      await pause(tester);
      expect(store.entries, isEmpty);

      await back(tester);
      await tester.tap(find.text('Continua a scrivere'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: fieldFinder('bpm'),
          matching: find.text('Valore non valido'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('editing an existing note updates it', (tester) async {
      final original = existing(SeedSchemas.quickNoteV1, {
        'content': const TextValue('Prima'),
      });
      await store.save(original);
      await open(tester, entry: original);

      expect(find.byKey(const ValueKey('note-type')), findsNothing);
      await tester.enterText(textInput('content'), 'Dopo');
      await pause(tester);

      final updated = store.entries.single;
      expect(updated.id, original.id);
      expect(updated.valueOf(FieldKey('content')), const TextValue('Dopo'));
      expect(updated.audit.revision, 2);
      expect(updated.audit.updatedAt, now);
    });
  });

  group('type', () {
    testWidgets('switching type while writing keeps what fits', (tester) async {
      await open(tester);

      await tester.enterText(textInput('content'), 'Comprare corde');
      await tester.tap(find.byKey(const ValueKey('note-type')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('To-do').last);
      await tester.pumpAndSettle();

      expect(fieldFinder('items'), findsOneWidget);
      expect(fieldFinder('content'), findsNothing);
      expect(find.text('Comprare corde'), findsOneWidget);
      await tester.enterText(
        find
            .descendant(
              of: fieldFinder('items'),
              matching: find.byType(EditableText),
            )
            .first,
        'Mi',
      );
      await pause(tester);
      expect(store.entries.single.schemaId, SeedSchemas.taskV2.id);
    });

    testWidgets('the type menu is announced as a button', (tester) async {
      final semantics = tester.ensureSemantics();
      await open(tester);

      expect(
        tester.getSemantics(find.byKey(const ValueKey('note-type'))),
        isSemantics(
          isButton: true,
          isHeader: false,
          tooltip: 'Tipo di nota',
          hasTapAction: true,
        ),
      );
      semantics.dispose();
    });

    testWidgets('the type is fixed once the note is saved', (tester) async {
      await open(tester);

      await tester.enterText(textInput('content'), 'testo');
      await pause(tester);

      expect(find.byKey(const ValueKey('note-type')), findsNothing);
    });
  });

  group('page', () {
    testWidgets('the title is large; other fields fold under it', (
      tester,
    ) async {
      final song = existing(SeedSchemas.songSketchV1, {
        'title': const TextValue('Notturno'),
        'bpm': NumberValue(90),
      });
      await store.save(song);
      await open(tester, entry: song, schema: SeedSchemas.songSketchV1);

      final title = tester.widget<EditableText>(textInput('title'));
      expect(title.style.fontSize, 26);
      expect(fieldFinder('bpm'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('details-toggle')));
      await tester.pumpAndSettle();
      expect(fieldFinder('bpm'), findsOneWidget);
    });

    testWidgets('a new note shows its details, to be filled in', (
      tester,
    ) async {
      await open(tester, schema: SeedSchemas.dreamLogV1);

      expect(fieldFinder('dream_date'), findsOneWidget);
    });
  });

  group('Markdown', () {
    MarkdownEditingController controllerOf(WidgetTester tester) =>
        tester.widget<EditableText>(textInput('content')).controller
            as MarkdownEditingController;

    testWidgets('it is rendered as it is typed, in the same field', (
      tester,
    ) async {
      await open(tester);

      await tester.enterText(textInput('content'), '# Titolo\n**forte**');
      await tester.pump();

      final controller = controllerOf(tester);
      final span = controller.buildTextSpan(
        context: tester.element(textInput('content')),
        style: const TextStyle(fontSize: 16),
        withComposing: false,
      );
      TextStyle? styleOf(String part) => (span.children!.cast<TextSpan>())
          .firstWhere((child) => child.text == part)
          .style;
      expect(styleOf('forte')?.fontWeight, FontWeight.w700);
      expect(styleOf('Titolo')?.fontSize, 26);
      // Styles are kept between calls, but not past a change of the base.
      final larger = controller.buildTextSpan(
        context: tester.element(textInput('content')),
        style: const TextStyle(fontSize: 20),
        withComposing: false,
      );
      expect(
        (larger.children!.cast<TextSpan>())
            .firstWhere((child) => child.text == 'forte')
            .style
            ?.fontSize,
        20,
      );
      // The source stays what is edited and saved.
      expect(controller.text, '# Titolo\n**forte**');
    });

    testWidgets('the toolbar formats the selection', (tester) async {
      await open(tester);
      await tester.enterText(textInput('content'), 'riff');
      final controller = controllerOf(tester);
      controller.selection = const TextSelection(
        baseOffset: 0,
        extentOffset: 4,
      );

      await tester.tap(find.byTooltip('Grassetto (Ctrl+B)'));
      await pause(tester);

      expect(controller.text, '**riff**');
      expect(
        store.entries.single.valueOf(FieldKey('content')),
        const TextValue('**riff**'),
      );
    });

    testWidgets('keyboard shortcuts format too', (tester) async {
      await open(tester);
      await tester.enterText(textInput('content'), 'riff');
      final controller = controllerOf(tester)
        ..selection = const TextSelection(baseOffset: 0, extentOffset: 4);
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyI);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      expect(controller.text, '_riff_');
    });

    testWidgets('Enter in a list starts the next item', (tester) async {
      await open(tester);

      await tester.enterText(textInput('content'), '- uno');
      await tester.enterText(textInput('content'), '- uno\n');

      expect(controllerOf(tester).text, '- uno\n- ');
    });

    testWidgets('a type without Markdown has no toolbar', (tester) async {
      await open(tester, schema: SeedSchemas.dreamLogV1);

      expect(find.byTooltip('Grassetto (Ctrl+B)'), findsNothing);
    });
  });

  group('focus mode', () {
    final focus = find.byKey(const ValueKey('focus-mode'));
    final song = existing(SeedSchemas.songSketchV1, {
      'title': const TextValue('Notturno'),
      'bpm': NumberValue(90),
      'lyrics': const TextValue('Prima strofa'),
    });

    testWidgets('leaves only the title and the text, toolbar included', (
      tester,
    ) async {
      await open(tester, entry: song, schema: SeedSchemas.songSketchV1);
      await tester.tap(find.byKey(const ValueKey('details-toggle')));
      await tester.pumpAndSettle();
      expect(fieldFinder('bpm'), findsOneWidget);

      await tester.tap(focus);
      await tester.pumpAndSettle();

      expect(fieldFinder('title'), findsOneWidget);
      expect(fieldFinder('lyrics'), findsOneWidget);
      expect(fieldFinder('bpm'), findsNothing);
      expect(fieldFinder('guide_track'), findsNothing);
      expect(find.byKey(const ValueKey('note-type')), findsNothing);
      expect(find.byType(BackButton), findsNothing);

      await tester.tap(focus);
      await tester.pumpAndSettle();
      expect(fieldFinder('bpm'), findsOneWidget, reason: 'details stay open');
    });

    testWidgets('a quick note keeps its text but loses the toolbar', (
      tester,
    ) async {
      await open(tester);
      await tester.enterText(textInput('content'), 'riff');
      await tester.pump();
      expect(find.byTooltip('Grassetto (Ctrl+B)'), findsOneWidget);

      await tester.tap(focus);
      await tester.pumpAndSettle();

      expect(find.byTooltip('Grassetto (Ctrl+B)'), findsNothing);
      expect(find.text('riff'), findsOneWidget);
    });

    testWidgets('back leaves focus mode before the page', (tester) async {
      await open(tester, entry: song, schema: SeedSchemas.songSketchV1);
      await tester.tap(focus);
      await tester.pumpAndSettle();

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(find.byType(NoteEditorScreen), findsOneWidget);
      expect(find.byType(BackButton), findsOneWidget);

      await back(tester);
      expect(find.byType(NoteEditorScreen), findsNothing);
    });

    testWidgets('Ctrl+Shift+F and Escape, from the text', (tester) async {
      await open(tester, entry: song, schema: SeedSchemas.songSketchV1);
      await tester.tap(textInput('lyrics'));
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(find.byType(BackButton), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(BackButton), findsOneWidget);
    });
  });
}
