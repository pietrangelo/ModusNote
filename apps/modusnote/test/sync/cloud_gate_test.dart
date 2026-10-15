import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:identity_cryptography_adapters/identity_cryptography_adapters.dart';
import 'package:modusnote/vault/vault_gate.dart';
import 'package:offline_sync_adapters/offline_sync_adapters.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';
import 'package:sqlite3/sqlite3.dart';

import '../notes/harness.dart';
import '../vault/support.dart';
import 'cloud_support.dart';

/// The app on [database] in a build that names a sync server; a new
/// [account] is a new app process.
Widget cloudGate(
  Database database,
  SyncAccount account,
  MemorySyncServer server,
) => VaultGate(
  keeper: keeperOn(database, server: server),
  passwordFrom: (bytes) => SodiumPasswordSecret.fromUtf8Bytes(sodium, bytes),
  catalog: SeedSchemas.catalog,
  account: account,
);

final cloudButton = find.byKey(const ValueKey('cloud'));

void main() {
  setUpAll(loadSodium);
  late Database database;
  late FakeAuthServer auth;

  setUp(() {
    database = memoryDatabase();
    auth = FakeAuthServer();
  });
  tearDown(() => database.close());

  Future<void> create(WidgetTester tester) async {
    await tester.enterText(
      find.byKey(const ValueKey('passphrase')),
      'frase lunga',
    );
    await tester.enterText(
      find.byKey(const ValueKey('passphrase-confirm')),
      'frase lunga',
    );
    await tester.ensureVisible(
      find.byKey(const ValueKey('passphrase-acknowledged')),
    );
    await tester.tap(find.byKey(const ValueKey('passphrase-acknowledged')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Crea il vault'));
    await tester.tap(find.text('Crea il vault'));
    await tester.pumpAndSettle();
  }

  Future<void> signIn(WidgetTester tester, {String code = goodCode}) async {
    await tester.tap(cloudButton);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('cloud-email')),
      'pietro@example.com',
    );
    await tester.tap(find.text('Invia il codice'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('cloud-code')), code);
    await tester.tap(find.text('Accedi'));
    await tester.pumpAndSettle();
  }

  testWidgets('a build without a server offers no sign-in', (tester) async {
    await pumpApp(
      tester,
      VaultGate(
        keeper: keeperOn(database),
        passwordFrom: (bytes) =>
            SodiumPasswordSecret.fromUtf8Bytes(sodium, bytes),
        catalog: SeedSchemas.catalog,
      ),
    );
    await create(tester);

    expect(cloudButton, findsNothing);
  });

  testWidgets('signing in with the emailed code starts the sync', (
    tester,
  ) async {
    final account = auth.account();
    final server = MemorySyncServer(account.accessToken);
    await pumpApp(tester, cloudGate(database, account, server));
    await create(tester);
    expect(server.workspaces, isEmpty);

    await signIn(tester);

    expect(
      find.text('Accesso effettuato come pietro@example.com'),
      findsOneWidget,
    );
    expect(find.textContaining('Sincronizzato alle'), findsOneWidget);
    expect(server.workspaces, hasLength(1));
    expect(auth.requests, ['/auth/v1/otp', '/auth/v1/verify']);
  });

  testWidgets('the link of a default email, pasted, signs in too', (
    tester,
  ) async {
    final account = auth.account();
    final server = MemorySyncServer(account.accessToken);
    await pumpApp(tester, cloudGate(database, account, server));
    await create(tester);

    await signIn(tester, code: goodLink);

    expect(account.signedIn, isTrue);
    expect(server.workspaces, hasLength(1));
  });

  testWidgets('a link to anywhere else is refused without a request', (
    tester,
  ) async {
    final account = auth.account();
    final server = MemorySyncServer(account.accessToken);
    await pumpApp(tester, cloudGate(database, account, server));
    await create(tester);

    await signIn(
      tester,
      code: goodLink.replaceFirst('project.supabase.co', 'evil.example'),
    );

    expect(find.text('Codice o link errato o scaduto.'), findsOneWidget);
    expect(account.signedIn, isFalse);
    expect(auth.requests, ['/auth/v1/otp']);
  });

  testWidgets('a wrong code is refused and the user stays signed out', (
    tester,
  ) async {
    final account = auth.account();
    final server = MemorySyncServer(account.accessToken);
    await pumpApp(tester, cloudGate(database, account, server));
    await create(tester);

    await signIn(tester, code: '654321');

    expect(find.text('Codice o link errato o scaduto.'), findsOneWidget);
    expect(account.signedIn, isFalse);
    expect(server.workspaces, isEmpty);
  });

  testWidgets('an address that is not one is caught before any request', (
    tester,
  ) async {
    final account = auth.account();
    await pumpApp(
      tester,
      cloudGate(database, account, MemorySyncServer(account.accessToken)),
    );
    await create(tester);
    await tester.tap(cloudButton);
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const ValueKey('cloud-email')), 'pietro');
    await tester.tap(find.text('Invia il codice'));
    await tester.pumpAndSettle();

    expect(find.text('Inserisci un indirizzo email valido.'), findsOneWidget);
    expect(auth.requests, isEmpty);
  });

  testWidgets('an unreachable server is said so', (tester) async {
    final account = auth.account();
    await pumpApp(
      tester,
      cloudGate(database, account, MemorySyncServer(account.accessToken)),
    );
    await create(tester);
    auth.failWith = 503;
    await tester.tap(cloudButton);
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('cloud-email')),
      'pietro@example.com',
    );
    await tester.tap(find.text('Invia il codice'));
    await tester.pumpAndSettle();

    expect(
      find.text('Il server non è raggiungibile. Controlla la connessione.'),
      findsOneWidget,
    );
  });

  testWidgets('the session comes back with the vault after a restart', (
    tester,
  ) async {
    final account = auth.account();
    final server = MemorySyncServer(account.accessToken);
    await pumpApp(tester, cloudGate(database, account, server));
    await create(tester);
    await signIn(tester);
    await tester.tapAt(const Offset(1, 1));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Blocca'));
    await tester.pumpAndSettle();
    expect(account.signedIn, isFalse);

    final restarted = auth.account();
    await pumpApp(
      tester,
      cloudGate(database, restarted, MemorySyncServer(restarted.accessToken)),
    );
    expect(restarted.signedIn, isFalse);
    await tester.enterText(
      find.byKey(const ValueKey('passphrase')),
      'frase lunga',
    );
    await tester.tap(find.text('Sblocca'));
    await tester.pumpAndSettle();

    expect(restarted.signedIn, isTrue);
    expect(restarted.email, 'pietro@example.com');
    expect(
      auth.requests.where((path) => path == '/auth/v1/verify'),
      hasLength(1),
    );
  });

  group('adversary', () {
    testWidgets('the session token is stored sealed, never in the clear', (
      tester,
    ) async {
      final account = auth.account();
      final server = MemorySyncServer(account.accessToken);
      await pumpApp(tester, cloudGate(database, account, server));
      await create(tester);

      await signIn(tester);

      final token = utf8.encode(issuedToken);
      final email = utf8.encode('pietro@example.com');
      final stored = database.select('SELECT envelope FROM vault_settings');
      expect(stored, hasLength(1));
      for (final table
          in database
              .select("SELECT name FROM sqlite_master WHERE type = 'table'")
              .map((row) => row['name'] as String)) {
        for (final row in database.select('SELECT * FROM "$table"')) {
          for (final value in row.values) {
            final bytes = switch (value) {
              final List<int> blob => blob,
              final String text => utf8.encode(text),
              _ => const <int>[],
            };
            expect(_contains(bytes, token), isFalse, reason: table);
            expect(_contains(bytes, email), isFalse, reason: table);
          }
        }
      }
    });

    testWidgets('a damaged stored session means signing in again', (
      tester,
    ) async {
      final account = auth.account();
      final server = MemorySyncServer(account.accessToken);
      await pumpApp(tester, cloudGate(database, account, server));
      await create(tester);
      await signIn(tester);
      await tester.tapAt(const Offset(1, 1));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Blocca'));
      await tester.pumpAndSettle();
      database.execute(
        "UPDATE vault_settings SET envelope = zeroblob(80) WHERE name = 'sync.session'",
      );

      final restarted = auth.account();
      await pumpApp(
        tester,
        cloudGate(database, restarted, MemorySyncServer(restarted.accessToken)),
      );
      await tester.enterText(
        find.byKey(const ValueKey('passphrase')),
        'frase lunga',
      );
      await tester.tap(find.text('Sblocca'));
      await tester.pumpAndSettle();

      expect(cloudButton, findsOneWidget);
      expect(restarted.signedIn, isFalse);
    });
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
