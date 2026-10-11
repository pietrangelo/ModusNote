import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modusnote/notes/dynamic_form_renderer.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import 'harness.dart';

final items = FieldKey('items');

Finder rows() => find.descendant(
  of: fieldFinder('items'),
  matching: find.byType(EditableText),
);

void main() {
  late List<FormDraft> drafts;
  setUp(() => drafts = []);

  Future<void> render(
    WidgetTester tester, {
    Map<FieldKey, FieldValue> values = const {},
  }) => pumpApp(
    tester,
    Scaffold(
      body: SingleChildScrollView(
        child: DynamicFormRenderer(
          schema: SeedSchemas.taskV2,
          values: values,
          onChanged: drafts.add,
        ),
      ),
    ),
  );

  ChecklistValue? reported() => drafts.last.values[items] as ChecklistValue?;

  Future<void> enter(WidgetTester tester) async {
    await tester.testTextInput.receiveAction(TextInputAction.next);
    await tester.pumpAndSettle();
  }

  EditableText focused(WidgetTester tester) => tester
      .widgetList<EditableText>(rows())
      .singleWhere((row) => row.focusNode.hasFocus);

  testWidgets('Enter adds a task; Enter on an empty one ends the list', (
    tester,
  ) async {
    await render(tester);
    expect(rows(), findsOneWidget);

    await tester.enterText(rows().first, 'latte');
    await enter(tester);
    expect(rows(), findsNWidgets(2));
    expect(focused(tester).controller.text, isEmpty);

    tester.testTextInput.enterText('pane');
    await tester.pump();
    await enter(tester);
    expect(rows(), findsNWidgets(3));

    await enter(tester); // On the new, empty task.

    expect(rows(), findsNWidgets(2));
    expect(
      tester.widgetList<EditableText>(rows()).any((r) => r.focusNode.hasFocus),
      isFalse,
    );
    expect(
      reported(),
      ChecklistValue([
        const ChecklistItem('latte'),
        const ChecklistItem('pane'),
      ]),
    );
  });

  testWidgets('Enter in the middle adds the task right below', (tester) async {
    await render(
      tester,
      values: {
        items: ChecklistValue([
          const ChecklistItem('uno'),
          const ChecklistItem('tre'),
        ]),
      },
    );

    await tester.showKeyboard(rows().first);
    await enter(tester);
    tester.testTextInput.enterText('due');
    await tester.pump();

    expect(reported()!.items.map((i) => i.text), ['uno', 'due', 'tre']);
  });

  testWidgets('ticking a task marks it done and counts it', (tester) async {
    await render(
      tester,
      values: {
        items: ChecklistValue([
          const ChecklistItem('latte'),
          const ChecklistItem('pane'),
        ]),
      },
    );
    expect(find.text('0/2'), findsOneWidget);

    await tester.tap(find.byType(Checkbox).first);
    await tester.pump();

    expect(reported()!.items.first.done, isTrue);
    expect(find.text('1/2'), findsOneWidget);
  });

  testWidgets('a task can be removed', (tester) async {
    await render(
      tester,
      values: {
        items: ChecklistValue([
          const ChecklistItem('latte'),
          const ChecklistItem('pane'),
        ]),
      },
    );

    await tester.tap(find.byTooltip('Rimuovi il task').first);
    await tester.pumpAndSettle();

    expect(reported(), ChecklistValue([const ChecklistItem('pane')]));
    expect(find.byTooltip('Rimuovi il task'), findsNothing); // The last stays.
  });

  testWidgets('"Add a task" continues a list that was ended', (tester) async {
    await render(
      tester,
      values: {
        items: ChecklistValue([const ChecklistItem('latte')]),
      },
    );

    await tester.tap(find.text('Aggiungi un task'));
    await tester.pumpAndSettle();
    expect(rows(), findsNWidgets(2));
    expect(focused(tester).controller.text, isEmpty);

    // Asking again while the new task is still empty adds nothing.
    await tester.tap(find.text('Aggiungi un task'));
    await tester.pumpAndSettle();
    expect(rows(), findsNWidgets(2));
  });

  group('adversary', () {
    testWidgets('empty and blank tasks never reach the value', (tester) async {
      await render(tester);

      await tester.enterText(rows().first, '   ');
      expect(drafts.last.values.containsKey(items), isFalse);

      await enter(tester); // Blank counts as empty: the list ends.
      expect(rows(), findsOneWidget);
    });

    testWidgets('a pasted line break cannot split or hide inside a task', (
      tester,
    ) async {
      await render(tester);

      await tester.enterText(rows().first, 'uno\ndue');

      final text = reported()!.items.single.text;
      expect(text, isNot(contains('\n')));
    });

    testWidgets('a long list stays usable on a phone', (tester) async {
      await render(
        tester,
        values: {
          items: ChecklistValue([
            for (var i = 0; i < 200; i++)
              ChecklistItem('task $i ${'x' * 80}', done: i.isEven),
          ]),
        },
      );

      expect(tester.takeException(), isNull);
      expect(find.text('100/200'), findsOneWidget);
    });
  });
}
