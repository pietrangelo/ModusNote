import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:identity_cryptography_adapters/identity_cryptography_adapters.dart';
import 'package:modusnote/vault/vault_gate.dart';
import 'package:modusnote/vault/vault_note_store.dart';
import 'package:offline_sync/offline_sync.dart';
import 'package:offline_sync_adapters/offline_sync_adapters.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';
import 'package:sqlite3/sqlite3.dart';

import '../notes/harness.dart';
import '../vault/support.dart';
import '../vault/vault_note_store_test.dart' show first, quickNote;
import 'cloud_support.dart';

PasswordSecret secret(List<int> utf8Bytes) =>
    SodiumPasswordSecret.fromUtf8Bytes(sodium, Uint8List.fromList(utf8Bytes));

Widget gate(Database database, SyncAccount account, MemorySyncServer server) =>
    VaultGate(
      keeper: keeperOn(database, server: server),
      passwordFrom: (bytes) =>
          SodiumPasswordSecret.fromUtf8Bytes(sodium, bytes),
      catalog: SeedSchemas.catalog,
      account: account,
    );

const email = 'pietro@example.com';

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
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
}

void main() {
  setUpAll(loadSodium);
  late FakeAuthServer auth;
  late SyncAccount phoneAccount;
  late MemorySyncServer server;
  late Database phoneDb;
  late Database browserDb;

  setUp(() async {
    auth = FakeAuthServer();
    phoneAccount = auth.account()..attach(null, persist: (_) async {});
    await phoneAccount.signIn(email, goodCode);
    server = MemorySyncServer(phoneAccount.accessToken);
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
      server: server,
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

  Future<void> signIn(WidgetTester tester) async {
    await tester.enterText(find.byKey(const ValueKey('cloud-email')), email);
    await tapOn(tester, find.text('Invia il codice'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('cloud-code')), goodCode);
    await tapOn(tester, find.text('Accedi'));
    await tester.pumpAndSettle();
  }

  Future<void> typeLink(WidgetTester tester, String code) async {
    await tester.enterText(find.byKey(const ValueKey('join-code')), code);
    await tester.enterText(
      find.byKey(const ValueKey('passphrase')),
      'frase del browser',
    );
    await tester.enterText(
      find.byKey(const ValueKey('passphrase-confirm')),
      'frase del browser',
    );
    await tapOn(tester, find.byKey(const ValueKey('join-submit')));
    await work(tester);
  }

  group('the new device', () {
    testWidgets('joins with the code and opens on the shared notes', (
      tester,
    ) async {
      final phone = await phoneWithANote();
      final code = LinkCode.tryParse('K7MQ4-XT9AB')!;
      final offering = await keeperOn(
        phoneDb,
        server: server,
      ).offerLink(phone, secret(code.toBytes()));
      await pumpApp(tester, gate(browserDb, auth.account(), server));
      await tester.pumpAndSettle();

      await tapOn(tester, find.byKey(const ValueKey('join-vault')));
      await tester.pumpAndSettle();
      await signIn(tester);
      await typeLink(tester, 'k7mq4 xt9ab');
      expect(
        find.text('In attesa che l\'altro dispositivo faccia entrare questo…'),
        findsOneWidget,
      );

      expect(await offering.poll(), isNotNull);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();

      expect(find.text('Dal telefono'), findsOneWidget);
      await tapOn(tester, find.byKey(const ValueKey('cloud')));
      await tester.pumpAndSettle();
      expect(find.text('Accesso effettuato come $email'), findsOneWidget);
    });

    testWidgets('a wrong code is said so and nothing is created', (
      tester,
    ) async {
      final phone = await phoneWithANote();
      final offering = await keeperOn(
        phoneDb,
        server: server,
      ).offerLink(phone, secret(LinkCode.tryParse('K7MQ4-XT9AB')!.toBytes()));
      addTearDown(offering.cancel);
      await pumpApp(tester, gate(browserDb, auth.account(), server));
      await tester.pumpAndSettle();
      await tapOn(tester, find.byKey(const ValueKey('join-vault')));
      await tester.pumpAndSettle();
      await signIn(tester);

      await typeLink(tester, 'K7MQ4-XT9AC');
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Codice errato o scaduto. Controlla quello sull\'altro dispositivo.',
        ),
        findsOneWidget,
      );
      expect(await keeperOn(browserDb).exists, isFalse);
      expect(server.answered, isEmpty);
    });

    testWidgets('something that is not a code is caught before any work', (
      tester,
    ) async {
      await pumpApp(tester, gate(browserDb, auth.account(), server));
      await tester.pumpAndSettle();
      await tapOn(tester, find.byKey(const ValueKey('join-vault')));
      await tester.pumpAndSettle();
      await signIn(tester);

      await typeLink(tester, 'K7MQ4');
      await tester.pumpAndSettle();

      expect(
        find.text('Il codice è formato da 10 lettere e cifre.'),
        findsOneWidget,
      );
    });

    testWidgets('going back leaves a device with no vault, signed out', (
      tester,
    ) async {
      final account = auth.account();
      await pumpApp(tester, gate(browserDb, account, server));
      await tester.pumpAndSettle();
      await tapOn(tester, find.byKey(const ValueKey('join-vault')));
      await tester.pumpAndSettle();
      await signIn(tester);

      await tapOn(tester, find.byKey(const ValueKey('join-back')));
      await tester.pumpAndSettle();

      expect(find.text('Crea il vault'), findsOneWidget);
      expect(account.signedIn, isFalse);
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
      await pumpApp(tester, gate(phoneDb, auth.account(), server));
      await tester.pumpAndSettle();
      for (final key in ['passphrase', 'passphrase-confirm']) {
        await tester.enterText(find.byKey(ValueKey(key)), 'frase lunga');
      }
      await tapOn(tester, find.text('Crea il vault'));
      await tester.pumpAndSettle();
      await tapOn(tester, find.byKey(const ValueKey('cloud')));
      await tester.pumpAndSettle();
      await signIn(tester);
      await tapOn(tester, find.byKey(const ValueKey('link-device')));
      if (offline) server.online = false;
      await work(tester);
    }

    String shownCode(WidgetTester tester) => tester
        .widget<SelectableText>(find.byKey(const ValueKey('link-code')))
        .data!;

    testWidgets('shows a code and admits the device that types it', (
      tester,
    ) async {
      await openLinkSheet(tester);
      final code = LinkCode.tryParse(shownCode(tester))!;
      expect(find.textContaining('Vale una volta sola'), findsOneWidget);

      final request = await keeperOn(browserDb, server: server).join(
        code: secret(code.toBytes()),
        passphrase: secret('frase del browser'.codeUnits),
      );
      addTearDown(request.cancel);
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();

      expect(find.byKey(const ValueKey('link-done')), findsOneWidget);
      final joined = await request.poll();
      addTearDown(() => joined?.lock());
      expect(joined, isNotNull);
      expect(server.membershipLog, hasLength(2));
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

      expect(LinkCode.tryParse(shownCode(tester)), isNotNull);
      await tapOn(tester, find.text('Chiudi'));
      await tester.pumpAndSettle();
    });

    testWidgets('closing the sheet withdraws the code', (tester) async {
      await openLinkSheet(tester);
      final code = LinkCode.tryParse(shownCode(tester))!;

      await tapOn(tester, find.text('Chiudi'));
      await tester.pumpAndSettle();
      final request = await keeperOn(browserDb, server: server).join(
        code: secret(code.toBytes()),
        passphrase: secret('frase del browser'.codeUnits),
      );
      addTearDown(request.cancel);
      await tester.pump(const Duration(seconds: 4));

      expect(server.membershipLog, hasLength(1));
    });
  });
}
