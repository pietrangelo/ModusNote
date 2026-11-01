import 'dart:convert';
import 'dart:io';

import 'package:publishing/publishing.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

void main() {
  final recipe = SeedSchemas.recipeV1;
  BlobId blob(String c) => BlobId(c * 32);
  MediaId copy(String c) => MediaId(c * 22);
  final cover = blob('a');
  final second = blob('b');
  final stepPicture = blob('c');
  final notUploaded = blob('d');
  final clip = blob('e');
  final uploaded = {
    cover: copy('A'),
    second: copy('B'),
    stepPicture: copy('C'),
    clip: copy('E'),
  };

  final values = <String, FieldValue>{
    'title': const TextValue('Parmigiana'),
    'description': TextValue(
      'Melanzane fritte, *sugo* e basilico.\n\n'
      '![il piatto](image:${cover.value})',
    ),
    'photos': AttachmentsValue([
      ImageAttachment(cover, caption: 'La teglia'),
      ImageAttachment(notUploaded),
      ImageAttachment(second),
      WebLink('https://example.org/storia', title: 'La storia'),
    ]),
    'servings': NumberValue(4),
    'ingredients': IngredientsValue([
      Ingredient(
        'Melanzane',
        amount: 1.5,
        unit: IngredientUnit.kilogram,
        link: WebLink('https://example.org/melanzane'),
      ),
      Ingredient(
        'Olio',
        amount: 2,
        unit: IngredientUnit.tablespoon,
        quantity: 'abbondanti',
      ),
      Ingredient('Uova', amount: 3),
      Ingredient('Sale', quantity: 'q.b.'),
    ]),
    'steps': StepsValue([
      PreparationStep(
        'Friggi le melanzane.',
        pictures: [
          ImageAttachment(stepPicture, caption: 'Dorate'),
          ImageAttachment(notUploaded),
        ],
      ),
      PreparationStep('Inforna a 180°.', video: clip),
    ]),
    'prep_time': NumberValue(40),
    'cook_time': NumberValue(45),
    'rest_time': NumberValue(0),
    'methods': ChoiceSetValue({'stovetop', 'oven'}),
    'oven_temperature': NumberValue(180),
    'difficulty': const RatingValue(2),
    'tags': TagListValue({'estate', 'vegetariana'}),
  };

  final words = RecipeWords(
    unit: (unit, count) => switch (unit) {
      IngredientUnit.kilogram => 'kg',
      IngredientUnit.tablespoon => count == 1 ? 'cucchiaio' : 'cucchiai',
      _ => unit.name,
    },
    option: (field, option) => switch (option) {
      'oven' => 'Forno',
      'stovetop' => 'Fornelli',
      _ => option,
    },
    category: 'Secondi',
  );

  PageDocument compose({
    Set<String>? fields,
    PublicationLayout? layout = PublicationLayout.recipe,
    bool listed = true,
  }) {
    final content = PublicationPolicy.compose(
      entry: entry(recipe, values),
      schema: recipe,
      fields: keys(fields ?? values.keys),
    );
    return PageComposer.compose(
      content: content,
      schema: recipe,
      media: uploaded,
      labelOf: labelOf,
      describe: describe,
      recipeWords: words,
      listed: listed,
      layout: layout,
    );
  }

  test('a recipe note starts with the recipe layout', () {
    expect(PublicationLayout.forSchemaName('recipe'), PublicationLayout.recipe);
    expect(PublicationLayout.recipe.columns, [Golden.minor, Golden.major]);
    expect(PublicationLayout.recipe.coverAspect, Golden.phi);
  });

  test('the recipe travels structured, as serv.pub takes it', () {
    final page = compose();
    final json = page.toJson();
    expect(json['layout'], 'recipe');
    final r = json['recipe']! as Map<String, Object>;
    expect(r['category'], 'Secondi');
    expect(r['servings'], 4);
    expect((r['prep'], r['cook'], r['rest']), (40, 45, 0));
    expect(r['difficulty'], 2);
    // In the type's order, in the person's language.
    expect(r['methods'], ['Forno', 'Fornelli']);
    expect(r['tags'], ['estate', 'vegetariana']);
    // Only uploaded pictures; the first is the cover.
    expect(r['cover'], [
      {'media': copy('A').value, 'caption': 'La teglia'},
      {'media': copy('B').value, 'caption': ''},
    ]);
    // The site shows the description as text: no picture in it.
    expect(r['description'], startsWith('Melanzane fritte, *sugo*'));
    expect(r['description'], isNot(contains('image:')));
    expect(r['description'], contains('il piatto'));
    expect(jsonDecode(jsonEncode(json)), json);
  });

  test('amounts stay numbers, with both names of their unit', () {
    final r = compose().recipe!;
    final [melanzane, olio, uova, sale] = r.ingredients;
    expect(melanzane.toJson(), {
      'name': 'Melanzane',
      'amount': 1.5,
      'unit': 'kilogram',
      'one': 'kg',
      'other': 'kg',
      'quantity': '',
      'link': 'https://example.org/melanzane',
    });
    expect(
      (olio.one, olio.other, olio.quantity),
      ('cucchiaio', 'cucchiai', 'abbondanti'),
    );
    // Counted things have no unit, so no names.
    expect(uova.toJson(), {
      'name': 'Uova',
      'amount': 3,
      'one': '',
      'other': '',
      'quantity': '',
    });
    expect(sale.link, isNull);
    expect(sale.amount, isNull);
  });

  test('steps keep their text and their uploaded pictures', () {
    final page = compose();
    final steps = page.recipe!.steps;
    expect(steps.map((s) => s.text), [
      'Friggi le melanzane.',
      'Inforna a 180°.',
    ]);
    expect(steps.first.pictures.map((p) => p.media), [copy('C')]);
    expect(steps.first.pictures.single.caption, 'Dorate');
    expect(steps.last.video, copy('E'));
    expect(steps.first.video, isNull);
    expect(page.media, [copy('A'), copy('B'), copy('C'), copy('E')]);
  });

  test('the other fields stay blocks, the links among the photos too', () {
    final blocks = compose().blocks;
    expect(blocks.map((b) => b.label), [
      'schema.recipe.field.photos',
      'schema.recipe.field.oven_temperature',
    ]);
    final links = blocks.first as LinksBlock;
    expect(links.items.single.url, 'https://example.org/storia');
    expect((blocks.last as TextBlock).text, '180');
  });

  test('without pictures, a step\'s video stays home too', () {
    final content = PublicationPolicy.compose(
      entry: entry(recipe, values),
      schema: recipe,
      fields: keys(values.keys),
      includePictures: false,
    );
    expect(content.videos, isEmpty);
    expect(content.images, isEmpty);
    expect(
      PublicationPolicy.compose(
        entry: entry(recipe, values),
        schema: recipe,
        fields: keys(values.keys),
      ).videos,
      [clip],
    );
  });

  test('only the fields the person chose', () {
    final page = compose(fields: {'title', 'ingredients'});
    final r = page.recipe!;
    expect(r.ingredients, hasLength(4));
    expect(r.steps, isEmpty);
    expect(r.cover, isEmpty);
    expect(r.servings, isNull);
    expect(r.description, isEmpty);
    expect(page.blocks, isEmpty);
    // A recipe with nothing but its name is still a page of the cookbook.
    expect(compose(fields: {'title'}).recipe, isNotNull);
  });

  test('without the recipe layout it is an ordinary page', () {
    final page = compose(layout: PublicationLayout.goldenCover);
    expect(page.recipe, isNull);
    expect(page.toJson().containsKey('recipe'), isFalse);
    expect(page.blocks, isNotEmpty);
  });

  test('only a recipe takes the recipe layout', () {
    final memo = schema('memo', [field('body', const MarkdownFieldType())]);
    final values = {'body': const TextValue('ciao')};
    expect(
      () => PageComposer.compose(
        content: PublicationPolicy.compose(
          entry: entry(memo, values),
          schema: memo,
          fields: keys(values.keys),
        ),
        schema: memo,
        media: const {},
        labelOf: labelOf,
        describe: describe,
        listed: true,
        layout: PublicationLayout.recipe,
      ),
      throwsA(isA<NotPublishableException>()),
    );
    expect(
      () => PageDocument(
        title: 'x',
        layout: PublicationLayout.recipe,
        listed: true,
        blocks: const [],
      ),
      throwsA(isA<NotPublishableException>()),
    );
  });

  test('without the person\'s words, the wire\'s own names', () {
    final many = <String, FieldValue>{
      'title': const TextValue('Tanto'),
      'ingredients': IngredientsValue([
        Ingredient('Olio', amount: 2, unit: IngredientUnit.tablespoon),
      ]),
      'methods': ChoiceSetValue({'oven'}),
    };
    final page = PageComposer.compose(
      content: PublicationPolicy.compose(
        entry: entry(recipe, many),
        schema: recipe,
        fields: keys(many.keys),
      ),
      schema: recipe,
      media: uploaded,
      labelOf: labelOf,
      describe: describe,
      listed: true,
      layout: PublicationLayout.recipe,
    );
    final r = page.recipe!;
    expect(r.ingredients.single.one, 'tablespoon');
    expect(r.methods, ['oven']);
    expect(r.category, isEmpty);
  });

  // The same page is read by serv.pub's own tests
  // (server/crates/publish/tests/app_pages.rs): the two sides agree on
  // the wire. UPDATE_FIXTURES=1 writes it anew.
  test('serv.pub reads the page as the app writes it', () {
    final fixture = File(
      '../../server/crates/publish/tests/fixtures/app_recipe.json',
    );
    final json = const JsonEncoder.withIndent('  ').convert(compose().toJson());
    if (Platform.environment['UPDATE_FIXTURES'] == '1') {
      fixture.writeAsStringSync('$json\n');
    }
    expect(fixture.readAsStringSync(), '$json\n');
  });

  test('the cookbook\'s address is never a page\'s', () {
    expect(PageSlug('ricette').isReserved, isTrue);
    expect(PageSlug.fromTitle('Ricette').freeAmong({}), PageSlug('ricette-2'));
    expect(PageSlug('ricetta').freeAmong({}), PageSlug('ricetta'));
    expect(
      SiteBook(
        name: SiteName('cucina'),
        settings: SiteSettings(title: 'Cucina', lang: 'it'),
      ).cookbookUrl.toString(),
      'https://serv.pub/cucina/ricette',
    );
  });
}
