import 'dart:convert';

import 'package:schema_dynamic_content/schema_dynamic_content.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

final photo = BlobId('a' * 32);
final stepPhoto = BlobId('b' * 32);
final otherPhoto = BlobId('c' * 32);

WebLink link(String url) => WebLink.parse(url)!;

DynamicEntry recipe(Map<String, FieldValue> attributes) => valueOf(
  DynamicEntry.create(
    schema: SeedSchemas.recipeV1,
    id: EntryId('r' * 32),
    attributes: {
      FieldKey('title'): const TextValue('Melanzane alla parmigiana'),
      for (final MapEntry(:key, :value) in attributes.entries)
        FieldKey(key): value,
    },
    at: at,
  ),
);

void main() {
  group('Ingredient', () {
    test('holds a name, an amount with its unit, words and a link', () {
      final flour = Ingredient(
        'Farina 00',
        amount: 250,
        unit: IngredientUnit.gram,
        link: link('https://example.org/farina'),
      );

      expect(flour.name, 'Farina 00');
      expect((flour.amount, flour.unit), (250, IngredientUnit.gram));
      expect(flour.link!.host, 'example.org');
      expect(Ingredient('Sale', quantity: 'q.b.').quantity, 'q.b.');
    });

    test('a unit needs an amount, and an amount is finite and positive', () {
      expect(
        () => Ingredient('Sale', unit: IngredientUnit.gram),
        throwsA(isA<InvalidValueException>()),
      );
      for (final amount in [0, -1, double.nan, double.infinity, 1e7]) {
        expect(
          () => Ingredient('Sale', amount: amount),
          throwsA(isA<InvalidValueException>()),
          reason: '$amount',
        );
      }
      expect(Ingredient('Uova', amount: 2).unit, isNull);
    });

    test('compares by every part', () {
      expect(Ingredient('Uova', amount: 2), Ingredient('Uova', amount: 2));
      expect(
        Ingredient('Uova', amount: 2),
        isNot(Ingredient('Uova', amount: 3)),
      );
      expect(
        Ingredient('Latte', amount: 1, unit: IngredientUnit.litre),
        isNot(Ingredient('Latte', amount: 1, unit: IngredientUnit.cup)),
      );
    });
  });

  group('IngredientsFieldType', () {
    final type = IngredientsFieldType(maxItems: 2);

    test('accepts a list of ingredients and nothing else', () {
      expect(type.check(IngredientsValue([Ingredient('Uova')])), isEmpty);
      expect(type.check(const TextValue('uova')), [ViolationCode.typeMismatch]);
    });

    test('rejects an empty list, too many items and blank names', () {
      expect(type.check(IngredientsValue(const [])), [
        ViolationCode.missingRequired,
      ]);
      expect(
        type.check(
          IngredientsValue([Ingredient('a'), Ingredient('b'), Ingredient('c')]),
        ),
        [ViolationCode.tooManyItems],
      );
      expect(type.check(IngredientsValue([Ingredient('  ')])), [
        ViolationCode.emptyItem,
      ]);
    });

    test('names and words are one safe line of bounded length', () {
      expect(type.check(IngredientsValue([Ingredient('a' * 201)])), [
        ViolationCode.tooLong,
      ]);
      expect(
        type.check(IngredientsValue([Ingredient('Sale', quantity: 'q' * 81)])),
        [ViolationCode.tooLong],
      );
      expect(type.check(IngredientsValue([Ingredient('Sale\u202E')])), [
        ViolationCode.invalidCharacters,
      ]);
      expect(type.check(IngredientsValue([Ingredient('Sale\nPepe')])), [
        ViolationCode.invalidCharacters,
      ]);
    });

    test('a link to buy an ingredient must be https', () {
      expect(
        type.check(
          IngredientsValue([
            Ingredient('Farina', link: link('http://example.org')),
          ]),
        ),
        [ViolationCode.invalidUrl],
      );
    });
  });

  group('StepsFieldType', () {
    final type = StepsFieldType(maxItems: 2);

    test('accepts steps with text, pictures or both', () {
      expect(
        type.check(
          StepsValue([
            PreparationStep('Taglia le melanzane.'),
            PreparationStep('', pictures: [ImageAttachment(stepPhoto)]),
          ]),
        ),
        isEmpty,
      );
      expect(type.check(const TextValue('x')), [ViolationCode.typeMismatch]);
    });

    test('rejects empty lists, empty steps and too many steps', () {
      expect(type.check(StepsValue(const [])), [ViolationCode.missingRequired]);
      expect(type.check(StepsValue([PreparationStep(' \n ')])), [
        ViolationCode.emptyItem,
      ]);
      expect(
        type.check(
          StepsValue([
            PreparationStep('a'),
            PreparationStep('b'),
            PreparationStep('c'),
          ]),
        ),
        [ViolationCode.tooManyItems],
      );
    });

    test('bounds the text and the pictures of each step and of all steps', () {
      expect(
        type.check(
          StepsValue([PreparationStep('a' * (StepsFieldType.maxText + 1))]),
        ),
        [ViolationCode.tooLong],
      );
      final many = [
        for (var i = 0; i <= StepsFieldType.maxPicturesPerStep; i++)
          ImageAttachment(BlobId('p$i'.padRight(32, '0'))),
      ];
      expect(type.check(StepsValue([PreparationStep('a', pictures: many)])), [
        ViolationCode.tooManyItems,
      ]);
      final roomy = StepsFieldType(maxItems: StepsFieldType.maxAllowedItems);
      final steps = [
        for (var s = 0; s < 12; s++)
          PreparationStep(
            's$s',
            pictures: [
              for (var i = 0; i < StepsFieldType.maxPicturesPerStep; i++)
                ImageAttachment(BlobId('s${s}p$i'.padRight(32, '0'))),
            ],
          ),
      ];
      expect(roomy.check(StepsValue(steps)), [ViolationCode.tooManyItems]);
    });

    test('a picture appears once across all the steps', () {
      expect(
        type.check(
          StepsValue([
            PreparationStep('a', pictures: [ImageAttachment(stepPhoto)]),
            PreparationStep('b', pictures: [ImageAttachment(stepPhoto)]),
          ]),
        ),
        [ViolationCode.duplicateItem],
      );
    });
  });

  group('ChoiceSetFieldType', () {
    final type = ChoiceSetFieldType(['oven', 'steam', 'grill']);

    test('accepts any non-empty subset of its options', () {
      expect(type.check(ChoiceSetValue({'oven', 'grill'})), isEmpty);
      expect(type.check(ChoiceSetValue(const {})), [
        ViolationCode.missingRequired,
      ]);
      expect(type.check(ChoiceSetValue({'oven', 'fryer'})), [
        ViolationCode.invalidChoice,
      ]);
      expect(type.check(const ChoiceValue('oven')), [
        ViolationCode.typeMismatch,
      ]);
    });

    test('values compare as sets', () {
      expect(ChoiceSetValue({'a', 'b'}), ChoiceSetValue({'b', 'a'}));
      expect(ChoiceSetValue({'a'}), isNot(ChoiceSetValue({'a', 'b'})));
    });

    test('options are identifiers, unique, at least one', () {
      for (final options in [
        <String>[],
        ['a', 'a'],
        ['Forno'],
      ]) {
        expect(
          () => ChoiceSetFieldType(options),
          throwsA(isA<InvalidSchemaException>()),
          reason: '$options',
        );
      }
    });
  });

  group('the recipe type', () {
    final full = recipe({
      'description': const TextValue('Il piatto della domenica.'),
      'photos': AttachmentsValue([ImageAttachment(photo, caption: 'Pronta')]),
      'servings': NumberValue(4),
      'ingredients': IngredientsValue([
        Ingredient(
          'Melanzane',
          amount: 1.2,
          unit: IngredientUnit.kilogram,
          link: link('https://example.org/melanzane'),
        ),
        Ingredient('Uova', amount: 3),
        Ingredient('Sale', quantity: 'q.b.'),
      ]),
      'steps': StepsValue([
        PreparationStep(
          'Friggi le **melanzane**.',
          pictures: [ImageAttachment(stepPhoto, caption: 'Dorate')],
        ),
        PreparationStep('Inforna per 40 minuti.'),
      ]),
      'prep_time': NumberValue(30),
      'cook_time': NumberValue(60),
      'rest_time': NumberValue(15),
      'methods': ChoiceSetValue({'oven', 'stovetop'}),
      'oven_temperature': NumberValue(180),
      'oven_mode': const ChoiceValue('fan'),
      'difficulty': const RatingValue(2),
      'tags': TagListValue({'domenica'}),
    });

    test('is offered with the other seed types', () {
      expect(SeedSchemas.all, contains(SeedSchemas.recipeV1));
      expect(SeedSchemas.recipeV1.icon, NoteIcon.recipe);
      expect(SeedSchemas.recipeV1.tint, NoteTint.sage);
      expect(Recipe.isRecipe(full), isTrue);
    });

    test('only the name is required', () {
      expect(Recipe.isRecipe(recipe(const {})), isTrue);
    });

    test('survives the entry codec unchanged', () {
      final back = valueOf(
        EntryCodec.decode(
          EntryCodec.encode(full),
          schemas: SeedSchemas.catalog.schemaFor,
        ),
      );

      expect(back.attributes, full.attributes);
    });

    test('survives the schema codec unchanged', () {
      expect(
        SchemaCodec.decode(SchemaCodec.encode(SeedSchemas.recipeV1)),
        SeedSchemas.recipeV1,
      );
    });

    test('its pictures are the photos and the pictures of the steps', () {
      expect(InlineImages.picturesOf(full), [photo, stepPhoto]);
    });

    test('search finds ingredients, steps, captions and methods', () {
      for (final query in ['melanzane', 'uova', 'inforna', 'dorate', 'oven']) {
        expect(EntrySearch(query).matches(full), isTrue, reason: query);
      }
      expect(EntrySearch('example.org').matches(full), isFalse);
    });

    test('adds up the times it states', () {
      expect(Recipe.totalMinutes(full), 105);
      expect(Recipe.totalMinutes(recipe({'cook_time': NumberValue(20)})), 20);
      expect(Recipe.totalMinutes(recipe(const {})), isNull);
    });

    test('reads its servings, ingredients and steps', () {
      expect(Recipe.servingsOf(full), 4);
      expect(Recipe.ingredientsOf(full), hasLength(3));
      expect(Recipe.stepsOf(full), hasLength(2));
      expect(Recipe.servingsOf(recipe(const {})), isNull);
      expect(Recipe.ingredientsOf(recipe(const {})), isEmpty);
    });
  });

  group('scaling to other servings', () {
    Ingredient scaled(Ingredient i, int from, int to) =>
        Recipe.scale([i], from: from, to: to).single;

    test('multiplies the amounts and keeps the rest', () {
      final flour = Ingredient(
        'Farina',
        amount: 250,
        unit: IngredientUnit.gram,
        link: link('https://example.org'),
      );

      final doubled = scaled(flour, 4, 8);
      expect((doubled.amount, doubled.unit), (500, IngredientUnit.gram));
      expect(doubled.link, flour.link);
      expect(
        scaled(Ingredient('Sale', quantity: 'q.b.'), 4, 8).quantity,
        'q.b.',
      );
      expect(scaled(Ingredient('Sale'), 4, 8).amount, isNull);
    });

    test('rounds to amounts a cook can measure', () {
      // 250 g for 4 is 62.5 g for 1: whole grams.
      expect(
        scaled(
          Ingredient('a', amount: 250, unit: IngredientUnit.gram),
          4,
          1,
        ).amount,
        63,
      );
      // Above 100 g, steps of 5 g.
      expect(
        scaled(
          Ingredient('a', amount: 333, unit: IngredientUnit.gram),
          3,
          4,
        ).amount,
        445,
      );
      // Under 10 g, tenths.
      expect(
        scaled(
          Ingredient('a', amount: 7, unit: IngredientUnit.gram),
          3,
          1,
        ).amount,
        2.3,
      );
      // Eggs and cloves by halves, never less than half.
      expect(scaled(Ingredient('Uova', amount: 3), 4, 2).amount, 1.5);
      expect(scaled(Ingredient('Uova', amount: 1), 4, 1).amount, 0.5);
      // Spoons and cups by quarters.
      expect(
        scaled(
          Ingredient('a', amount: 1, unit: IngredientUnit.tablespoon),
          4,
          6,
        ).amount,
        1.5,
      );
      expect(
        scaled(
          Ingredient('a', amount: 1, unit: IngredientUnit.cup),
          3,
          1,
        ).amount,
        0.25,
      );
    });

    test('the same servings change nothing', () {
      final odd = Ingredient('a', amount: 333.3, unit: IngredientUnit.gram);
      expect(scaled(odd, 4, 4), odd);
    });

    test('servings are whole and positive', () {
      expect(
        () => Recipe.scale([Ingredient('a')], from: 0, to: 2),
        throwsArgumentError,
      );
      expect(
        () => Recipe.scale([Ingredient('a')], from: 2, to: 0),
        throwsArgumentError,
      );
    });
  });

  group('hostile recipe records', () {
    Map<String, Object?> jsonOf(DynamicEntry entry) =>
        jsonDecode(utf8.decode(EntryCodec.encode(entry)))
            as Map<String, Object?>;

    Object? decodeWith(String field, Object? value) {
      final json = jsonOf(recipe(const {}));
      (json['attributes']! as Map<String, Object?>)[field] = value;
      return EntryCodec.decode(
        utf8.encode(jsonEncode(json)),
        schemas: SeedSchemas.catalog.schemaFor,
      );
    }

    void refuses(String field, Object? value) => expect(
      () => decodeWith(field, value),
      throwsA(isA<EntryFormatException>()),
      reason: jsonEncode(value),
    );

    test('malformed ingredients are a format error', () {
      for (final item in [
        ['Sale'],
        ['Sale', null, null, '', null, 'extra'],
        ['Sale', 'due', null, '', null],
        ['Sale', -1, null, '', null],
        ['Sale', null, 'gram', '', null],
        ['Sale', 1, 'barrel', '', null],
        ['Sale', 1, null, '', 'javascript:alert(1)'],
        ['Sale', 1, null, 7, null],
        'Sale',
      ]) {
        refuses('ingredients', {
          'kind': 'ingredients',
          'value': [item],
        });
      }
    });

    test('malformed steps are a format error', () {
      for (final step in [
        <Object?>[],
        ['Taglia', 'b' * 32],
        ['Taglia', 7, ''],
        ['Taglia', 'not a blob id!', ''],
        [7],
      ]) {
        refuses('steps', {
          'kind': 'steps',
          'value': [step],
        });
      }
    });

    test('a set of options holds each once', () {
      refuses('methods', {
        'kind': 'choice_set',
        'value': ['oven', 'oven'],
      });
    });

    test('well-formed but invalid values are violations, not errors', () {
      final http = decodeWith('ingredients', {
        'kind': 'ingredients',
        'value': [
          ['Farina', null, null, '', 'http://example.org'],
        ],
      });
      expect(codesOf(http! as Validated<DynamicEntry>), [
        ViolationCode.invalidUrl,
      ]);
      final unknown = decodeWith('methods', {
        'kind': 'choice_set',
        'value': ['teleport'],
      });
      expect(codesOf(unknown! as Validated<DynamicEntry>), [
        ViolationCode.invalidChoice,
      ]);
    });
  });
}
