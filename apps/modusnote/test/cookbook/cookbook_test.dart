import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import '../backup/markdown_export_test.dart' show unzipBytes;

import 'package:image/image.dart' as img;
import 'package:modusnote/cookbook/book_picture.dart';
import 'package:modusnote/cookbook/cookbook.dart';
import 'package:modusnote/cookbook/cookbook_epub.dart';
import 'package:modusnote/cookbook/cookbook_pages.dart';
import 'package:modusnote/cookbook/cookbook_pdf.dart';
import 'package:modusnote/cookbook/cookbook_words.dart';
import 'package:modusnote/l10n/generated/app_localizations_it.dart';
import 'package:modusnote/notes/recipes/recipe_text.dart';
import 'package:modusnote/notes/schema_text.dart';
import 'package:publishing/publishing.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

DynamicEntry recipe(String id, Map<String, FieldValue> attributes) =>
    switch (DynamicEntry.create(
      schema: SeedSchemas.recipeV1,
      id: EntryId(id.padRight(32, '0')),
      attributes: {
        for (final e in attributes.entries) FieldKey(e.key): e.value,
      },
      at: DateTime.utc(2026, 11, 1, 9),
    )) {
      Valid(:final value) => value,
      Invalid(:final violations) => throw StateError('$violations'),
    };

/// A plain JPEG of [width] × [height] in one colour.
Uint8List jpeg(int width, int height, int r, int g, int b) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(r, g, b));
  return img.encodeJpg(image, quality: 80);
}

final l10n = AppLocalizationsIt();

CookbookFonts fonts() {
  Uint8List read(String name) =>
      File('assets/fonts/book/$name').readAsBytesSync();
  return CookbookFonts(
    regular: read('Inter-Regular.ttf'),
    semiBold: read('Inter-SemiBold.ttf'),
    display: read('PlusJakartaSans-Bold.ttf'),
  );
}

void main() {
  final root = CategoryId('r' * 32);
  final primi = CategoryId('p' * 32);
  final dolci = CategoryId('d' * 32);
  final elsewhere = CategoryId('x' * 32);
  final tree = CategoryTree([
    NoteCategory(id: root, name: CategoryName('Cucina sarda')),
    NoteCategory(id: primi, name: CategoryName('Primi'), parent: root),
    NoteCategory(id: dolci, name: CategoryName('Dolci'), parent: root),
    NoteCategory(id: elsewhere, name: CategoryName('Lavoro')),
  ]);
  final cover = BlobId('c' * 32);
  final step = BlobId('s' * 32);

  final malloreddus = recipe('a', {
    'title': const TextValue('Malloreddus alla campidanese'),
    'description': const TextValue(
      'Gnocchetti di semola con **salsiccia** e zafferano.',
    ),
    'photos': AttachmentsValue([ImageAttachment(cover, caption: 'Il piatto')]),
    'servings': NumberValue(4),
    'prep_time': NumberValue(30),
    'cook_time': NumberValue(40),
    'difficulty': const RatingValue(2),
    'methods': ChoiceSetValue({'stovetop'}),
    'ingredients': IngredientsValue([
      Ingredient('Malloreddus', amount: 400, unit: IngredientUnit.gram),
      Ingredient('Salsiccia fresca', amount: 300, unit: IngredientUnit.gram),
      Ingredient('Pecorino  sardo', quantity: 'q.b.'),
      Ingredient(
        'Zafferano',
        amount: 1,
        unit: IngredientUnit.pinch,
        link: WebLink('https://example.org/zafferano'),
      ),
    ]),
    'steps': StepsValue([
      PreparationStep(
        'Rosola la salsiccia sbriciolata.',
        pictures: [ImageAttachment(step, caption: 'Dorata')],
      ),
      PreparationStep(
        'Aggiungi il pomodoro e cuoci 40 minuti.',
        video: BlobId('v' * 32),
      ),
      PreparationStep('Scola la pasta e condisci con il [sugo](note:abc).'),
    ]),
    'tags': TagListValue({'domenica'}),
  });
  final seadas = recipe('b', {
    'title': const TextValue('Seadas'),
    'ingredients': IngredientsValue([
      Ingredient('Pecorino sardo', amount: 200, unit: IngredientUnit.gram),
      Ingredient('Miele', quantity: 'q.b.'),
    ]),
    'steps': StepsValue([PreparationStep('Friggi e copri di miele.')]),
  });
  final culurgiones = recipe('c', {
    'title': const TextValue('Culurgiones'),
    'ingredients': IngredientsValue([Ingredient('patate', amount: 1)]),
  });
  final pane = recipe('d', {'title': const TextValue('Pane carasau')});
  final other = recipe('e', {'title': const TextValue('Fuori dal libro')});

  final filed = {
    malloreddus.id: primi,
    culurgiones.id: primi,
    seadas.id: dolci,
    pane.id: root,
    other.id: elsewhere,
  };

  Cookbook collect({SiteBook? site}) => Cookbook.collect(
    tree: tree,
    root: root,
    entries: [malloreddus, seadas, culurgiones, pane, other],
    categoryOf: (id) => filed[id],
    compose: CookbookPages(
      schemas: [SeedSchemas.recipeV1],
      texts: SchemaText(l10n),
      recipes: RecipeText(l10n),
      locale: 'it',
      site: site,
    ).compose,
    palette: SitePalette.of(const SiteTheme(BaseTheme.fresco)),
  );

  group('Cookbook', () {
    test('a chapter per category, recipes by title, nothing from outside', () {
      final book = collect();
      expect(book.title, 'Cucina sarda');
      expect(
        [for (final c in book.chapters) c.path],
        [
          <String>[],
          ['Dolci'],
          ['Primi'],
        ],
      );
      expect(
        [
          for (final c in book.chapters) [for (final r in c.recipes) r.title],
        ],
        [
          ['Pane carasau'],
          ['Seadas'],
          ['Culurgiones', 'Malloreddus alla campidanese'],
        ],
      );
      // Each chapter its colour, as on serv.pub.
      final palette = SitePalette.of(const SiteTheme(BaseTheme.fresco));
      for (final (i, c) in book.chapters.indexed) {
        expect(c.colours, CategoryColours.of(palette, i));
      }
    });

    test('the index merges ingredients written alike, in book order', () {
      final book = collect();
      final index = {
        for (final i in book.ingredients)
          i.name: [for (final r in i.recipes) r.title],
      };
      expect(index.keys, [
        'Malloreddus',
        'Miele',
        'patate',
        'Pecorino sardo',
        'Salsiccia fresca',
        'Zafferano',
      ]);
      expect(index['Pecorino sardo'], [
        'Seadas',
        'Malloreddus alla campidanese',
      ]);
    });

    test('the page is the one serv.pub would show, without vault ids', () {
      final book = collect();
      final page = book.recipes.last;
      final r = page.recipe;
      expect(r.description, contains('**salsiccia**'));
      expect(r.cover.single.caption, 'Il piatto');
      expect(page.media[r.cover.single.media], cover);
      expect(page.media[r.steps.first.pictures.single.media], step);
      expect(r.steps[1].video, isNotNull);
      expect(r.steps[2].text, isNot(contains('note:')));
      expect(page.page, isNull);
    });

    test('a published recipe brings its address, for the video code', () {
      final site = SiteBook(
        name: SiteName('ersilia'),
        settings: SiteSettings(title: 'Ersilia', lang: 'it'),
        pages: {
          malloreddus.id: PublishedPage(
            slug: PageSlug('malloreddus'),
            title: 'Malloreddus',
            listed: true,
            media: const [],
            at: DateTime.utc(2026, 11),
          ),
        },
      );
      final page = collect(site: site).recipes.last;
      expect(page.page.toString(), endsWith('/ersilia/malloreddus'));
    });

    test('a category with too many recipes is refused', () {
      final many = [
        for (var i = 0; i <= Cookbook.maxRecipes; i++)
          recipe('m$i', {'title': TextValue('R$i')}),
      ];
      expect(
        () => Cookbook.collect(
          tree: tree,
          root: root,
          entries: many,
          categoryOf: (_) => root,
          compose: (_) => null,
          palette: SitePalette.of(const SiteTheme(BaseTheme.fresco)),
        ),
        throwsA(isA<CookbookTooLargeException>()),
      );
    });
  });

  group('CookbookPdf', () {
    test('every page size gives a PDF with the pictures it has', () async {
      final book = collect();
      final page = book.recipes.last;
      final pictures = {
        for (final MapEntry(:key, :value) in page.media.entries)
          if (value == cover)
            key: jpeg(800, 494, 200, 120, 40)
          else if (value == step)
            key: jpeg(320, 198, 90, 140, 60),
      };
      for (final size in CookbookPage.values) {
        final pdf = await CookbookPdf(
          book: book,
          words: CookbookWords.of(l10n),
          fonts: fonts(),
          pictures: pictures,
          page: size,
        ).render();
        expect(String.fromCharCodes(pdf.take(5)), '%PDF-');
        if (Platform.environment['COOKBOOK_OUT'] case final out?) {
          File('$out/cookbook-${size.name}.pdf').writeAsBytesSync(pdf);
        }
      }
    });
  });

  group('CookbookEpub', () {
    Map<String, Uint8List> epub({String description = ''}) {
      final book = collect();
      final page = book.recipes.last;
      final pictures = {
        for (final MapEntry(:key, :value) in page.media.entries)
          if (value == cover) key: jpeg(80, 49, 200, 120, 40),
      };
      final bytes = CookbookEpub(
        book: book,
        words: CookbookWords.of(l10n),
        pictures: pictures,
      ).render(at: DateTime.utc(2026, 11, 1, 12));
      if (Platform.environment['COOKBOOK_OUT'] case final out?) {
        File('$out/cookbook.epub').writeAsBytesSync(bytes);
      }
      return unzipBytes(bytes);
    }

    test('an EPUB 3: mimetype first, a page per recipe, the index', () {
      final files = epub();
      expect(files.keys.first, 'mimetype');
      expect(String.fromCharCodes(files['mimetype']!), 'application/epub+zip');
      final opf = utf8.decode(files['EPUB/package.opf']!);
      expect(opf, contains('<dc:title>Cucina sarda</dc:title>'));
      expect(opf, contains('properties="cover-image"'));
      expect(
        files.keys.where((k) => k.startsWith('EPUB/recipe-')),
        hasLength(4),
      );
      final index = utf8.decode(files['EPUB/ingredients.xhtml']!);
      expect(index, contains('<dt>Pecorino sardo</dt>'));
      final malloreddus = utf8.decode(files['EPUB/recipe-3.xhtml']!);
      expect(malloreddus, contains('<strong>salsiccia</strong>'));
      expect(malloreddus, contains(l10n.cookbookVideoInNote));
      expect(malloreddus, isNot(contains('note:')));
    });
  });

  group('adversary', () {
    test('markup of the person never becomes markup of the book', () {
      final hostile = recipe('h', {
        'title': const TextValue('<script>alert(1)</script> & "co"'),
        'description': const TextValue(
          '[clic](javascript:alert(1)) <img src=x onerror=alert(1)> '
          '[ok](https://example.org/?a=1&b="2")',
        ),
        'steps': StepsValue([
          PreparationStep('![x](https://tracker.example/pixel.png) Mescola.'),
        ]),
      });
      final book = Cookbook.collect(
        tree: tree,
        root: root,
        entries: [hostile],
        categoryOf: (_) => root,
        compose: CookbookPages(
          schemas: [SeedSchemas.recipeV1],
          texts: SchemaText(l10n),
          recipes: RecipeText(l10n),
          locale: 'it',
        ).compose,
        palette: SitePalette.of(const SiteTheme(BaseTheme.fresco)),
      );
      final files = unzipBytes(
        CookbookEpub(
          book: book,
          words: CookbookWords.of(l10n),
          pictures: const {},
        ).render(at: DateTime.utc(2026, 11)),
      );
      final page = utf8.decode(files['EPUB/recipe-0.xhtml']!);
      expect(page, isNot(contains('<script')));
      expect(page, isNot(contains('<img src=x')));
      expect(page, isNot(contains('javascript:')));
      expect(page, isNot(contains('tracker.example')));
      expect(page, contains('&lt;script&gt;'));
      expect(page, contains('href="https://example.org/?a=1&amp;b=%222%22"'));
      final opf = utf8.decode(files['EPUB/package.opf']!);
      expect(opf, contains('<dc:title>Cucina sarda</dc:title>'));
    });

    testWidgets('a picture keeps nothing of its file but the pixels', (
      tester,
    ) async {
      final original = img.Image(width: 40, height: 30);
      img.fill(original, color: img.ColorRgb8(10, 120, 200));
      original.exif.imageIfd['Make'] = img.IfdValueAscii('SegretoCamera');
      final bytes = img.encodeJpg(original);
      expect(String.fromCharCodes(bytes), contains('SegretoCamera'));
      final clean = await tester.runAsync(
        () => bookPicture(bytes, side: bookPictureSide),
      );
      expect(clean, isNotNull);
      expect(String.fromCharCodes(clean!), isNot(contains('SegretoCamera')));
      expect(String.fromCharCodes(clean), isNot(contains('Exif')));
      final back = img.decodeJpg(clean)!;
      expect((back.width, back.height), (40, 30));
    });
  });
}
