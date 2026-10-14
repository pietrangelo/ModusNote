import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import '../notes/harness.dart';
import '../vault/support.dart';
import 'cloud_gate_test.dart' show cloudButton, cloudGate;
import 'cloud_support.dart';

/// Deleting the sync account from the sync sheet, as Google Play requires
/// of an app that creates accounts.
void main() {
  setUpAll(loadSodium);
  late Database database;
  late FakeAuthServer auth;

  setUp(() {
    database = memoryDatabase();
    auth = FakeAuthServer();
  });
  tearDown(() => database.close());

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
    }
    await tester.tap(find.text(create ? 'Crea il vault' : 'Sblocca'));
    await tester.pumpAndSettle();
  }

  Future<void> signIn(WidgetTester tester) async {
    await tester.tap(cloudButton);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('cloud-email')),
      'someone@example.com',
    );
    await tester.tap(find.text('Invia il codice'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('cloud-code')), goodCode);
    await tester.tap(find.text('Accedi'));
    await tester.pumpAndSettle();
  }

  Future<void> deleteAccount(WidgetTester tester, {bool confirm = true}) async {
    await tester.ensureVisible(find.byKey(const ValueKey('delete-account')));
    await tester.tap(find.byKey(const ValueKey('delete-account')));
    await tester.pumpAndSettle();
    expect(find.text("Eliminare l'account?"), findsOneWidget);
    await tester.tap(
      confirm
          ? find.byKey(const ValueKey('delete-account-confirm'))
          : find.text('Annulla'),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the account goes, the notes stay and the vault stops syncing', (
    tester,
  ) async {
    final account = auth.account();
    final server = MemorySyncServer(account.accessToken);
    await pumpApp(tester, cloudGate(database, account, server));
    await unlock(tester, create: true);
    await signIn(tester);

    await deleteAccount(tester);

    expect(auth.requests.last, '/functions/v1/delete-account');
    expect(account.signedIn, isFalse);
    expect(find.byKey(const ValueKey('cloud-retired')), findsOneWidget);
    expect(find.byKey(const ValueKey('cloud-email')), findsNothing);
    expect(find.byKey(const ValueKey('delete-account')), findsNothing);
  });

  testWidgets('a vault whose account was deleted stays retired on unlock', (
    tester,
  ) async {
    final account = auth.account();
    await pumpApp(
      tester,
      cloudGate(database, account, MemorySyncServer(account.accessToken)),
    );
    await unlock(tester, create: true);
    await signIn(tester);
    await deleteAccount(tester);
    await tester.tapAt(const Offset(1, 1));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Blocca'));
    await tester.pumpAndSettle();

    final restarted = auth.account();
    await pumpApp(
      tester,
      cloudGate(database, restarted, MemorySyncServer(restarted.accessToken)),
    );
    await unlock(tester, create: false);
    await tester.tap(cloudButton);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('cloud-retired')), findsOneWidget);
    expect(find.byKey(const ValueKey('cloud-email')), findsNothing);
    expect(restarted.signedIn, isFalse);
  });

  testWidgets('cancelling deletes nothing', (tester) async {
    final account = auth.account();
    await pumpApp(
      tester,
      cloudGate(database, account, MemorySyncServer(account.accessToken)),
    );
    await unlock(tester, create: true);
    await signIn(tester);

    await deleteAccount(tester, confirm: false);

    expect(auth.requests, isNot(contains('/functions/v1/delete-account')));
    expect(account.signedIn, isTrue);
  });

  testWidgets('offline, the account stays and the sheet says so', (
    tester,
  ) async {
    final account = auth.account();
    await pumpApp(
      tester,
      cloudGate(database, account, MemorySyncServer(account.accessToken)),
    );
    await unlock(tester, create: true);
    await signIn(tester);
    auth.failWith = 503;

    await deleteAccount(tester);

    expect(
      find.byKey(const ValueKey('delete-account-problem')),
      findsOneWidget,
    );
    expect(find.textContaining('non è stato eliminato'), findsOneWidget);
    expect(account.signedIn, isTrue);
    expect(find.byKey(const ValueKey('cloud-retired')), findsNothing);
  });

  testWidgets('a refused session is said so, and nothing is retired', (
    tester,
  ) async {
    final account = auth.account();
    await pumpApp(
      tester,
      cloudGate(database, account, MemorySyncServer(account.accessToken)),
    );
    await unlock(tester, create: true);
    await signIn(tester);
    auth.failWith = 401;

    await deleteAccount(tester);

    expect(find.textContaining('Esci, accedi di nuovo'), findsOneWidget);
    expect(find.byKey(const ValueKey('cloud-retired')), findsNothing);
  });
}
