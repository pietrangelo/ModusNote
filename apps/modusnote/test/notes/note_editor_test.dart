import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modusnote/notes/note_editor.dart';
import 'package:modusnote/notes/note_store.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import 'harness.dart';

final now = DateTime.utc(2026, 10, 11, 14);

void main() {
  late InMemoryNoteStore store;

  setUp(() => store = InMemoryNoteStore());

  Future<void> open(
    WidgetTester tester, {
    DynamicEntry? entry,
    SchemaDefinition? schema,
  }) => pumpApp(
    tester,
    NoteEditorScreen(
      schemas: SeedSchemas.all,
      store: store,
      entry: entry,
      initialSchema: schema ?? SeedSchemas.taskV1,
      clock: () => now,
    ),
  );

  Future<void> save(WidgetTester tester) async {
    await tester.tap(find.text('Salva'));
    await tester.pumpAndSettle();
  }

  testWidgets('a note that misses required fields is not saved', (
    tester,
  ) async {
    await open(tester);

    await save(tester);

    expect(store.entries, isEmpty);
    expect(find.text('Obbligatorio'), findsWidgets);
    expect(find.text('Correggi i campi evidenziati per salvare.'), findsOne);
  });

  testWidgets('a valid new note is saved as a new entry', (tester) async {
    await open(tester);

    await tester.enterText(textInput('description'), 'Chiamare Ada');
    await tester.tap(
      find.descendant(
        of: fieldFinder('completed'),
        matching: find.byType(Checkbox),
      ),
    );
    await tester.pump();
    await tester.tap(
      find.descendant(
        of: fieldFinder('completed'),
        matching: find.byType(Checkbox),
      ),
    );
    await save(tester);

    final entry = store.entries.single;
    expect(entry.schemaId, SeedSchemas.taskV1.id);
    expect(
      entry.valueOf(FieldKey('description')),
      const TextValue('Chiamare Ada'),
    );
    expect(entry.valueOf(FieldKey('completed')), const BooleanValue(false));
    expect(entry.audit.createdAt, now);
    expect(
      entry.id.value,
      matches(RegExp(r'^[0-9a-f]{32}$')),
      reason: 'the id doubles as the record id the vault stores it under',
    );
  });

  testWidgets('an unreadable number blocks saving and is flagged', (
    tester,
  ) async {
    await open(tester, schema: SeedSchemas.songSketchV1);

    await tester.enterText(textInput('title'), 'Riff');
    await tester.enterText(textInput('bpm'), 'veloce');
    await save(tester);

    expect(store.entries, isEmpty);
    expect(
      find.descendant(
        of: fieldFinder('bpm'),
        matching: find.text('Valore non valido'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('switching type while writing keeps what fits', (tester) async {
    await open(tester, schema: SeedSchemas.quickNoteV1);

    await tester.enterText(textInput('content'), 'Comprare corde');
    await tester.tap(find.widgetWithText(ChoiceChip, 'Attività'));
    await tester.pumpAndSettle();

    expect(fieldFinder('description'), findsOneWidget);
    expect(fieldFinder('content'), findsNothing);
    expect(find.text('Comprare corde'), findsOneWidget);
  });

  testWidgets('editing an existing note updates it, type fixed', (
    tester,
  ) async {
    final original = switch (DynamicEntry.create(
      schema: SeedSchemas.quickNoteV1,
      id: EntryId('n1'),
      attributes: {FieldKey('content'): const TextValue('Prima')},
      at: now.subtract(const Duration(days: 1)),
    )) {
      Valid(:final value) => value,
      Invalid() => throw StateError('fixture'),
    };
    await store.save(original);
    await open(tester, entry: original, schema: SeedSchemas.quickNoteV1);

    expect(find.byType(ChoiceChip), findsNothing);
    await tester.tap(find.text('Scrivi'));
    await tester.pumpAndSettle();
    await tester.enterText(textInput('content'), 'Dopo');
    await save(tester);

    final updated = store.entries.single;
    expect(updated.id, original.id);
    expect(updated.valueOf(FieldKey('content')), const TextValue('Dopo'));
    expect(updated.audit.revision, 2);
    expect(updated.audit.updatedAt, now);
  });
}
