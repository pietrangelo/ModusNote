import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modusnote/notes/categories/categories_screen.dart';
import 'package:modusnote/notes/note_editor.dart';
import 'package:modusnote/notes/note_library.dart';
import 'package:modusnote/notes/note_store.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import 'harness.dart';

DynamicEntry quickNote(String id, String content, int minute) =>
    switch (DynamicEntry.create(
      schema: SeedSchemas.quickNoteV1,
      id: EntryId(id),
      attributes: {FieldKey('content'): TextValue(content)},
      at: DateTime.utc(2026, 10, 13, 9, minute),
    )) {
      Valid(:final value) => value,
      Invalid(:final violations) => throw StateError('$violations'),
    };

final novels = CategoryId('n' * 32);
final crime = CategoryId('c' * 32);
final work = CategoryId('w' * 32);

void main() {
  late InMemoryNoteStore store;

  setUp(() async {
    store = InMemoryNoteStore();
    await store.saveCategory(
      NoteCategory(
        id: novels,
        name: CategoryName('Romanzi'),
        icon: NoteIcon.book,
        tint: NoteTint.rose,
      ),
    );
    await store.saveCategory(
      NoteCategory(id: crime, name: CategoryName('Gialli'), parent: novels),
    );
    await store.saveCategory(
      NoteCategory(id: work, name: CategoryName('Lavoro')),
    );
    await store.save(quickNote('a', 'Trama del delitto', 1), newIn: crime);
    await store.save(quickNote('b', 'Idee per la saga', 2), newIn: novels);
    await store.save(quickNote('c', 'Riunione di lunedì', 3), newIn: work);
    await store.save(quickNote('d', 'Lista della spesa', 4));
  });

  Future<void> openLibrary(WidgetTester tester) => pumpApp(
    tester,
    NoteLibraryScreen(schemas: SeedSchemas.all, store: store),
  );

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  Finder chip(CategoryId id) => find.byKey(ValueKey('category-${id.value}'));

  testWidgets('a category shows its notes and those of the categories '
      'inside it', (tester) async {
    await openLibrary(tester);
    expect(find.text('Lista della spesa'), findsOneWidget);

    await tap(tester, chip(novels));

    expect(find.text('Trama del delitto'), findsOneWidget);
    expect(find.text('Idee per la saga'), findsOneWidget);
    expect(find.text('Riunione di lunedì'), findsNothing);
    expect(find.text('Lista della spesa'), findsNothing);
    expect(chip(work), findsNothing, reason: 'only what is inside Romanzi');

    await tap(tester, chip(crime));

    expect(find.text('Trama del delitto'), findsOneWidget);
    expect(find.text('Idee per la saga'), findsNothing);

    // The path leads back up.
    await tap(tester, find.byKey(ValueKey('path-${novels.value}')));
    expect(find.text('Idee per la saga'), findsOneWidget);
    await tap(tester, find.byKey(const ValueKey('path-all')));
    expect(find.text('Lista della spesa'), findsOneWidget);
  });

  testWidgets('a new note is filed in the category being looked at', (
    tester,
  ) async {
    await openLibrary(tester);
    await tap(tester, chip(work));

    await tap(tester, find.text('Nuova nota'));

    final editor = tester.widget<NoteEditorScreen>(
      find.byType(NoteEditorScreen),
    );
    expect(editor.category, work);
  });

  testWidgets('a long press files a note somewhere else', (tester) async {
    await openLibrary(tester);

    await tester.longPress(find.text('Lista della spesa'));
    await tester.pumpAndSettle();
    await tap(tester, find.byKey(ValueKey('pick-${crime.value}')));

    expect(store.categoryOf(EntryId('d')), crime);
    expect(find.text('Nota spostata in «Gialli».'), findsOneWidget);

    await tester.longPress(find.text('Lista della spesa'));
    await tester.pumpAndSettle();
    await tap(tester, find.byKey(const ValueKey('pick-none')));

    expect(store.categoryOf(EntryId('d')), isNull);
  });

  testWidgets('without categories the library shows no path', (tester) async {
    await pumpApp(
      tester,
      NoteLibraryScreen(schemas: SeedSchemas.all, store: InMemoryNoteStore()),
    );

    expect(find.text('Tutte le note'), findsNothing);
  });

  testWidgets('a deleted category shows every note again', (tester) async {
    await openLibrary(tester);
    await tap(tester, chip(work));
    expect(find.text('Lista della spesa'), findsNothing);

    await store.deleteCategory(work);
    await tester.pumpAndSettle();

    expect(find.text('Lista della spesa'), findsOneWidget);
    expect(find.text('Riunione di lunedì'), findsOneWidget);
  });

  group('categories screen', () {
    Future<void> openScreen(WidgetTester tester) =>
        pumpApp(tester, CategoriesScreen(store: store));

    testWidgets('the library opens it', (tester) async {
      await openLibrary(tester);

      await tap(tester, find.byTooltip('Categorie'));

      expect(find.byType(CategoriesScreen), findsOneWidget);
    });

    testWidgets('lists the tree, children under their parent', (tester) async {
      await openScreen(tester);

      final names = ['Lavoro', 'Romanzi', 'Gialli'];
      final tops = [
        for (final name in names) tester.getTopLeft(find.text(name)).dy,
      ];
      expect(tops, orderedEquals([...tops]..sort()));
      expect(
        tester.getTopLeft(find.text('Gialli')).dx,
        greaterThan(tester.getTopLeft(find.text('Romanzi')).dx),
      );
    });

    testWidgets('creates a category with a name, icon and colour', (
      tester,
    ) async {
      await openScreen(tester);

      await tap(tester, find.text('Nuova categoria'));
      await tester.enterText(
        find.byKey(const ValueKey('category-name')),
        '  Manuali  ',
      );
      await tap(tester, find.byTooltip('Libro'));
      await tap(tester, find.byTooltip('Ciano'));
      await tap(tester, find.text('Salva'));

      final created = store.categories.roots.firstWhere(
        (c) => c.name.value == 'Manuali',
      );
      expect(created.icon, NoteIcon.book);
      expect(created.tint, NoteTint.cyan);
      expect(created.parent, isNull);
      expect(RegExp(r'^[0-9a-f]{32}$').hasMatch(created.id.value), isTrue);
      expect(find.text('Manuali'), findsOneWidget);
    });

    testWidgets('refuses a blank name', (tester) async {
      await openScreen(tester);

      await tap(tester, find.text('Nuova categoria'));
      await tester.enterText(
        find.byKey(const ValueKey('category-name')),
        '   ',
      );
      await tap(tester, find.text('Salva'));

      expect(
        find.text('Scrivi un nome di al massimo 80 caratteri, su una riga.'),
        findsOneWidget,
      );
      expect(store.categories.length, 3);
    });

    Future<void> menu(WidgetTester tester, String name, String action) async {
      await tap(
        tester,
        find.descendant(
          of: find.ancestor(
            of: find.text(name),
            matching: find.byType(ListTile),
          ),
          matching: find.byIcon(Icons.more_vert),
        ),
      );
      await tap(tester, find.text(action).last);
    }

    testWidgets('adds a subcategory', (tester) async {
      await openScreen(tester);

      await menu(tester, 'Gialli', 'Nuova sotto-categoria');
      await tester.enterText(
        find.byKey(const ValueKey('category-name')),
        'Noir',
      );
      await tap(tester, find.text('Salva'));

      final noir = store.categories.ordered.firstWhere(
        (c) => c.name.value == 'Noir',
      );
      expect(store.categories.parentOf(noir.id), crime);
    });

    testWidgets('moves a category, offering only places that fit', (
      tester,
    ) async {
      await openScreen(tester);

      await menu(tester, 'Romanzi', 'Sposta');

      // Not inside itself or its own subcategory.
      expect(find.byKey(ValueKey('pick-${novels.value}')), findsNothing);
      expect(find.byKey(ValueKey('pick-${crime.value}')), findsNothing);
      await tap(tester, find.byKey(ValueKey('pick-${work.value}')));

      expect(store.categories.parentOf(novels), work);
      expect(store.categories.depthOf(crime), 3);
    });

    testWidgets('deleting asks first and keeps every note', (tester) async {
      await openScreen(tester);

      await menu(tester, 'Romanzi', 'Elimina');
      expect(find.text('Eliminare «Romanzi»?'), findsOneWidget);
      expect(
        find.text(
          'Le sue note e sotto-categorie passano al livello principale. '
          'Nessuna nota viene eliminata.',
        ),
        findsOneWidget,
      );
      await tap(tester, find.widgetWithText(FilledButton, 'Elimina'));

      expect(store.categories[novels], isNull);
      expect(store.categories.parentOf(crime), isNull);
      expect(store.categoryOf(EntryId('b')), isNull);
      expect(store.categoryOf(EntryId('a')), crime);
      expect(store.entries, hasLength(4));
    });
  });
}
