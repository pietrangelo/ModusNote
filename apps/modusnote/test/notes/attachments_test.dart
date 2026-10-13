import 'dart:convert';
import 'dart:typed_data';

import 'package:blob_storage_media/blob_storage_media.dart';
import 'package:file/memory.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modusnote/attachments/note_images.dart';
import 'package:modusnote/notes/note_editor.dart';
import 'package:modusnote/vault/vault_note_store.dart';
import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:offline_sync/offline_sync.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import '../audio/fake_capture.dart';
import '../vault/support.dart';
import 'harness.dart';
import 'image_support.dart';

final attachments = FieldKey('attachments');

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

  Future<void> tapButton(WidgetTester tester, String label) async {
    final button = find.descendant(
      of: fieldFinder('attachments'),
      matching: find.text(label),
    );
    await tester.ensureVisible(button);
    await tester.tap(button);
  }

  Future<void> leave(WidgetTester tester) async {
    await tester.pump();
    await tester.tap(find.byType(BackButton));
    await settleFiles(tester);
  }

  testWidgets('a picture is sealed, shown and saved with the page', (
    tester,
  ) async {
    await openEditor(tester);

    await tapButton(tester, 'Aggiungi immagine');
    await settleFiles(tester);
    await settleFiles(tester);

    expect(find.byType(Image), findsOneWidget);
    expect(find.text('Questa immagine è danneggiata'), findsNothing);
    // The bytes handed over are wiped once sealed.
    expect(chooser.handedOut.single, everyElement(0));

    await leave(tester);

    final entry = store.entries.single;
    final value = entry.valueOf(attachments)! as AttachmentsValue;
    final blob = (value.items.single as ImageAttachment).blob;
    final image = store.imageOf(blob)!;
    expect(image.metadata.info, ImageHeader(ImageFormat.png, 1, 1));
    expect(image.metadata.addedAt, DateTime.utc(2026, 10, 13, 21));
    expect(encFiles(files), ['${blob.value}.enc']);
    final sealed = files.file('/blobs/${blob.value}.enc').readAsBytesSync();
    expect(_contains(sealed, 'IHDR'.codeUnits), isFalse);
  });

  testWidgets('a file that is not a picture is refused, and nothing kept', (
    tester,
  ) async {
    chooser.next = () => Uint8List.fromList(
      utf8.encode('<svg xmlns="http://www.w3.org/2000/svg"/>'),
    );
    await openEditor(tester);

    await tapButton(tester, 'Aggiungi immagine');
    await settleFiles(tester);

    expect(
      find.text(
        'Solo immagini PNG, JPEG, GIF e WebP, fino a 32 MB e 50 megapixel',
      ),
      findsOneWidget,
    );
    expect(find.byType(Image), findsNothing);
    expect(encFiles(files), isEmpty);
  });

  testWidgets('cancelling the picker changes nothing', (tester) async {
    chooser.next = () => null;
    await openEditor(tester);

    await tapButton(tester, 'Aggiungi immagine');
    await settleFiles(tester);

    expect(find.byType(Image), findsNothing);
    expect(encFiles(files), isEmpty);
  });

  testWidgets('a picture removed from a saved page is deleted with the save', (
    tester,
  ) async {
    await openEditor(tester);
    await tapButton(tester, 'Aggiungi immagine');
    await settleFiles(tester);
    await leave(tester);
    expect(encFiles(files), hasLength(1));

    await openEditor(tester, entry: store.entries.single);
    await settleFiles(tester);
    final menu = find.descendant(
      of: fieldFinder('attachments'),
      matching: find.byIcon(Icons.more_vert),
    );
    await tester.ensureVisible(menu);
    await tester.tap(menu);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rimuovi'));
    await tester.pumpAndSettle();
    await leave(tester);

    expect(store.entries.single.valueOf(attachments), isNull);
    expect(encFiles(files), isEmpty);
  });

  testWidgets('a link is kept as text and opens only once confirmed', (
    tester,
  ) async {
    await openEditor(tester);

    await tapButton(tester, 'Aggiungi link');
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('link-address-field')),
      'javascript:alert(1)',
    );
    await tester.tap(find.text('Salva'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Solo indirizzi http e https, senza spazi né lettere di altri alfabeti',
      ),
      findsOneWidget,
    );

    await tester.enterText(
      find.byKey(const ValueKey('link-address-field')),
      'example.org/guida',
    );
    await tester.enterText(
      find.byKey(const ValueKey('link-title-field')),
      'Guida',
    );
    await tester.tap(find.text('Salva'));
    await tester.pumpAndSettle();

    // Title and site, never the title alone.
    expect(find.text('Guida'), findsOneWidget);
    expect(find.text('example.org'), findsOneWidget);
    expect(opened, isEmpty);

    await tester.tap(find.text('Guida'));
    await tester.pumpAndSettle();
    expect(find.text('Aprire questo indirizzo?'), findsOneWidget);
    expect(find.text('https://example.org/guida'), findsOneWidget);
    await tester.tap(find.text('Annulla'));
    await tester.pumpAndSettle();
    expect(opened, isEmpty);

    await tester.tap(find.text('Guida'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Apri'));
    await tester.pumpAndSettle();
    expect(opened, [Uri.parse('https://example.org/guida')]);

    await leave(tester);
    expect(
      store.entries.single.valueOf(attachments),
      AttachmentsValue([WebLink('https://example.org/guida', title: 'Guida')]),
    );
  });

  testWidgets('a picture this device cannot open says so', (tester) async {
    final page = switch (DynamicEntry.create(
      schema: SeedSchemas.documentV1,
      id: EntryId('d' * 32),
      attributes: {
        FieldKey('title'): const TextValue('Pagina'),
        attachments: AttachmentsValue([ImageAttachment(BlobId('f' * 32))]),
      },
      at: DateTime.utc(2026, 10, 13),
    )) {
      Valid(:final value) => value,
      Invalid(:final violations) => throw StateError('$violations'),
    };
    // Metadata for a blob that is on no device yet.
    await store.save(
      page,
      pictures: [
        KeyedImage(
          epoch: vault.engine.currentEpoch,
          metadata: ImageMetadata(
            blob: SealedBlob(
              id: BlobId('f' * 32),
              keyId: SubkeyId.fromBytes(List.filled(SubkeyId.length, 1)),
              plaintextLength: pixel.length,
            ),
            info: ImageHeader(ImageFormat.png, 1, 1),
            addedAt: DateTime.utc(2026, 10, 13),
          ),
        ),
      ],
    );

    await openEditor(tester, entry: store.entries.single);
    await settleFiles(tester);

    expect(
      find.text('Non ancora scaricata: collegati per vederla'),
      findsOneWidget,
    );
  });
}

bool _contains(List<int> haystack, List<int> needle) {
  outer:
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return true;
  }
  return false;
}
