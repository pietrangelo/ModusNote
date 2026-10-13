import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modusnote/notes/note_editor.dart';
import 'package:modusnote/notes/note_store.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import '../harness.dart';
import 'manual_support.dart';

void main() {
  late InMemoryNoteStore store;

  setUp(() async {
    store = await manualStore();
  });

  DynamicEntry entry(EntryId id) =>
      store.entries.firstWhere((entry) => entry.id == id);

  Future<void> open(WidgetTester tester, {DynamicEntry? entry}) async {
    await pumpApp(
      tester,
      Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => NoteEditorScreen(
                    schemas: SeedSchemas.all,
                    store: store,
                    entry: entry,
                    initialSchema: SeedSchemas.documentV1,
                  ),
                ),
              ),
              child: const Text('apri'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('apri'));
    await tester.pumpAndSettle();
    // Room for the whole index below the page.
    tester.view.physicalSize = const Size(1080, 6000);
    await tester.pumpAndSettle();
  }

  Finder row(String id) => find.byKey(ValueKey('index-${page(id).value}'));

  testWidgets('a page shows its manual, itself marked, in order', (
    tester,
  ) async {
    await open(tester, entry: entry(page('p2')));

    expect(find.text('Indice'), findsOneWidget);
    final rows = [
      for (final id in ['p1', 'p2', 'p3', 'p4', 'p5']) row(id),
    ];
    final tops = [for (final r in rows) tester.getTopLeft(r).dy];
    expect(tops, orderedEquals([...tops]..sort()));
    expect(
      find.byKey(ValueKey('index-section-${setup.value}')),
      findsOneWidget,
    );
    expect(tester.widget<ListTile>(row('p2')).selected, isTrue);
    expect(row('p6'), findsNothing);
    expect(find.text('Promemoria'), findsNothing);
  });

  testWidgets('a tap opens another page of the manual', (tester) async {
    await open(tester, entry: entry(page('p2')));

    await tester.tap(row('p5'));
    await tester.pumpAndSettle();

    expect(find.text('Proxy'), findsWidgets);
    expect(tester.widget<ListTile>(row('p5')).selected, isTrue);
  });

  testWidgets('a new page from the index lands in the same category', (
    tester,
  ) async {
    await open(tester, entry: entry(page('p4')));

    await tester.tap(find.text('Nuova pagina'));
    await tester.pumpAndSettle();
    await tester.enterText(textInput('title'), 'Aggiornare');
    await tester.pump();
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    final added = store.entries.firstWhere(
      (e) => e.valueOf(FieldKey('title')) == const TextValue('Aggiornare'),
    );
    expect(added.schemaId, SeedSchemas.documentV1.id);
    expect(store.categoryOf(added.id), setup);
    expect(find.byKey(ValueKey('index-${added.id.value}')), findsOneWidget);
  });

  testWidgets('a page in no category says how to make an index', (
    tester,
  ) async {
    await open(tester, entry: entry(page('p6')));

    expect(
      find.textContaining('Metti la pagina in una categoria'),
      findsOneWidget,
    );
    expect(find.text('Nuova pagina'), findsNothing);
  });
}
