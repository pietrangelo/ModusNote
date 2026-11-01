import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modusnote/notes/recipes/cooking_mode.dart';
import 'package:modusnote/notes/recipes/shopping_list.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import 'harness.dart';

final at = DateTime.utc(2026, 11, 1, 9);

DynamicEntry recipe({bool withServings = true}) => switch (DynamicEntry.create(
  schema: SeedSchemas.recipeV1,
  id: EntryId('r' * 32),
  attributes: {
    FieldKey('title'): const TextValue('Pane'),
    if (withServings) FieldKey('servings'): NumberValue(2),
    FieldKey('ingredients'): IngredientsValue([
      Ingredient('Farina', amount: 500, unit: IngredientUnit.gram),
      Ingredient('Sale', quantity: 'q.b.'),
      Ingredient('Lievito', amount: 1, unit: IngredientUnit.teaspoon),
    ]),
    FieldKey('steps'): StepsValue([
      PreparationStep('Impasta e lascia lievitare **2 ore**.'),
      PreparationStep('Inforna per 40 minuti.'),
    ]),
  },
  at: at,
)) {
  Valid(:final value) => value,
  Invalid(:final violations) => throw StateError('$violations'),
};

void main() {
  group('StepTimer', () {
    test('reads the first time a step names', () {
      expect(StepTimer.minutesIn('Inforna per 40 minuti.'), 40);
      expect(StepTimer.minutesIn('lascia lievitare 2 ore'), 120);
      expect(StepTimer.minutesIn('Bake 25 min, then 5 more'), 25);
      expect(StepTimer.minutesIn('Rest for 1 hour'), 60);
      expect(StepTimer.minutesIn('1 minuto'), 1);
    });

    test('guesses nothing from a bare number or an absurd time', () {
      expect(StepTimer.minutesIn('Usa 3 uova'), isNull);
      expect(StepTimer.minutesIn('a 180 gradi'), isNull);
      expect(StepTimer.minutesIn('0 minuti'), isNull);
      expect(StepTimer.minutesIn('48 ore'), isNull);
      expect(StepTimer.minutesIn('10 minestre'), isNull);
    });
  });

  group('ShoppingList', () {
    test('is a to-do list, one task per line', () {
      final list = ShoppingList.of(
        id: EntryId('s' * 32),
        title: 'Spesa: Pane',
        lines: ['500 g Farina', '1 cucchiaino Lievito'],
        at: at,
      )!;

      expect(list.schemaId, SeedSchemas.taskV2.id);
      expect(
        list.attributes[FieldKey('title')],
        const TextValue('Spesa: Pane'),
      );
      expect(
        list.attributes[FieldKey('items')],
        ChecklistValue([
          const ChecklistItem('500 g Farina'),
          const ChecklistItem('1 cucchiaino Lievito'),
        ]),
      );
    });

    test('cuts what would not fit, and is nothing without lines', () {
      final list = ShoppingList.of(
        id: EntryId('s' * 32),
        title: 'S' * 300,
        lines: ['a' * 600, '  ', 'b\u202Ec'],
        at: at,
      )!;
      final title = list.attributes[FieldKey('title')]! as TextValue;
      final items = list.attributes[FieldKey('items')]! as ChecklistValue;

      expect(title.text.length, 200);
      expect(items.items.map((i) => i.text), ['a' * 500, 'b c']);
      expect(
        ShoppingList.of(
          id: EntryId('s' * 32),
          title: 'x',
          lines: const [' '],
          at: at,
        ),
        isNull,
      );
    });
  });

  group('cooking mode', () {
    late List<List<String>> shopped;
    setUp(() => shopped = []);

    Future<void> open(WidgetTester tester, {DynamicEntry? entry}) => pumpApp(
      tester,
      CookingModeScreen(
        entry: entry ?? recipe(),
        title: 'Pane',
        openImage: (_) async => Uint8List(0),
        onShopping: (lines) async => shopped.add(lines),
      ),
    );

    testWidgets('scales the ingredients to the servings chosen', (
      tester,
    ) async {
      await open(tester);
      expect(find.text('2 porzioni'), findsOneWidget);
      expect(find.text('500 g Farina'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('servings-more')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('servings-more')));
      await tester.pump();

      expect(find.text('4 porzioni'), findsOneWidget);
      expect(find.text('1000 g Farina'), findsOneWidget);
      expect(find.text('2 cucchiaini Lievito'), findsOneWidget);
      expect(find.text('q.b. Sale'), findsOneWidget);
    });

    testWidgets('the shopping list leaves out what is ticked', (tester) async {
      await open(tester);

      await tester.tap(find.byKey(const ValueKey('have-0')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('add-to-shopping')));
      await tester.pump();

      expect(shopped, [
        ['q.b. Sale', '1 cucchiaino Lievito'],
      ]);
      expect(
        find.text('Lista della spesa creata con 2 ingredienti'),
        findsOneWidget,
      );
    });

    testWidgets('with everything ticked there is nothing to buy', (
      tester,
    ) async {
      await open(tester);
      for (var i = 0; i < 3; i++) {
        await tester.tap(find.byKey(ValueKey('have-$i')));
        await tester.pump();
      }
      await tester.tap(find.byKey(const ValueKey('add-to-shopping')));
      await tester.pump();

      expect(shopped, isEmpty);
      expect(find.text('Hai già tutto'), findsOneWidget);
    });

    testWidgets('shows one step a page, with the time it names', (
      tester,
    ) async {
      await open(tester);

      await tester.tap(find.byKey(const ValueKey('cooking-next')));
      await tester.pumpAndSettle();
      expect(find.text('Fase 1 di 2'), findsOneWidget);
      expect(find.text('Timer 2 h'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('cooking-next')));
      await tester.pumpAndSettle();
      expect(find.text('Fase 2 di 2'), findsOneWidget);
      expect(find.text('Timer 40 min'), findsOneWidget);
      expect(find.text('Fatto'), findsOneWidget);
    });

    testWidgets('a timer counts down and says when time is up', (tester) async {
      await open(tester);
      await tester.tap(find.byKey(const ValueKey('cooking-next')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('cooking-next')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('step-timer-1')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('timer-minutes')), '1');
      await tester.tap(find.text('Avvia'));
      await tester.pumpAndSettle();
      expect(find.text('1:00'), findsOneWidget);

      await tester.pump(const Duration(seconds: 1));
      expect(find.text('0:59'), findsOneWidget);
      await tester.pump(const Duration(seconds: 59));
      await tester.pump();
      expect(find.byKey(const ValueKey('timer-running')), findsNothing);
      expect(find.text('Tempo scaduto'), findsOneWidget);
    });

    testWidgets('without servings the amounts are as written', (tester) async {
      await open(tester, entry: recipe(withServings: false));

      expect(find.byKey(const ValueKey('servings')), findsNothing);
      expect(find.text('500 g Farina'), findsOneWidget);
    });
  });
}
