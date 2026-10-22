import 'dart:typed_data';

import 'package:collaboration_access_control/collaboration_access_control.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:identity_cryptography_adapters/identity_cryptography_adapters.dart';
import 'package:modusnote/vault/vault_gate.dart';
import 'package:modusnote/vault/vault_note_store.dart';
import 'package:offline_sync/offline_sync.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';
import 'package:sqlite3/sqlite3.dart';

import '../notes/harness.dart';
import '../vault/support.dart';
import '../vault/vault_note_store_test.dart' show first, quickNote;
import 'cloud_support.dart';

PasswordSecret secret(List<int> utf8Bytes) =>
    SodiumPasswordSecret.fromUtf8Bytes(sodium, Uint8List.fromList(utf8Bytes));

Widget gate(Database database, MemorySyncServer server) => VaultGate(
  keeper: keeperOn(database, gateway: server),
  passwordFrom: (bytes) => SodiumPasswordSecret.fromUtf8Bytes(sodium, bytes),
  catalog: SeedSchemas.catalog,
);

/// Lets Argon2id and the server round trips finish under a spinner, which
/// never lets the tester settle.
Future<void> work(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Taps [finder] after scrolling it into view: the forms are taller than
/// a phone held upright.
Future<void> tapOn(WidgetTester tester, Finder finder) async {
  // A field that just took focus may still be scrolling itself into view.
  await tester.pump(const Duration(milliseconds: 300));
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
}

/// Creates the vault on the gate's first screen.
Future<void> createVault(WidgetTester tester) async {
  for (final key in ['passphrase', 'passphrase-confirm']) {
    await tester.enterText(find.byKey(ValueKey(key)), 'frase lunga');
  }
  await tapOn(tester, find.byKey(const ValueKey('passphrase-acknowledged')));
  await tapOn(tester, find.text('Crea il vault'));
  await tester.pumpAndSettle();
}

/// Opens the sync sheet and turns the sync on.
Future<void> turnOnSync(WidgetTester tester) async {
  await tapOn(tester, find.byKey(const ValueKey('cloud')));
  await tester.pumpAndSettle();
  await tapOn(tester, find.byKey(const ValueKey('cloud-enable')));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadSodium);
  late MemorySyncServer server;
  late Database phoneDb;
  late Database browserDb;

  setUp(() {
    server = MemorySyncServer();
    phoneDb = memoryDatabase();
    browserDb = memoryDatabase();
  });
  tearDown(() {
    phoneDb.close();
    browserDb.close();
  });

  /// The phone, outside the UI: a vault with one note on the server.
  Future<UnlockedVault> phoneWithANote() async {
    final vault = await keeperOn(
      phoneDb,
      gateway: server,
    ).create(secret('frase del telefono'.codeUnits));
    addTearDown(vault.lock);
    final store = await VaultNoteStore.open(
      vault.engine,
      catalog: SeedSchemas.catalog,
    );
    await store.save(quickNote(first, 'Dal telefono', DateTime.utc(2026)));
    await vault.engine.sync();
    return vault;
  }

  /// The phone shows [code] for another device of its person.
  Future<InviteOffering> offer(UnlockedVault phone, InviteCode code) =>
      keeperOn(phoneDb, gateway: server).offerInvite(
        phone,
        secret(code.toBytes()),
        lookup: code.lookup,
        role: Role.owner,
      );

  Future<void> typeCode(WidgetTester tester, String code) async {
    await tester.enterText(find.byKey(const ValueKey('join-code')), code);
    await tester.enterText(
      find.byKey(const ValueKey('passphrase')),
      'frase del browser',
    );
    await tester.enterText(
      find.byKey(const ValueKey('passphrase-confirm')),
      'frase del browser',
    );
    await tapOn(tester, find.byKey(const ValueKey('passphrase-acknowledged')));
    await tapOn(tester, find.byKey(const ValueKey('join-submit')));
    await work(tester);
  }

  final code = InviteCode.tryParse('K7MQ4X-T9ABCD-EF01')!;

  group('the new device', () {
    testWidgets('joins with the code and opens on the shared notes, '
        'syncing', (tester) async {
      final phone = await phoneWithANote();
      final offering = await offer(phone, code);
      await pumpApp(tester, gate(browserDb, server));
      await tester.pumpAndSettle();

      await tapOn(tester, find.byKey(const ValueKey('join-vault')));
      await tester.pumpAndSettle();
      await typeCode(tester, code.display.toLowerCase());
      expect(
        find.textContaining('In attesa che l\'altro dispositivo dia accesso'),
        findsOneWidget,
      );

      expect(await offering.poll(), isNotNull);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();

      expect(find.text('Dal telefono'), findsOneWidget);
      expect(find.byTooltip('Sincronizzazione: aggiornato'), findsOneWidget);
    });

    testWidgets('joining waits for the warning to be acknowledged', (
      tester,
    ) async {
      await pumpApp(tester, gate(browserDb, server));
      await tester.pumpAndSettle();
      await tapOn(tester, find.byKey(const ValueKey('join-vault')));
      await tester.pumpAndSettle();
      final submit = find.byKey(const ValueKey('join-submit'));

      expect(find.byKey(const ValueKey('passphrase-warning')), findsOneWidget);
      expect(tester.widget<FilledButton>(submit).onPressed, isNull);
      await tapOn(
        tester,
        find.byKey(const ValueKey('passphrase-acknowledged')),
      );
      await tester.pump();
      expect(tester.widget<FilledButton>(submit).onPressed, isNotNull);
    });

    testWidgets('a wrong code is said so and nothing is created', (
      tester,
    ) async {
      final phone = await phoneWithANote();
      final offering = await offer(phone, code);
      addTearDown(offering.cancel);
      await pumpApp(tester, gate(browserDb, server));
      await tester.pumpAndSettle();
      await tapOn(tester, find.byKey(const ValueKey('join-vault')));
      await tester.pumpAndSettle();

      // The same lookup, the rest of the code wrong.
      await typeCode(tester, 'K7MQ4X-T9ABCD-EF02');
      await tester.pumpAndSettle();

      expect(find.textContaining('Codice errato o scaduto.'), findsOneWidget);
      expect(await keeperOn(browserDb).exists, isFalse);
      expect(server.inviteAnswered, isEmpty);
    });

    testWidgets('something that is not a code is caught before any work', (
      tester,
    ) async {
      await pumpApp(tester, gate(browserDb, server));
      await tester.pumpAndSettle();
      await tapOn(tester, find.byKey(const ValueKey('join-vault')));
      await tester.pumpAndSettle();

      await typeCode(tester, 'K7MQ4-XT9AB');
      await tester.pumpAndSettle();

      expect(
        find.text('Il codice è formato da 16 lettere e cifre.'),
        findsOneWidget,
      );
      // Only the code is wrong, so the passphrase stays to fix it.
      final field = tester.widget<EditableText>(
        find.descendant(
          of: find.byKey(const ValueKey('passphrase')),
          matching: find.byType(EditableText),
        ),
      );
      expect(field.controller.text, 'frase del browser');
      expect(server.signed, isEmpty);
    });

    testWidgets('going back leaves a device with no vault', (tester) async {
      await pumpApp(tester, gate(browserDb, server));
      await tester.pumpAndSettle();
      await tapOn(tester, find.byKey(const ValueKey('join-vault')));
      await tester.pumpAndSettle();

      await tapOn(tester, find.byKey(const ValueKey('join-back')));
      await tester.pumpAndSettle();

      expect(find.text('Crea il vault'), findsOneWidget);
      expect(await keeperOn(browserDb).exists, isFalse);
    });

    testWidgets('a build without a server offers no linking', (tester) async {
      await pumpApp(
        tester,
        VaultGate(
          keeper: keeperOn(browserDb),
          passwordFrom: (bytes) =>
              SodiumPasswordSecret.fromUtf8Bytes(sodium, bytes),
          catalog: SeedSchemas.catalog,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('join-vault')), findsNothing);
    });
  });

  group('the device already in the workspace', () {
    Future<void> openLinkSheet(
      WidgetTester tester, {
      bool offline = false,
    }) async {
      await pumpApp(tester, gate(phoneDb, server));
      await tester.pumpAndSettle();
      await createVault(tester);
      await turnOnSync(tester);
      await tapOn(tester, find.byKey(const ValueKey('link-device')));
      if (offline) server.online = false;
      await work(tester);
    }

    InviteCode shownCode(WidgetTester tester) => InviteCode.tryParse(
      tester
          .widget<SelectableText>(find.byKey(const ValueKey('link-code')))
          .data!,
    )!;

    Future<LinkRequest> answer(InviteCode code) =>
        keeperOn(browserDb, gateway: server).acceptInvite(
          code: secret(code.toBytes()),
          lookup: code.lookup,
          passphrase: secret('frase del browser'.codeUnits),
        );

    testWidgets('shows a code and admits the device that types it, '
        'as an owner', (tester) async {
      await openLinkSheet(tester);
      final code = shownCode(tester);
      expect(find.textContaining('Vale una volta sola'), findsOneWidget);

      final request = await answer(code);
      addTearDown(request.cancel);
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();

      expect(find.byKey(const ValueKey('link-done')), findsOneWidget);
      final joined = await request.poll();
      addTearDown(() => joined?.lock());
      expect(joined, isNotNull);
      expect(server.membershipLog, hasLength(2));
      expect(
        joined!.engine.ledger.workspace.member(joined.member)?.role,
        Role.owner,
      );
    });

    testWidgets('a code that could not be posted can be made again', (
      tester,
    ) async {
      await openLinkSheet(tester, offline: true);
      expect(find.byKey(const ValueKey('link-code')), findsNothing);
      expect(
        find.text('Il server non è raggiungibile. Controlla la connessione.'),
        findsOneWidget,
      );

      server.online = true;
      await tapOn(tester, find.text('Nuovo codice'));
      await work(tester);

      expect(shownCode(tester), isNotNull);
      await tapOn(tester, find.text('Chiudi'));
      await tester.pumpAndSettle();
    });

    testWidgets('closing the sheet withdraws the code', (tester) async {
      await openLinkSheet(tester);
      final code = shownCode(tester);

      await tapOn(tester, find.text('Chiudi'));
      await tester.pumpAndSettle();
      expect(server.closed, contains(code.lookup));

      await expectLater(
        answer(code),
        throwsA(isA<LinkCodeRejectedException>()),
      );
      await tester.pump(const Duration(seconds: 4));
      expect(server.membershipLog, hasLength(1));
    });

    testWidgets('only an owner is offered linking', (tester) async {
      await pumpApp(tester, gate(phoneDb, server));
      await tester.pumpAndSettle();
      await createVault(tester);

      await turnOnSync(tester);

      expect(find.byKey(const ValueKey('link-device')), findsOneWidget);
    });
  });
}
