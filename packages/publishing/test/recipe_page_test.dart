import 'package:publishing/publishing.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

void main() {
  final recipe = schema('recipe', [
    field('title', TextFieldType(maxLength: 200)),
    field('ingredients', IngredientsFieldType()),
    field('steps', StepsFieldType()),
    field('methods', ChoiceSetFieldType(['oven', 'steam'])),
  ]);
  final cover = BlobId('0123456789abcdef0123456789abcdef');
  final step = BlobId('fedcba9876543210fedcba9876543210');
  final private = BlobId('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa');
  final stepCopy = MediaId('AAAAAAAAAAAAAAAAAAAAAA');

  final values = {
    'title': const TextValue('Pane'),
    'ingredients': IngredientsValue([
      Ingredient(
        'Farina *00* [fine]',
        amount: 500,
        unit: IngredientUnit.gram,
        link: WebLink('https://example.org/farina?a=(1)'),
      ),
      Ingredient('Sale', quantity: 'q.b.'),
    ]),
    'steps': StepsValue([
      PreparationStep(
        'Impasta come in [la nota](note:${'n' * 32}).\n'
        'Poi ![segreta](image:${private.value}).',
        pictures: [ImageAttachment(step, caption: 'Impasto [liscio]')],
      ),
      PreparationStep('Inforna.'),
    ]),
    'methods': ChoiceSetValue({'oven'}),
  };

  PublicationContent content({bool pictures = true}) =>
      PublicationPolicy.compose(
        entry: entry(recipe, values),
        schema: recipe,
        fields: keys(values.keys),
        includePictures: pictures,
      );

  PageDocument page(PublicationContent content) => PageComposer.compose(
    content: content,
    schema: recipe,
    media: {step: stepCopy},
    labelOf: labelOf,
    describe: describe,
    ingredientLine: (item) => switch (item.amount) {
      final n? => '$n g ${item.name}',
      null => '${item.name}, ${item.quantity}',
    },
    listed: true,
  );

  test('the pictures of the steps are uploaded with the page', () {
    expect(content().images, [step]);
    expect(content(pictures: false).images, isEmpty);
  });

  test('a step loses links to private notes and pictures not offered', () {
    final steps = content().fields[FieldKey('steps')]! as StepsValue;
    final text = steps.steps.first.text;
    expect(text, isNot(contains('note:n')));
    expect(text, contains('la nota'));
    final none = content(pictures: false).fields[FieldKey('steps')]!;
    expect((none as StepsValue).steps.first.pictures, isEmpty);
    expect(none.steps.first.text, isNot(contains('image:')));
  });

  test('ingredients become a list, with the shop shown by its site', () {
    final blocks = page(content()).blocks;
    final list = blocks.whereType<MarkdownBlock>().first;
    expect(list.label, 'ingredients');
    expect(list.text, contains(r'- 500 g Farina \*00\* \[fine\]'));
    expect(
      list.text,
      contains('[example.org](<https://example.org/farina?a=(1)>)'),
    );
    expect(list.text, contains('- Sale, q.b.'));
  });

  test('steps are numbered, with their uploaded pictures in place', () {
    final blocks = page(content()).blocks.whereType<MarkdownBlock>().toList();
    final steps = blocks[1];
    expect(steps.label, 'steps');
    expect(steps.text, startsWith('**1.** Impasta'));
    expect(steps.text, contains('![Impasto liscio](image:${stepCopy.value})'));
    expect(steps.text, contains('**2.** Inforna.'));
    // No id of the vault reaches the page, in any spelling.
    expect(steps.text, isNot(contains(private.value)));
    expect(steps.text, isNot(contains(step.value)));
    expect(steps.text, isNot(contains(cover.value)));
  });

  test('a step picture without an uploaded copy is left out', () {
    final doc = PageComposer.compose(
      content: content(),
      schema: recipe,
      media: const {},
      labelOf: labelOf,
      describe: describe,
      listed: true,
    );
    final steps = doc.blocks.whereType<MarkdownBlock>().last.text;
    expect(steps, isNot(contains('image:')));
    expect(steps, isNot(contains(step.value)));
  });

  test('without a way to write ingredients, their names are shown', () {
    final doc = PageComposer.compose(
      content: content(),
      schema: recipe,
      media: {step: stepCopy},
      labelOf: labelOf,
      describe: describe,
      listed: true,
    );
    expect(
      doc.blocks.whereType<MarkdownBlock>().first.text,
      startsWith(r'- Farina \*00\* \[fine\]'),
    );
  });
}
