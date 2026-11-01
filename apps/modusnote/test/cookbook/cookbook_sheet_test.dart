import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modusnote/cookbook/cookbook.dart';
import 'package:modusnote/cookbook/cookbook_pages.dart';
import 'package:modusnote/cookbook/cookbook_sheet.dart';
import 'package:modusnote/notes/recipes/recipe_text.dart';
import 'package:modusnote/notes/schema_text.dart';
import 'package:publishing/publishing.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import '../backup/backup_sheet_test.dart' show FakeFiles;
import '../notes/harness.dart';
import 'cookbook_test.dart' show fonts, jpeg, recipe;

void main() {
  final root = CategoryId('r' * 32);
  final tree = CategoryTree([
    NoteCategory(id: root, name: CategoryName('Cucina sarda')),
  ]);
  final photo = BlobId('c' * 32);
  final seadas = recipe('b', {
    'title': const TextValue('Seadas'),
    'photos': AttachmentsValue([ImageAttachment(photo)]),
    'ingredients': IngredientsValue([Ingredient('Miele', quantity: 'q.b.')]),
  });

  late FakeFiles files;
  late List<(BlobId, int)> asked;
  late List<CategoryId> collected;

  CookbookTools tools({List<DynamicEntry>? entries}) => CookbookTools(
    files: files,
    collect: (root, l10n) async {
      collected.add(root);
      return Cookbook.collect(
        tree: tree,
        root: root,
        entries: entries ?? [seadas],
        categoryOf: (_) => root,
        compose: CookbookPages(
          schemas: [SeedSchemas.recipeV1],
          texts: SchemaText(l10n),
          recipes: RecipeText(l10n),
          locale: 'it',
        ).compose,
        palette: SitePalette.of(const SiteTheme(BaseTheme.fresco)),
      );
    },
    picture: (blob, side) async {
      asked.add((blob, side));
      return jpeg(60, 37, 200, 120, 40);
    },
    fonts: () async => fonts(),
  );

  setUp(() {
    files = FakeFiles();
    asked = [];
    collected = [];
  });

  Future<void> open(WidgetTester tester, CookbookTools tools) async {
    await pumpApp(
      tester,
      Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => showCookbookSheet(
                context,
                root: root,
                name: 'Cucina sarda',
                tools: tools,
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

  Future<void> export(WidgetTester tester) async {
    final button = find.byKey(const ValueKey('cookbook-export'));
    await tester.ensureVisible(button);
    await tester.tap(button);
    // The work runs off the test's fake clock.
    for (var i = 0; i < 50 && files.saved.isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  testWidgets('warns that the file is in clear, then saves a PDF', (
    tester,
  ) async {
    await open(tester, tools());
    expect(find.textContaining('non è cifrato'), findsOneWidget);
    expect(find.text('Aureo'), findsOneWidget);

    await export(tester);

    expect(collected, [root]);
    expect(files.saved.keys.single, 'Cucina sarda.pdf');
    expect(String.fromCharCodes(files.saved.values.single.take(5)), '%PDF-');
    // The opening photo, at its own size.
    expect(asked.single.$2, 987);
    expect(find.text('Ricettario esportato'), findsOneWidget);
  });

  testWidgets('an EPUB, without the photos when asked', (tester) async {
    await open(tester, tools());
    await tester.tap(find.text('EPUB, per i lettori di ebook'));
    await tester.pumpAndSettle();
    expect(find.text('Aureo'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('cookbook-pictures')));
    await tester.pumpAndSettle();

    await export(tester);

    expect(files.saved.keys.single, 'Cucina sarda.epub');
    final bytes = files.saved.values.single;
    expect(
      String.fromCharCodes(Uint8List.sublistView(bytes, 30, 38)),
      'mimetype',
    );
    expect(asked, isEmpty);
  });

  testWidgets('a category without recipes says so and saves nothing', (
    tester,
  ) async {
    await open(tester, tools(entries: const []));
    await export(tester);
    expect(collected, [root]);
    expect(
      find.text('In questa categoria non ci sono ricette.'),
      findsOneWidget,
    );
    expect(files.saved, isEmpty);
  });
}
