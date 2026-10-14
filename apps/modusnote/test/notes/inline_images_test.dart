import 'package:blob_storage_media/blob_storage_media.dart';
import 'package:file/memory.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modusnote/attachments/note_images.dart';
import 'package:modusnote/notes/attachments/attachments_input.dart';
import 'package:modusnote/notes/editor/inline_picture.dart';
import 'package:modusnote/notes/editor/markdown_controller.dart';
import 'package:modusnote/notes/note_editor.dart';
import 'package:modusnote/vault/vault_note_store.dart';
import 'package:offline_sync/offline_sync.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import '../audio/fake_capture.dart';
import '../vault/support.dart';
import 'harness.dart';
import 'image_support.dart';

final body = FieldKey('body');

List<String> encFiles(MemoryFileSystem files) => [
  if (files.directory('/blobs').existsSync())
    for (final f in files.directory('/blobs').listSync()) f.basename,
];

/// The blob store works on the real event loop: give it a moment.
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
  late FakeChooser chooser;
  late List<Uri> opened;

  setUp(() async {
    final database = memoryDatabase();
    addTearDown(database.close);
    vault = await keeperOn(database).create(passphrase('frase lunga'));
    addTearDown(vault.lock);
    final storage = memoryBlobs();
    files = storage.files;
    chooser = FakeChooser();
    opened = [];
    store = await VaultNoteStore.open(
      vault.engine,
      catalog: SeedSchemas.catalog,
      images: NoteImages(
        blobs: storage.blobs,
        engine: vault.engine,
        chooser: chooser,
        clock: () => DateTime.utc(2026, 10, 13, 21),
      ),
    );
  });

  Future<void> openEditor(WidgetTester tester, {DynamicEntry? entry}) async {
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
                    openLink: (address) async {
                      opened.add(address);
                      return true;
                    },
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
    await tester.enterText(textInput('title'), 'Manuale');
  }

  Future<void> leave(WidgetTester tester) async {
    await tester.pump();
    await tester.tap(find.byType(BackButton));
    await settleFiles(tester);
  }

  MarkdownEditingController controllerOf(WidgetTester tester) =>
      tester.widget<EditableText>(textInput('body')).controller
          as MarkdownEditingController;

  String bodyOf(DynamicEntry entry) => (entry.valueOf(body)! as TextValue).text;

  Future<void> insertPicture(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('insert-image')));
    await settleFiles(tester);
    await settleFiles(tester);
  }

  /// A saved page with one picture in its text, open in the editor again.
  Future<BlobId> savedWithPicture(WidgetTester tester) async {
    await openEditor(tester);
    await tester.enterText(textInput('body'), 'Il palco');
    await insertPicture(tester);
    await leave(tester);
    final saved = store.entries.single;
    return InlineImages.picturesOf(saved).single;
  }

  testWidgets('a picture goes into the text where the cursor is, and is '
      'drawn there', (tester) async {
    await openEditor(tester);
    await tester.enterText(textInput('body'), 'Il palco');

    await insertPicture(tester);

    final text = controllerOf(tester).text;
    final picture = InlineImages.find(text).single;
    expect(text, 'Il palco\n${InlineImages.markdown('', picture.blob)}\n');
    expect(find.byType(InlinePicture), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('Immagine non disponibile'), findsNothing);
    // Every character of the source is still there, offsets unchanged.
    final span = controllerOf(tester).buildTextSpan(
      context: tester.element(textInput('body')),
      withComposing: false,
    );
    expect(span.toPlainText().length, text.length);
    var placeholders = 0;
    span.visitChildren((child) {
      if (child is WidgetSpan) placeholders++;
      return true;
    });
    expect(placeholders, picture.end - picture.start);
    expect(chooser.handedOut.single, everyElement(0));

    await leave(tester);

    final saved = store.entries.single;
    expect(bodyOf(saved), text);
    expect(saved.valueOf(FieldKey('attachments')), isNull);
    expect(
      store.imageOf(picture.blob)!.metadata.info,
      ImageHeader(ImageFormat.png, 1, 1),
    );
    expect(encFiles(files), ['${picture.blob.value}.enc']);
  });

  testWidgets('a saved picture is drawn again, and a tap opens it whole', (
    tester,
  ) async {
    await savedWithPicture(tester);

    await openEditor(tester, entry: store.entries.single);
    await settleFiles(tester);
    expect(find.byType(InlinePicture), findsOneWidget);

    await tester.tap(find.byType(InlinePicture));
    await settleFiles(tester);
    expect(find.byType(ImageViewer), findsOneWidget);
  });

  testWidgets('the cursor in its Markdown shows the source to edit the '
      'caption', (tester) async {
    await openEditor(tester);
    await tester.enterText(textInput('body'), 'Il palco');
    await insertPicture(tester);
    final controller = controllerOf(tester);
    final picture = InlineImages.find(controller.text).single;

    controller.selection = TextSelection.collapsed(offset: picture.start + 2);
    await tester.pump();
    expect(find.byType(InlinePicture), findsNothing);

    controller.value = TextEditingValue(
      text: controller.text.replaceFirst('![]', '![Il palco]'),
      selection: TextSelection.collapsed(
        offset: picture.end + 'Il palco'.length,
      ),
    );
    await settleFiles(tester);
    expect(find.byType(InlinePicture), findsOneWidget);
    expect(find.text('Il palco'), findsWidgets);
  });

  testWidgets('taking the picture out of the text deletes it with the save', (
    tester,
  ) async {
    await savedWithPicture(tester);
    expect(encFiles(files), hasLength(1));

    await openEditor(tester, entry: store.entries.single);
    await tester.enterText(textInput('body'), 'Solo testo');
    await leave(tester);

    expect(InlineImages.picturesOf(store.entries.single), isEmpty);
    expect(encFiles(files), isEmpty);
  });

  testWidgets('a picture pasted into another note stays while either shows '
      'it', (tester) async {
    final blob = await savedWithPicture(tester);
    final first = store.entries.single;

    await openEditor(tester);
    await tester.enterText(
      textInput('body'),
      'Copia\n${InlineImages.markdown('', blob)}\n',
    );
    await leave(tester);
    expect(store.entries, hasLength(2));
    expect(find.text('Salvataggio non riuscito'), findsNothing);

    await openEditor(tester, entry: first);
    await tester.enterText(textInput('body'), 'Senza foto');
    await leave(tester);

    expect(encFiles(files), ['${blob.value}.enc']);
  });

  testWidgets('a picture this vault does not know says so and is not saved', (
    tester,
  ) async {
    await openEditor(tester);
    await tester.enterText(
      textInput('body'),
      InlineImages.markdown('', BlobId('f' * 32)),
    );
    await tester.pump(NoteEditorScreen.autosaveDelay);
    await settleFiles(tester);

    expect(find.text('Immagine non disponibile'), findsOneWidget);
    expect(store.entries, isEmpty);
  });

  testWidgets('a Markdown image with any other address stays text', (
    tester,
  ) async {
    await openEditor(tester);
    await tester.enterText(
      textInput('body'),
      '![x](https://example.org/x.png)',
    );
    await tester.pump();

    expect(find.byType(InlinePicture), findsNothing);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('at most a page worth of pictures is drawn in one text', (
    tester,
  ) async {
    final blob = await savedWithPicture(tester);
    await openEditor(tester);
    final many = List.filled(
      MarkdownEditingController.maxPictures + 5,
      InlineImages.markdown('', blob),
    ).join('\n');
    await tester.enterText(textInput('body'), many);
    await tester.pump();

    expect(
      find.byType(InlinePicture, skipOffstage: false),
      findsNWidgets(MarkdownEditingController.maxPictures),
    );
  });
}
