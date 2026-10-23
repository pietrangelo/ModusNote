import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modusnote/notes/draft_merge.dart';
import 'package:modusnote/notes/note_editor.dart';
import 'package:modusnote/notes/note_store.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import 'harness.dart';

final now = DateTime.utc(2026, 10, 23, 9);
final title = FieldKey('title');
final body = FieldKey('body');
final id = EntryId('0123456789abcdef0123456789abcdef');

DynamicEntry page(String heading, String text) => switch (DynamicEntry.create(
  schema: SeedSchemas.documentV1,
  id: id,
  attributes: {title: TextValue(heading), body: TextValue(text)},
  at: now.subtract(const Duration(days: 1)),
)) {
  Valid(:final value) => value,
  Invalid(:final violations) => throw StateError('$violations'),
};

/// [entry] as another device saved it: [changes] on top.
DynamicEntry elsewhere(
  DynamicEntry entry,
  Map<FieldKey, FieldValue?> changes,
) => switch (entry.update(
  schema: SeedSchemas.documentV1,
  changes: changes,
  at: now.subtract(const Duration(hours: 1)),
)) {
  Valid(:final value) => value,
  Invalid(:final violations) => throw StateError('$violations'),
};

String? textOf(WidgetTester tester, String key) =>
    tester.widget<EditableText>(textInput(key)).controller.text;

void main() {
  late InMemoryNoteStore store;
  late DynamicEntry opened;

  setUp(() async {
    store = InMemoryNoteStore(clock: () => now);
    opened = page('Faro', 'La luce gira.');
    await store.save(opened);
  });

  Future<void> open(WidgetTester tester) async {
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
                    entry: store.entryOf(id),
                    initialSchema: SeedSchemas.documentV1,
                    clock: () => now,
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
  }

  Future<void> pause(WidgetTester tester) async {
    await tester.pump(NoteEditorScreen.autosaveDelay);
    await tester.pumpAndSettle();
  }

  testWidgets('an untouched page shows what another device saved', (
    tester,
  ) async {
    await open(tester);

    await store.save(
      elsewhere(opened, {body: const TextValue('Si è spenta.')}),
    );
    await tester.pumpAndSettle();

    expect(textOf(tester, 'body'), 'Si è spenta.');
    await pause(tester);
    expect(store.entryOf(id)!.valueOf(body), const TextValue('Si è spenta.'));
    expect(store.copies, isEmpty);
  });

  testWidgets('typing in one field takes in another device\'s other field', (
    tester,
  ) async {
    await open(tester);
    await tester.enterText(textInput('title'), 'Il faro');

    await store.save(
      elsewhere(opened, {body: const TextValue('Si è spenta.')}),
    );
    await tester.pumpAndSettle();
    await pause(tester);

    final saved = store.entryOf(id)!;
    expect(saved.valueOf(title), const TextValue('Il faro'));
    expect(saved.valueOf(body), const TextValue('Si è spenta.'));
    expect(store.copies, isEmpty);
  });

  testWidgets('a field both changed keeps this one and copies the other', (
    tester,
  ) async {
    await open(tester);
    await tester.enterText(textInput('body'), 'Gira ancora.');

    await store.save(
      elsewhere(opened, {body: const TextValue('Si è spenta.')}),
    );
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Questa nota è cambiata anche su un altro dispositivo. Dove avete '
        'scritto entrambi resta la tua versione; l\'altra è conservata in '
        'una copia.',
      ),
      findsOneWidget,
    );
    await pause(tester);

    expect(store.entryOf(id)!.valueOf(body), const TextValue('Gira ancora.'));
    final copy = store.entryOf(store.copies[id]!)!;
    expect(copy.valueOf(body), const TextValue('Si è spenta.'));
  });

  testWidgets('a page put in the trash elsewhere closes when untouched', (
    tester,
  ) async {
    await open(tester);

    await store.moveToTrash(id);
    await tester.pumpAndSettle();

    expect(find.byType(NoteEditorScreen), findsNothing);
    expect(find.text('apri'), findsOneWidget);
  });

  testWidgets('a page put in the trash elsewhere while typing is kept', (
    tester,
  ) async {
    await open(tester);
    await tester.enterText(textInput('body'), 'Gira ancora.');

    await store.moveToTrash(id);
    await tester.pumpAndSettle();
    await pause(tester);

    expect(find.byType(NoteEditorScreen), findsOneWidget);
    expect(store.entryOf(id)!.valueOf(body), const TextValue('Gira ancora.'));
  });

  group('the merge', () {
    final a = FieldKey('a');
    final b = FieldKey('b');
    const one = TextValue('1');
    const two = TextValue('2');
    const three = TextValue('3');

    test('takes each side\'s own change and names a clash', () {
      final merge = DraftMerge.of(
        base: {a: one, b: one},
        mine: {a: two, b: two},
        theirs: {a: one, b: three},
      );

      expect(merge.values, {a: two, b: two});
      expect(merge.clashes, {b});
    });

    test('a field cleared on the other side is cleared', () {
      final merge = DraftMerge.of(
        base: {a: one, b: one},
        mine: {a: two, b: one},
        theirs: {a: one},
      );

      expect(merge.values, {a: two});
      expect(merge.clashes, isEmpty);
    });

    test('the same change on both sides is no clash', () {
      final merge = DraftMerge.of(
        base: {a: one},
        mine: {a: two},
        theirs: {a: two},
      );

      expect(merge.clashes, isEmpty);
    });
  });
}
