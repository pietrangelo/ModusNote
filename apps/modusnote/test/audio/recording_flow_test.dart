import 'package:file/memory.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modusnote/audio/note_recorder.dart';
import 'package:modusnote/notes/note_editor.dart';
import 'package:modusnote/vault/vault_note_store.dart';
import 'package:offline_sync/offline_sync.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import '../notes/harness.dart';
import '../vault/support.dart';
import 'fake_capture.dart';

final guideTrack = FieldKey('guide_track');

List<String> encFiles(MemoryFileSystem files) => [
  if (files.directory('/blobs').existsSync())
    for (final f in files.directory('/blobs').listSync()) f.basename,
];

/// The blob store was opened outside the test's fake clock, so its file
/// operations finish on the real event loop: give them a moment.
Future<void> settleFiles(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 50)),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadSodium);

  late UnlockedVault vault;
  late MemoryFileSystem files;
  late VaultNoteStore store;

  Future<void> openStore({bool denied = false}) async {
    final storage = memoryBlobs();
    files = storage.files;
    var now = DateTime.utc(2026, 10, 11, 9);
    store = await VaultNoteStore.open(
      vault.engine,
      schemas: SeedSchemas.all,
      recorder: NoteRecorder(
        capture: () => FakeCapture(voice(), denied: denied),
        blobs: storage.blobs,
        engine: vault.engine,
        // Each reading is 42 s later: a take lasts exactly 0:42.
        clock: () => now = now.add(const Duration(seconds: 42)),
      ),
    );
  }

  setUp(() async {
    final database = memoryDatabase();
    addTearDown(database.close);
    vault = await keeperOn(database).create(passphrase('frase lunga'));
    addTearDown(vault.lock);
  });

  Future<void> openEditor(WidgetTester tester) => pumpApp(
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
                  initialSchema: SeedSchemas.songSketchV1,
                ),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );

  Future<void> startEditing(WidgetTester tester) async {
    await openEditor(tester);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(textInput('title'), 'Riff');
  }

  Future<void> tapRecord(WidgetTester tester) async {
    await tester.ensureVisible(fieldFinder('guide_track'));
    await tester.tap(
      find.descendant(
        of: fieldFinder('guide_track'),
        matching: find.text('Registra'),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a take recorded in the editor is saved with the note', (
    tester,
  ) async {
    await openStore();
    await startEditing(tester);

    await tapRecord(tester);
    expect(find.text('Registrazione'), findsOneWidget);
    await tester.tap(find.text('Ferma e allega'));
    await tester.pumpAndSettle();

    expect(find.text('Registrazione allegata · 0:42'), findsOneWidget);
    await tester.tap(find.text('Salva'));
    await tester.pumpAndSettle();

    final entry = store.entries.single;
    final blob = (entry.valueOf(guideTrack)! as AudioBlobValue).blob;
    expect(
      store.recordingOf(blob)?.metadata.duration,
      const Duration(seconds: 42),
    );
    expect(encFiles(files), ['${blob.value}.enc']);
  });

  testWidgets('a discarded take leaves the field empty and no blob', (
    tester,
  ) async {
    await openStore();
    await startEditing(tester);

    await tapRecord(tester);
    await tester.tap(find.text('Scarta'));
    await tester.pumpAndSettle();
    await settleFiles(tester);

    expect(find.text('Nessuna registrazione'), findsOneWidget);
    expect(encFiles(files), isEmpty);
  });

  group('adversary', () {
    testWidgets('leaving the editor without saving deletes the take', (
      tester,
    ) async {
      await openStore();
      await startEditing(tester);
      await tapRecord(tester);
      await tester.tap(find.text('Ferma e allega'));
      await tester.pumpAndSettle();
      expect(encFiles(files), hasLength(1));

      Navigator.of(tester.element(find.byType(NoteEditorScreen))).pop();
      await tester.pumpAndSettle();
      await settleFiles(tester);

      expect(encFiles(files), isEmpty);
      expect(store.entries, isEmpty);
    });

    testWidgets('a refused microphone says so and records nothing', (
      tester,
    ) async {
      await openStore(denied: true);
      await startEditing(tester);

      await tapRecord(tester);

      expect(
        find.text(
          'Accesso al microfono negato. Consentilo nelle impostazioni di sistema per registrare.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Chiudi'));
      await tester.pumpAndSettle();
      expect(find.text('Nessuna registrazione'), findsOneWidget);
      expect(encFiles(files), isEmpty);
    });
  });
}
