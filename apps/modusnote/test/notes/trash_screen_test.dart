import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modusnote/notes/note_editor.dart';
import 'package:modusnote/notes/note_library.dart';
import 'package:modusnote/notes/note_store.dart';
import 'package:modusnote/notes/trash_screen.dart';
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

void main() {
  late InMemoryNoteStore store;

  setUp(() async {
    store = InMemoryNoteStore();
    await store.save(quickNote('a', 'Accordi del ponte', 1));
    await store.save(quickNote('b', 'Lista della spesa', 2));
  });

  Future<void> openLibrary(WidgetTester tester) => pumpApp(
    tester,
    NoteLibraryScreen(schemas: SeedSchemas.all, store: store),
  );

  Future<void> openTrash(WidgetTester tester) =>
      pumpApp(tester, TrashScreen(schemas: SeedSchemas.all, store: store));

  Future<void> tapTooltip(WidgetTester tester, String tooltip) async {
    await tester.tap(find.byTooltip(tooltip));
    await tester.pumpAndSettle();
  }

  testWidgets('the editor moves a note to the trash, and undo brings it '
      'back', (tester) async {
    await openLibrary(tester);
    await tester.tap(find.text('Lista della spesa'));
    await tester.pumpAndSettle();

    await tapTooltip(tester, 'Sposta nel cestino');

    expect(find.byType(NoteEditorScreen), findsNothing);
    expect(find.text('Lista della spesa'), findsNothing);
    expect(find.text('Nota spostata nel cestino.'), findsOneWidget);
    expect(store.trash.single.entry.id, EntryId('b'));

    await tester.tap(find.text('Annulla'));
    await tester.pumpAndSettle();

    expect(store.trash, isEmpty);
    expect(find.text('Lista della spesa'), findsOneWidget);
  });

  testWidgets('a new note has nothing to trash', (tester) async {
    await pumpApp(
      tester,
      NoteEditorScreen(
        schemas: SeedSchemas.all,
        store: store,
        initialSchema: SeedSchemas.quickNoteV1,
      ),
    );

    expect(find.byTooltip('Sposta nel cestino'), findsNothing);
  });

  testWidgets('the library opens the trash', (tester) async {
    await store.moveToTrash(EntryId('a'));
    await openLibrary(tester);

    await tapTooltip(tester, 'Cestino');

    expect(find.byType(TrashScreen), findsOneWidget);
    expect(find.text('Accordi del ponte'), findsOneWidget);
    expect(find.textContaining('Nel cestino dal'), findsOneWidget);
  });

  testWidgets('an empty trash says so and offers nothing to empty', (
    tester,
  ) async {
    await openTrash(tester);

    expect(find.text('Il cestino è vuoto.'), findsOneWidget);
    final empty = tester.widget<TextButton>(
      find.widgetWithText(TextButton, 'Svuota il cestino'),
    );
    expect(empty.onPressed, isNull);
  });

  testWidgets('restoring puts the note back in the library', (tester) async {
    await store.moveToTrash(EntryId('a'));
    await openTrash(tester);

    await tapTooltip(tester, 'Ripristina');

    expect(store.trash, isEmpty);
    expect(store.entries.map((e) => e.id), contains(EntryId('a')));
    expect(find.text('Nota ripristinata.'), findsOneWidget);
    expect(find.text('Il cestino è vuoto.'), findsOneWidget);
  });

  testWidgets('deleting for good asks first, and cancel keeps the note', (
    tester,
  ) async {
    await store.moveToTrash(EntryId('a'));
    await openTrash(tester);

    await tapTooltip(tester, 'Elimina per sempre');
    expect(find.text('Eliminare la nota per sempre?'), findsOneWidget);
    await tester.tap(find.text('Annulla'));
    await tester.pumpAndSettle();

    expect(store.trash, hasLength(1));

    await tapTooltip(tester, 'Elimina per sempre');
    await tester.tap(find.text('Elimina'));
    await tester.pumpAndSettle();

    expect(store.trash, isEmpty);
    expect(store.entries.map((e) => e.id), [EntryId('b')]);
    expect(find.text('Il cestino è vuoto.'), findsOneWidget);
  });

  testWidgets('emptying the trash deletes every note in it', (tester) async {
    await store.moveToTrash(EntryId('a'));
    await store.moveToTrash(EntryId('b'));
    await openTrash(tester);

    await tester.tap(find.text('Svuota il cestino'));
    await tester.pumpAndSettle();
    expect(find.text('Svuotare il cestino?'), findsOneWidget);
    await tester.tap(find.text('Elimina'));
    await tester.pumpAndSettle();

    expect(store.trash, isEmpty);
    expect(store.entries, isEmpty);
  });

  testWidgets('the most recently trashed note comes first', (tester) async {
    var minute = 0;
    store = InMemoryNoteStore(
      clock: () => DateTime.utc(2026, 10, 13, 10, minute++),
    );
    await store.save(quickNote('a', 'Accordi del ponte', 1));
    await store.save(quickNote('b', 'Lista della spesa', 2));
    await store.moveToTrash(EntryId('a'));
    await store.moveToTrash(EntryId('b'));
    await openTrash(tester);

    final first = tester.getTopLeft(find.text('Lista della spesa')).dy;
    final second = tester.getTopLeft(find.text('Accordi del ponte')).dy;
    expect(first, lessThan(second));
  });
}
