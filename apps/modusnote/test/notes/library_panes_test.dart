import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modusnote/notes/note_editor.dart';
import 'package:modusnote/notes/note_library.dart';
import 'package:modusnote/notes/note_store.dart';
import 'package:modusnote/notes/trash_screen.dart';
import 'package:modusnote/theme/golden_ratio.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import 'harness.dart';

DynamicEntry entry(
  String id,
  SchemaDefinition schema,
  Map<String, FieldValue> attributes,
  int minute,
) => switch (DynamicEntry.create(
  schema: schema,
  id: EntryId(id),
  attributes: {for (final e in attributes.entries) FieldKey(e.key): e.value},
  at: DateTime.utc(2026, 10, 11, 9, minute),
)) {
  Valid(:final value) => value,
  Invalid(:final violations) => throw StateError('$violations'),
};

const song = '0000000000000000000000000000000a';
const riff = '0000000000000000000000000000000b';

Finder row(String id) => find.byKey(ValueKey('note-row-$id'));
Finder nav(String name) => find.byKey(ValueKey('nav-$name'));

void main() {
  late InMemoryNoteStore store;

  setUp(() async {
    store = InMemoryNoteStore();
    await store.save(
      entry(song, SeedSchemas.songSketchV1, {
        'title': const TextValue('Notturno in La'),
      }, 1),
    );
    await store.save(
      entry(riff, SeedSchemas.quickNoteV1, {
        'content': const TextValue('Idea per un riff'),
      }, 2),
    );
  });

  /// The library on a window as wide as a laptop's browser.
  Future<void> openWide(WidgetTester tester, {double width = 1440}) async {
    await pumpApp(
      tester,
      NoteLibraryScreen(schemas: SeedSchemas.all, store: store),
    );
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = Size(width, 900);
    await tester.pumpAndSettle();
  }

  Future<void> select(WidgetTester tester, Finder target) async {
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  testWidgets('a wide window shows types, notes and the note side by side', (
    tester,
  ) async {
    await openWide(tester);

    expect(nav('all'), findsOneWidget);
    for (final schema in SeedSchemas.all) {
      expect(nav(schema.id.name), findsOneWidget);
    }
    expect(nav('trash'), findsOneWidget);
    expect(row(song), findsOneWidget);
    expect(row(riff), findsOneWidget);
    expect(find.text('Scegli una nota o creane una nuova.'), findsOneWidget);
    expect(find.byType(FloatingActionButton), findsNothing);

    await select(tester, row(song));

    expect(find.byType(NoteEditorScreen), findsOneWidget);
    expect(row(riff), findsOneWidget, reason: 'the list stays in view');
    expect(find.byType(BackButton), findsNothing);
  });

  testWidgets('the columns take their widths from the golden scale', (
    tester,
  ) async {
    await openWide(tester);

    expect(
      tester.getSize(find.byKey(const ValueKey('pane-types'))).width,
      Extents.l,
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('pane-notes'))).width,
      Extents.xl,
    );
  });

  testWidgets('a narrow window keeps the cards and pages', (tester) async {
    await openWide(tester, width: Extents.xxxl - 1);

    expect(nav('all'), findsNothing);
    expect(find.byType(FloatingActionButton), findsOneWidget);
  });

  testWidgets('picking another note saves the one being written first', (
    tester,
  ) async {
    await openWide(tester);
    await select(tester, row(riff));

    await tester.enterText(textInput('content'), 'Idea per un riff in Mi');
    await select(tester, row(song));

    final saved = store.entries.firstWhere((e) => e.id.value == riff);
    expect(
      saved.attributes[FieldKey('content')],
      const TextValue('Idea per un riff in Mi'),
    );
    expect(find.text('Notturno in La'), findsWidgets);
  });

  testWidgets('a note that cannot be saved asks before another opens', (
    tester,
  ) async {
    await openWide(tester);
    await select(tester, row(song));

    await tester.enterText(textInput('title'), '');
    await select(tester, row(riff));

    expect(find.byType(AlertDialog), findsOneWidget);
    await select(tester, find.text('Continua a scrivere'));
    expect(fieldFinder('title'), findsOneWidget);
    expect(fieldFinder('content'), findsNothing);
  });

  testWidgets('a type in the side column filters the notes', (tester) async {
    await openWide(tester);

    await select(tester, nav(SeedSchemas.songSketchV1.id.name));

    expect(row(song), findsOneWidget);
    expect(row(riff), findsNothing);
  });

  testWidgets('a new note opens beside the list and joins it once saved', (
    tester,
  ) async {
    await openWide(tester);
    await select(tester, nav(SeedSchemas.quickNoteV1.id.name));

    await select(tester, find.text('Nuova nota'));
    await tester.enterText(textInput('content'), 'Un giro di accordi');
    await tester.pump(NoteEditorScreen.autosaveDelay);
    await tester.pumpAndSettle();

    expect(store.entries, hasLength(3));
    expect(find.text('Un giro di accordi'), findsWidgets);
    expect(find.byType(NoteEditorScreen), findsOneWidget);
  });

  testWidgets('closing or trashing the note empties the right column', (
    tester,
  ) async {
    await openWide(tester);
    await select(tester, row(riff));

    await select(tester, find.byTooltip('Sposta nel cestino'));

    expect(find.byType(NoteEditorScreen), findsNothing);
    expect(row(riff), findsNothing);
    expect(find.text('Scegli una nota o creane una nuova.'), findsOneWidget);

    await select(tester, row(song));
    await select(tester, find.byTooltip('Chiudi'));
    expect(find.byType(NoteEditorScreen), findsNothing);
  });

  testWidgets('the categories show as a tree in the side column', (
    tester,
  ) async {
    final novels = CategoryId('n' * 32);
    final crime = CategoryId('c' * 32);
    await store.saveCategory(
      NoteCategory(id: novels, name: CategoryName('Romanzi')),
    );
    await store.saveCategory(
      NoteCategory(id: crime, name: CategoryName('Gialli'), parent: novels),
    );
    await store.file(EntryId(riff), crime);
    await openWide(tester);

    final top = find.byKey(ValueKey('nav-category-${novels.value}'));
    final inner = find.byKey(ValueKey('nav-category-${crime.value}'));
    expect(top, findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Gialli')).dx,
      greaterThan(tester.getTopLeft(find.text('Romanzi')).dx),
      reason: 'a subcategory sits inside its parent',
    );

    await select(tester, top);
    expect(row(riff), findsOneWidget, reason: 'subcategories count too');
    expect(row(song), findsNothing);

    await select(tester, find.text('Nuova nota'));
    await tester.enterText(textInput('content'), 'Un altro giallo');
    await select(tester, inner);
    await tester.pump(NoteEditorScreen.autosaveDelay);
    await tester.pumpAndSettle();
    final added = store.entries.firstWhere(
      (e) => e.id.value != riff && e.id.value != song,
    );
    expect(store.categoryOf(added.id), novels);

    await select(tester, nav('all'));
    expect(row(song), findsOneWidget);
  });

  testWidgets('the trash opens in place of the notes', (tester) async {
    await openWide(tester);
    await select(tester, row(riff));
    await tester.enterText(textInput('content'), 'Riff salvato');

    await select(tester, nav('trash'));

    expect(find.byType(TrashScreen), findsOneWidget);
    expect(find.byType(NoteEditorScreen), findsNothing);
    final saved = store.entries.firstWhere((e) => e.id.value == riff);
    expect(
      saved.attributes[FieldKey('content')],
      const TextValue('Riff salvato'),
    );

    await select(tester, nav('all'));
    expect(find.byType(TrashScreen), findsNothing);
    expect(row(riff), findsOneWidget);
  });
}
