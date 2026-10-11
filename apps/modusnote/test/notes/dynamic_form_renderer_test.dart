import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modusnote/notes/dynamic_form_renderer.dart';
import 'package:modusnote/notes/markdown/markdown_view.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import 'harness.dart';

FieldKey k(String key) => FieldKey(key);

void main() {
  late List<FormDraft> drafts;
  setUp(() => drafts = []);

  Future<void> render(
    WidgetTester tester,
    SchemaDefinition schema, {
    Map<FieldKey, FieldValue> values = const {},
    List<Violation> violations = const [],
    Locale locale = const Locale('it'),
  }) => pumpApp(
    tester,
    Scaffold(
      body: SingleChildScrollView(
        child: DynamicFormRenderer(
          schema: schema,
          values: values,
          violations: violations,
          onChanged: drafts.add,
        ),
      ),
    ),
    locale: locale,
  );

  testWidgets('renders one input per field with localized labels', (
    tester,
  ) async {
    await render(tester, SeedSchemas.songSketchV1);

    for (final field in SeedSchemas.songSketchV1.fields) {
      expect(fieldFinder(field.key.value), findsOneWidget);
    }
    expect(find.text('Titolo'), findsOneWidget);
    expect(find.text('Tonalità'), findsOneWidget);
    expect(find.text('Traccia guida'), findsOneWidget);
  });

  testWidgets('each of the four templates renders in both languages', (
    tester,
  ) async {
    for (final locale in const [Locale('it'), Locale('en')]) {
      for (final schema in SeedSchemas.all) {
        await render(tester, schema, locale: locale);
        expect(tester.takeException(), isNull);
        expect(find.byType(DynamicFormRenderer), findsOneWidget);
      }
    }
  });

  testWidgets('typing text reports a TextValue, clearing removes it', (
    tester,
  ) async {
    await render(tester, SeedSchemas.songSketchV1);

    await tester.enterText(textInput('title'), 'Notturno');
    expect(drafts.last.values[k('title')], const TextValue('Notturno'));

    await tester.enterText(textInput('title'), '');
    expect(drafts.last.values.containsKey(k('title')), isFalse);
  });

  testWidgets('numbers parse with either decimal separator', (tester) async {
    await render(tester, SeedSchemas.songSketchV1);

    await tester.enterText(textInput('bpm'), '96');
    expect(drafts.last.values[k('bpm')], NumberValue(96));
    expect(drafts.last.unreadable, isEmpty);

    await tester.enterText(textInput('bpm'), '96,5');
    expect(drafts.last.values[k('bpm')], NumberValue(96.5));
  });

  testWidgets('a number that does not parse is reported, not guessed', (
    tester,
  ) async {
    await render(tester, SeedSchemas.songSketchV1);

    await tester.enterText(textInput('bpm'), 'veloce');

    expect(drafts.last.values.containsKey(k('bpm')), isFalse);
    expect(drafts.last.unreadable, {k('bpm')});
  });

  testWidgets('a checkbox reports a BooleanValue', (tester) async {
    await render(tester, SeedSchemas.taskV1);

    await tester.tap(
      find.descendant(
        of: fieldFinder('completed'),
        matching: find.byType(Checkbox),
      ),
    );

    expect(drafts.last.values[k('completed')], const BooleanValue(true));
  });

  testWidgets('tapping the third star rates 3, tapping it again clears', (
    tester,
  ) async {
    await render(tester, SeedSchemas.dreamLogV1);
    final third = find.byTooltip('3 su 5');

    await tester.tap(third);
    expect(drafts.last.values[k('lucidity')], const RatingValue(3));

    await tester.pump();
    await tester.tap(third);
    expect(drafts.last.values.containsKey(k('lucidity')), isFalse);
  });

  testWidgets('a choice shows localized options and reports the identifier', (
    tester,
  ) async {
    await render(tester, SeedSchemas.taskV1);

    await tester.tap(
      find.descendant(
        of: fieldFinder('priority'),
        matching: find.byType(DropdownButton<String>),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Urgente').last);
    await tester.pumpAndSettle();

    expect(drafts.last.values[k('priority')], const ChoiceValue('urgent'));
  });

  testWidgets('tags are added on submit and removed with their chip', (
    tester,
  ) async {
    await render(tester, SeedSchemas.quickNoteV1);

    await tester.enterText(textInput('tags'), 'idee');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(drafts.last.values[k('tags')], TagListValue({'idee'}));

    await tester.tap(find.byTooltip('Rimuovi idee'));
    await tester.pump();
    expect(drafts.last.values.containsKey(k('tags')), isFalse);
  });

  testWidgets('initial values are shown', (tester) async {
    await render(
      tester,
      SeedSchemas.taskV1,
      values: {
        k('description'): const TextValue('Chiamare Ada'),
        k('priority'): const ChoiceValue('high'),
      },
    );

    expect(find.text('Chiamare Ada'), findsOneWidget);
    expect(find.text('Alta'), findsOneWidget);
  });

  testWidgets('violations appear, localized, under their field', (
    tester,
  ) async {
    await render(
      tester,
      SeedSchemas.taskV1,
      violations: [
        Violation(ViolationCode.missingRequired, k('description')),
        Violation(ViolationCode.invalidChoice, k('priority')),
      ],
    );

    expect(
      find.descendant(
        of: fieldFinder('description'),
        matching: find.text('Obbligatorio'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: fieldFinder('priority'),
        matching: find.text('Non è tra le opzioni'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('the order follows the schema UI hints when present', (
    tester,
  ) async {
    final schema = SchemaDefinition(
      id: SchemaId('ordered', 1),
      label: Label.literal('Ordinata'),
      fields: [
        FieldDefinition(
          key: k('first'),
          label: Label.literal('Primo'),
          type: TextFieldType(),
        ),
        FieldDefinition(
          key: k('second'),
          label: Label.literal('Secondo'),
          type: TextFieldType(),
        ),
      ],
      uiHints: [
        WidgetPlacement(field: k('second'), section: 'main', order: 0),
        WidgetPlacement(field: k('first'), section: 'main', order: 1),
      ],
    );

    await render(tester, schema);

    expect(
      tester.getTopLeft(find.text('Secondo')).dy,
      lessThan(tester.getTopLeft(find.text('Primo')).dy),
    );
  });

  group('Markdown', () {
    testWidgets('a new note opens on the text, a written one on the preview', (
      tester,
    ) async {
      await render(tester, SeedSchemas.quickNoteV1);
      expect(textInput('content'), findsOneWidget);
      expect(find.byKey(const ValueKey('markdown-preview')), findsNothing);

      await tester.pumpWidget(const SizedBox()); // A new editor.
      await render(
        tester,
        SeedSchemas.quickNoteV1,
        values: {k('content'): const TextValue('# Spesa\n\n- [x] pane')},
      );
      expect(textInput('content'), findsNothing);
      expect(find.text('Spesa'), findsOneWidget);
      expect(find.byKey(const ValueKey('task-done')), findsOneWidget);
    });

    testWidgets('the preview shows what was just typed, and back', (
      tester,
    ) async {
      await render(tester, SeedSchemas.quickNoteV1);

      await tester.enterText(textInput('content'), '**forte**');
      await tester.tap(find.text('Anteprima'));
      await tester.pumpAndSettle();
      expect(find.text('forte'), findsOneWidget);
      expect(textInput('content'), findsNothing);

      await tester.tap(find.text('Scrivi'));
      await tester.pumpAndSettle();
      expect(find.text('**forte**'), findsOneWidget);
      expect(drafts.last.values[k('content')], const TextValue('**forte**'));
    });

    testWidgets('an empty preview says so', (tester) async {
      await render(tester, SeedSchemas.quickNoteV1);

      await tester.tap(find.text('Anteprima'));
      await tester.pumpAndSettle();

      expect(find.text('Niente da mostrare.'), findsOneWidget);
    });
  });

  group('adversary', () {
    testWidgets('hostile text is shown as plain text, never interpreted', (
      tester,
    ) async {
      const hostile =
          '<script>alert(1)</script> [x](javascript:alert(1)) **b** \u202Egnp.exe';
      await render(
        tester,
        SeedSchemas.quickNoteV1,
        values: {k('content'): const TextValue(hostile)},
      );

      expect(tester.takeException(), isNull);
      // The preview shows the tags as text and the link with its address.
      final preview = tester.widget<RichText>(
        find.descendant(
          of: find.byType(MarkdownView),
          matching: find.byType(RichText),
        ),
      );
      expect(
        preview.text.toPlainText(),
        '<script>alert(1)</script> x (javascript:alert(1)) b \u202Egnp.exe',
      );
      expect(find.byType(InkWell), findsNWidgets(2)); // The two tabs only.

      await tester.tap(find.text('Scrivi'));
      await tester.pumpAndSettle();
      expect(find.text(hostile), findsOneWidget);
    });

    testWidgets('a very long text renders without overflow', (tester) async {
      await render(
        tester,
        SeedSchemas.quickNoteV1,
        values: {k('content'): TextValue('lorem ipsum ' * 5000)},
      );

      expect(tester.takeException(), isNull);
    });

    testWidgets('a value of the wrong type for its field is ignored', (
      tester,
    ) async {
      await render(
        tester,
        SeedSchemas.taskV1,
        values: {
          k('completed'): const TextValue('yes'),
          k('priority'): const ChoiceValue('not_an_option'),
          k('due'): NumberValue(3),
        },
      );

      expect(tester.takeException(), isNull);
    });
  });
}
