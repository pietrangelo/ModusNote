import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modusnote/l10n/generated/app_localizations_en.dart';
import 'package:modusnote/l10n/generated/app_localizations_it.dart';
import 'package:modusnote/notes/attachments/attachments_input.dart';
import 'package:modusnote/notes/dynamic_form_renderer.dart';
import 'package:modusnote/notes/recipes/recipe_inputs.dart';
import 'package:modusnote/notes/recipes/recipe_text.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import 'harness.dart';

final ingredients = FieldKey('ingredients');
final steps = FieldKey('steps');
final methods = FieldKey('methods');
final picture = BlobId('p' * 32);

void main() {
  late List<FormDraft> drafts;
  setUp(() => drafts = []);

  Future<void> render(
    WidgetTester tester, {
    Map<FieldKey, FieldValue> values = const {},
    Future<BlobId?> Function()? addImage,
  }) => pumpApp(
    tester,
    Scaffold(
      body: SingleChildScrollView(
        child: DynamicFormRenderer(
          schema: SeedSchemas.recipeV1,
          values: {FieldKey('title'): const TextValue('Pane'), ...values},
          onChanged: drafts.add,
          attachments: AttachmentHooks(
            openImage: (_) async => Uint8List(0),
            openLink: (_) async => false,
            addImage: addImage,
          ),
        ),
      ),
    ),
    size: const Size(600, 4000),
  );

  Finder input(String name) => find.byKey(ValueKey(name));

  testWidgets('ingredients, steps and methods are on the page, not folded', (
    tester,
  ) async {
    await render(tester);

    expect(fieldFinder('ingredients'), findsOneWidget);
    expect(fieldFinder('steps'), findsOneWidget);
    expect(input('ingredient-name-0'), findsOneWidget);
    expect(input('step-text-0'), findsOneWidget);
  });

  testWidgets('an ingredient is written with its amount, unit and shop', (
    tester,
  ) async {
    await render(tester);

    await tester.enterText(input('ingredient-amount-0'), '1,5');
    await tester.enterText(input('ingredient-name-0'), 'Farina');
    await tester.enterText(
      input('ingredient-link-0'),
      'https://example.org/farina',
    );
    await tester.tap(input('ingredient-unit-0'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('kg').last);
    await tester.pumpAndSettle();

    expect(
      drafts.last.values[ingredients],
      IngredientsValue([
        Ingredient(
          'Farina',
          amount: 1.5,
          unit: IngredientUnit.kilogram,
          link: WebLink('https://example.org/farina'),
        ),
      ]),
    );
    expect(drafts.last.unreadable, isEmpty);
  });

  testWidgets('a bad amount or a link that is not https stops the save', (
    tester,
  ) async {
    await render(tester);

    await tester.enterText(input('ingredient-name-0'), 'Sale');
    await tester.enterText(input('ingredient-amount-0'), 'tanto');
    await tester.pump();
    expect(drafts.last.unreadable, {ingredients});
    expect(find.text('Non è un numero positivo'), findsOneWidget);

    await tester.enterText(input('ingredient-amount-0'), '');
    await tester.enterText(input('ingredient-link-0'), 'http://example.org');
    await tester.pump();
    expect(drafts.last.unreadable, {ingredients});
    expect(find.text('Solo indirizzi https'), findsOneWidget);

    await tester.enterText(input('ingredient-link-0'), '');
    await tester.pump();
    expect(drafts.last.unreadable, isEmpty);
    expect(
      drafts.last.values[ingredients],
      IngredientsValue([Ingredient('Sale')]),
    );
  });

  testWidgets('steps are added, moved and given pictures', (tester) async {
    await render(tester, addImage: () async => picture);

    await tester.enterText(input('step-text-0'), 'Impasta');
    await tester.tap(find.text('Aggiungi una fase'));
    await tester.pump();
    await tester.enterText(input('step-text-1'), 'Inforna');
    await tester.tap(input('step-add-picture-1'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Sposta su').last);
    await tester.pump();

    expect(
      drafts.last.values[steps],
      StepsValue([
        PreparationStep('Inforna', pictures: [ImageAttachment(picture)]),
        PreparationStep('Impasta'),
      ]),
    );
    expect(find.text('Fase 1'), findsOneWidget);
    expect(find.text('Fase 2'), findsOneWidget);
  });

  testWidgets('methods are chips to turn on and off', (tester) async {
    // A new recipe shows its details open.
    await render(tester);

    await tester.tap(input('choice-oven'));
    await tester.pump();
    await tester.tap(input('choice-steam'));
    await tester.pump();
    expect(drafts.last.values[methods], ChoiceSetValue({'oven', 'steam'}));

    await tester.tap(input('choice-oven'));
    await tester.pump();
    await tester.tap(input('choice-steam'));
    await tester.pump();
    expect(drafts.last.values.containsKey(methods), isFalse);
  });

  testWidgets('a saved recipe opens with its values', (tester) async {
    await render(
      tester,
      values: {
        ingredients: IngredientsValue([
          Ingredient('Uova', amount: 2),
          Ingredient('Sale', quantity: 'q.b.'),
        ]),
        steps: StepsValue([PreparationStep('Sbatti')]),
      },
    );

    expect(find.text('Uova'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(find.text('q.b.'), findsOneWidget);
    expect(find.text('Sbatti'), findsOneWidget);
  });

  group('RecipeText', () {
    final it = RecipeText(AppLocalizationsIt());
    final en = RecipeText(AppLocalizationsEn());

    test('writes amounts the local way, units by count', () {
      expect(
        it.line(
          Ingredient('Farina', amount: 1.5, unit: IngredientUnit.kilogram),
        ),
        '1,5 kg Farina',
      );
      expect(
        en.line(
          Ingredient('Flour', amount: 1.5, unit: IngredientUnit.kilogram),
        ),
        '1.5 kg Flour',
      );
      expect(
        it.line(Ingredient('Olio', amount: 2, unit: IngredientUnit.tablespoon)),
        '2 cucchiai Olio',
      );
      expect(
        it.line(Ingredient('Olio', amount: 1, unit: IngredientUnit.tablespoon)),
        '1 cucchiaio Olio',
      );
      expect(it.line(Ingredient('Uova', amount: 3)), '3 Uova');
      expect(it.line(Ingredient('Sale', quantity: 'q.b.')), 'q.b. Sale');
      expect(it.line(Ingredient('Pepe')), 'Pepe');
      expect(it.amount(1500), '1500');
    });

    test('writes times in minutes and hours', () {
      expect(it.minutes(45), '45 min');
      expect(it.minutes(120), '2 h');
      expect(it.minutes(75), '1 h 15 min');
    });
  });

  test('amounts are read with either decimal sign, and only positive', () {
    expect(IngredientsInput.parseAmount('1,5'), 1.5);
    expect(IngredientsInput.parseAmount(' 250 '), 250);
    expect(IngredientsInput.parseAmount('0.25'), 0.25);
    for (final bad in ['', '0', '-1', '1e3', 'tanto', '1,2,3', '99999999']) {
      expect(IngredientsInput.parseAmount(bad), isNull, reason: bad);
    }
  });
}
