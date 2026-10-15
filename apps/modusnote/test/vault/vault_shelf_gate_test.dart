import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:identity_cryptography_adapters/identity_cryptography_adapters.dart';
import 'package:modusnote/notes/note_library.dart';
import 'package:modusnote/vault/vault_gate.dart';
import 'package:modusnote/vault/vault_shelf_gate.dart';
import 'package:offline_sync/offline_sync.dart';
import 'package:offline_sync_adapters/offline_sync_adapters.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';
import 'package:sqlite3/sqlite3.dart';

import '../notes/harness.dart';
import 'support.dart';

/// The platform's side of the shelf, in memory: a database per vault, and
/// a record of what was closed and erased.
final class FakeShelfStorage {
  final databases = <ShelfId, Database>{};
  final closed = <ShelfId>[];
  final erased = <ShelfId>[];

  Future<ShelfVault> open(ShelfEntry entry) async {
    final database = databases.putIfAbsent(entry.id, memoryDatabase);
    final keeper = keeperOn(database);
    return ShelfVault(
      build: (switcher) => VaultGate(
        keeper: keeper,
        passwordFrom: (bytes) =>
            SodiumPasswordSecret.fromUtf8Bytes(sodium, bytes),
        catalog: SeedSchemas.catalog,
        switcher: switcher,
      ),
      isEmpty: () async => !await keeper.exists,
      close: () async => closed.add(entry.id),
      erase: () async {
        erased.add(entry.id);
        databases.remove(entry.id)!.close();
      },
    );
  }

  void dispose() {
    for (final database in databases.values) {
      database.close();
    }
  }
}

final shelfButton = find.byKey(const ValueKey('shelf'));
final phraseField = find.byKey(const ValueKey('passphrase'));

void main() {
  setUpAll(loadSodium);
  late Database shelfDatabase;
  late SqliteShelfStore store;
  late FakeShelfStorage storage;

  setUp(() {
    shelfDatabase = memoryDatabase();
    store = SqliteShelfStore(shelfDatabase);
    storage = FakeShelfStorage();
  });
  tearDown(() {
    storage.dispose();
    shelfDatabase.close();
  });

  Widget shelfGate() =>
      VaultShelfGate(store: store, open: storage.open, random: Random(3));

  Future<void> create(WidgetTester tester, String phrase) async {
    await tester.enterText(phraseField, phrase);
    await tester.enterText(
      find.byKey(const ValueKey('passphrase-confirm')),
      phrase,
    );
    final acknowledged = find.byKey(const ValueKey('passphrase-acknowledged'));
    await tester.ensureVisible(acknowledged);
    await tester.tap(acknowledged);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Crea il vault'));
    await tester.tap(find.text('Crea il vault'));
    await tester.pumpAndSettle();
  }

  Future<void> lock(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Blocca'));
    await tester.pumpAndSettle();
  }

  Future<void> openPicker(WidgetTester tester) async {
    await tester.tap(shelfButton);
    await tester.pumpAndSettle();
  }

  Future<void> addVault(WidgetTester tester, String name) async {
    await openPicker(tester);
    await tester.tap(find.byKey(const ValueKey('shelf-add')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('shelf-name')), name);
    await tester.tap(find.byKey(const ValueKey('shelf-name-save')));
    await tester.pumpAndSettle();
  }

  Future<void> pick(WidgetTester tester, ShelfId id) async {
    await openPicker(tester);
    await tester.tap(find.byKey(ValueKey('shelf-$id')));
    await tester.pumpAndSettle();
  }

  testWidgets('a device with one vault opens it under its old storage', (
    tester,
  ) async {
    await pumpApp(tester, shelfGate());
    await tester.pumpAndSettle();

    expect(find.text('Il mio vault'), findsOneWidget);
    expect(storage.databases.keys, [ShelfId.first]);
    await create(tester, 'frase del primo');
    expect(find.byType(NoteLibraryScreen), findsOneWidget);
    expect(shelfButton, findsNothing);
  });

  testWidgets('a new vault has its own database and passphrase', (
    tester,
  ) async {
    await pumpApp(tester, shelfGate());
    await tester.pumpAndSettle();
    await create(tester, 'frase del primo');
    await lock(tester);

    await addVault(tester, '  Band  ');

    final shelf = await store.load();
    final band = shelf.entries.last;
    expect(band.label, 'Band');
    expect(band.scope, 1);
    expect(shelf.lastOpened, band.id);
    expect(storage.closed, [ShelfId.first]);
    expect(find.text('Band'), findsOneWidget);
    expect(find.text('Crea il tuo vault'), findsOneWidget);

    await create(tester, 'frase della band');
    await lock(tester);
    expect(await keeperOn(storage.databases[ShelfId.first]!).exists, isTrue);
    expect(await keeperOn(storage.databases[band.id]!).exists, isTrue);

    // Back to the first vault: the other one's passphrase does not open it.
    await pick(tester, ShelfId.first);
    expect(find.text('Il mio vault'), findsOneWidget);
    await tester.enterText(phraseField, 'frase della band');
    await tester.tap(find.text('Sblocca'));
    await tester.pumpAndSettle();
    expect(find.byType(NoteLibraryScreen), findsNothing);
    await tester.enterText(phraseField, 'frase del primo');
    await tester.tap(find.text('Sblocca'));
    await tester.pumpAndSettle();
    expect(find.byType(NoteLibraryScreen), findsOneWidget);
  });

  testWidgets('the shelf reopens the vault used last', (tester) async {
    await pumpApp(tester, shelfGate());
    await tester.pumpAndSettle();
    await addVault(tester, 'Sogni');

    await pumpApp(tester, const SizedBox());
    await pumpApp(tester, shelfGate());
    await tester.pumpAndSettle();

    expect(find.text('Sogni'), findsOneWidget);
  });

  testWidgets('only an empty vault added later can be removed', (tester) async {
    await pumpApp(tester, shelfGate());
    await tester.pumpAndSettle();
    await openPicker(tester);
    expect(find.byKey(const ValueKey('shelf-remove')), findsNothing);
    await tester.tapAt(Offset.zero);
    await tester.pumpAndSettle();

    await addVault(tester, 'Prova');
    final prova = (await store.load()).lastOpened;
    await openPicker(tester);
    await tester.tap(find.byKey(const ValueKey('shelf-remove')));
    await tester.pumpAndSettle();

    expect(storage.erased, [prova]);
    expect(await store.load(), VaultShelf.initial());
    expect(find.text('Il mio vault'), findsOneWidget);

    await addVault(tester, 'Piena');
    await create(tester, 'frase della piena');
    await lock(tester);
    await openPicker(tester);
    expect(find.byKey(const ValueKey('shelf-remove')), findsNothing);
  });

  testWidgets('a removal is refused when the vault was created meanwhile', (
    tester,
  ) async {
    await pumpApp(tester, shelfGate());
    await tester.pumpAndSettle();
    await addVault(tester, 'Prova');
    final prova = (await store.load()).lastOpened;
    await openPicker(tester);
    // Another tab created it while the picker was up.
    await tester.runAsync(
      () =>
          keeperOn(storage.databases[prova]!)
              .create(passphrase('frase di un altra scheda'))
              .then((v) => v.lock()),
    );
    await tester.tap(find.byKey(const ValueKey('shelf-remove')));
    await tester.pumpAndSettle();

    expect(storage.erased, isEmpty);
    expect((await store.load()).entries, hasLength(2));
  });

  testWidgets('names are one safe line', (tester) async {
    await pumpApp(tester, shelfGate());
    await tester.pumpAndSettle();
    await openPicker(tester);
    await tester.tap(find.byKey(const ValueKey('shelf-add')));
    await tester.pumpAndSettle();

    for (final name in ['   ', 'Note\u202Eexe.txt', 'riga\u0000nascosta']) {
      await tester.enterText(find.byKey(const ValueKey('shelf-name')), name);
      await tester.tap(find.byKey(const ValueKey('shelf-name-save')));
      await tester.pumpAndSettle();
      expect(
        find.text('Scrivi un nome di una riga, al massimo 40 caratteri.'),
        findsOneWidget,
      );
    }
    expect((await store.load()).entries, hasLength(1));
  });

  testWidgets('renaming keeps the vault open where it was', (tester) async {
    await pumpApp(tester, shelfGate());
    await tester.pumpAndSettle();
    await openPicker(tester);
    await tester.tap(find.byKey(ValueKey('shelf-rename-${ShelfId.first}')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('shelf-name')), 'Casa');
    await tester.tap(find.byKey(const ValueKey('shelf-name-save')));
    await tester.pumpAndSettle();

    expect(find.text('Casa'), findsOneWidget);
    expect((await store.load()).current.label, 'Casa');
    expect(storage.closed, isEmpty);
  });

  testWidgets('a full shelf offers no new vault', (tester) async {
    var shelf = VaultShelf.initial();
    for (var i = 1; i < VaultShelf.maxVaults; i++) {
      (shelf, _) = shelf.add('Vault $i', Random(i));
    }
    await store.save(shelf);
    await pumpApp(tester, shelfGate());
    await tester.pumpAndSettle();
    await openPicker(tester);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('shelf-add')),
      100,
      scrollable: find.byType(Scrollable).last,
    );

    final add = tester.widget<ListTile>(
      find.byKey(const ValueKey('shelf-add')),
    );
    expect(add.enabled, isFalse);
    expect(find.text('Questo dispositivo ha già 20 vault.'), findsOneWidget);
  });
}
