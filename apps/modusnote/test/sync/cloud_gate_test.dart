import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:identity_cryptography_adapters/identity_cryptography_adapters.dart';
import 'package:modusnote/vault/vault_gate.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';
import 'package:sqlite3/sqlite3.dart';

import '../notes/harness.dart';
import '../vault/support.dart';
import 'cloud_support.dart';

/// The app on [database] in a build that names a sync server; a new gate
/// is a new app process.
Widget cloudGate(Database database, MemorySyncServer server) => VaultGate(
  keeper: keeperOn(database, gateway: server),
  passwordFrom: (bytes) => SodiumPasswordSecret.fromUtf8Bytes(sodium, bytes),
  catalog: SeedSchemas.catalog,
);

final cloudButton = find.byKey(const ValueKey('cloud'));

/// Creates the vault, or unlocks it, on the gate's form.
Future<void> unlock(WidgetTester tester, {required bool create}) async {
  await tester.enterText(
    find.byKey(const ValueKey('passphrase')),
    'frase lunga',
  );
  if (create) {
    await tester.enterText(
      find.byKey(const ValueKey('passphrase-confirm')),
      'frase lunga',
    );
    await tester.ensureVisible(
      find.byKey(const ValueKey('passphrase-acknowledged')),
    );
    await tester.tap(find.byKey(const ValueKey('passphrase-acknowledged')));
    await tester.pumpAndSettle();
  }
  final submit = find.text(create ? 'Crea il vault' : 'Sblocca');
  await tester.ensureVisible(submit);
  await tester.tap(submit);
  await tester.pumpAndSettle();
}

/// Opens the sync sheet and turns the sync on.
Future<void> turnOn(WidgetTester tester) async {
  await tester.tap(cloudButton);
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('cloud-enable')));
  await tester.pumpAndSettle();
}

/// Locks the vault from the library.
Future<void> lock(WidgetTester tester) async {
  await tester.tapAt(const Offset(1, 1));
  await tester.pumpAndSettle();
  await tester.tap(find.byTooltip('Blocca'));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadSodium);
  late Database database;
  late MemorySyncServer server;

  setUp(() {
    database = memoryDatabase();
    server = MemorySyncServer();
  });
  tearDown(() => database.close());

  testWidgets('a build without a server offers no sync', (tester) async {
    await pumpApp(
      tester,
      VaultGate(
        keeper: keeperOn(database),
        passwordFrom: (bytes) =>
            SodiumPasswordSecret.fromUtf8Bytes(sodium, bytes),
        catalog: SeedSchemas.catalog,
      ),
    );
    await unlock(tester, create: true);

    expect(cloudButton, findsNothing);
  });

  testWidgets('a new vault stays on the device until its sync is turned on', (
    tester,
  ) async {
    await pumpApp(tester, cloudGate(database, server));
    await unlock(tester, create: true);

    expect(find.byTooltip('Sincronizzazione spenta'), findsOneWidget);
    expect(server.signed, isEmpty);
    await tester.tap(cloudButton);
    await tester.pumpAndSettle();
    expect(find.textContaining('La sincronizzazione è spenta'), findsOneWidget);
    expect(find.byKey(const ValueKey('members')), findsNothing);
  });

  testWidgets('turning it on publishes the vault and shows the state', (
    tester,
  ) async {
    await pumpApp(tester, cloudGate(database, server));
    await unlock(tester, create: true);

    await turnOn(tester);

    expect(find.textContaining('Sincronizzato alle'), findsOneWidget);
    expect(find.byKey(const ValueKey('cloud-enable')), findsNothing);
    expect(server.workspaces, hasLength(1));
    await tester.tapAt(const Offset(1, 1));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Sincronizzazione: aggiornato'), findsOneWidget);
  });

  testWidgets('the sync stays on after a restart', (tester) async {
    await pumpApp(tester, cloudGate(database, server));
    await unlock(tester, create: true);
    await turnOn(tester);
    await lock(tester);

    await pumpApp(tester, cloudGate(database, server));
    await unlock(tester, create: false);

    expect(find.byTooltip('Sincronizzazione: aggiornato'), findsOneWidget);
  });

  testWidgets('an unreachable server leaves the edits queued, and says so', (
    tester,
  ) async {
    server.online = false;
    await pumpApp(tester, cloudGate(database, server));
    await unlock(tester, create: true);

    await turnOn(tester);

    expect(find.textContaining('non è raggiungibile'), findsOneWidget);
    expect(server.workspaces, isEmpty);
  });

  group('a vault that synced through an account', () {
    Future<void> legacy(WidgetTester tester, Uint8List session) async {
      await pumpApp(tester, cloudGate(database, server));
      await unlock(tester, create: true);
      await lock(tester);
      // What the app before this one sealed: no way to write it from here
      // but through the keeper, as that app did.
      final keeper = keeperOn(database);
      final vault = await keeper.unlock(passphrase('frase lunga'));
      await keeper.saveSetting(vault, 'sync.session', session);
      vault.lock();
    }

    testWidgets('keeps syncing, and its session is dropped', (tester) async {
      await legacy(tester, Uint8List.fromList(List.filled(40, 7)));

      await pumpApp(tester, cloudGate(database, server));
      await unlock(tester, create: false);

      expect(find.byTooltip('Sincronizzazione: aggiornato'), findsOneWidget);
      final rows = database.select(
        "SELECT name FROM vault_settings WHERE name LIKE 'sync.%'",
      );
      // Where it synced now, next to the switch; the session is gone.
      expect(
        rows.map((row) => row['name']),
        unorderedEquals(['sync.enabled', 'sync.server']),
      );
    });
  });

  group('adversary', () {
    testWidgets('a damaged mark counts as on: the person turned it on once', (
      tester,
    ) async {
      await pumpApp(tester, cloudGate(database, server));
      await unlock(tester, create: true);
      await turnOn(tester);
      await lock(tester);
      database.execute(
        "UPDATE vault_settings SET envelope = zeroblob(80) "
        "WHERE name = 'sync.enabled'",
      );

      await pumpApp(tester, cloudGate(database, server));
      await unlock(tester, create: false);

      expect(find.byTooltip('Sincronizzazione: aggiornato'), findsOneWidget);
    });
  });
}
