import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import '../notes/harness.dart';
import '../vault/support.dart';
import 'cloud_gate_test.dart' show cloudButton, cloudGate, lock, turnOn, unlock;
import 'cloud_support.dart';

/// An owner deletes the vault from the server, from the sync sheet: what
/// Google Play asks of an app whose data people can put on a server.
void main() {
  setUpAll(loadSodium);
  late Database database;
  late MemorySyncServer server;

  setUp(() {
    database = memoryDatabase();
    server = MemorySyncServer();
  });
  tearDown(() => database.close());

  Future<void> deleteFromServer(
    WidgetTester tester, {
    bool confirm = true,
  }) async {
    await tester.ensureVisible(find.byKey(const ValueKey('delete-server')));
    await tester.tap(find.byKey(const ValueKey('delete-server')));
    await tester.pumpAndSettle();
    expect(find.text('Eliminare i dati dal server?'), findsOneWidget);
    await tester.tap(
      confirm
          ? find.byKey(const ValueKey('delete-server-confirm'))
          : find.text('Annulla'),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the server forgets the vault, the notes stay and the vault '
      'stops syncing', (tester) async {
    await pumpApp(tester, cloudGate(database, server));
    await unlock(tester, create: true);
    await turnOn(tester);

    await deleteFromServer(tester);

    expect(server.workspaces, isEmpty);
    expect(server.membershipLog, isEmpty);
    expect(find.byKey(const ValueKey('cloud-retired')), findsOneWidget);
    expect(find.byKey(const ValueKey('cloud-enable')), findsNothing);
    expect(find.byKey(const ValueKey('delete-server')), findsNothing);
  });

  testWidgets('a vault deleted from the server stays so on unlock', (
    tester,
  ) async {
    await pumpApp(tester, cloudGate(database, server));
    await unlock(tester, create: true);
    await turnOn(tester);
    await deleteFromServer(tester);
    await lock(tester);
    final before = server.signed.length;

    await pumpApp(tester, cloudGate(database, server));
    await unlock(tester, create: false);
    await tester.tap(cloudButton);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('cloud-retired')), findsOneWidget);
    expect(server.signed, hasLength(before));
  });

  testWidgets('cancelling deletes nothing', (tester) async {
    await pumpApp(tester, cloudGate(database, server));
    await unlock(tester, create: true);
    await turnOn(tester);

    await deleteFromServer(tester, confirm: false);

    expect(server.workspaces, hasLength(1));
    expect(find.byKey(const ValueKey('cloud-retired')), findsNothing);
  });

  testWidgets('offline, nothing is deleted and the sheet says so', (
    tester,
  ) async {
    await pumpApp(tester, cloudGate(database, server));
    await unlock(tester, create: true);
    await turnOn(tester);
    server.online = false;

    await deleteFromServer(tester);

    expect(find.byKey(const ValueKey('delete-server-problem')), findsOneWidget);
    expect(find.textContaining('non è stato eliminato nulla'), findsOneWidget);
    expect(server.workspaces, hasLength(1));
    expect(find.byKey(const ValueKey('cloud-retired')), findsNothing);
  });

  testWidgets('a refusal is said so, and nothing is retired', (tester) async {
    await pumpApp(tester, cloudGate(database, server));
    await unlock(tester, create: true);
    await turnOn(tester);
    server.refuseWith = 400;

    await deleteFromServer(tester);

    expect(
      find.textContaining('non ha accettato la richiesta'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('cloud-retired')), findsNothing);
  });
}
