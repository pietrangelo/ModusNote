import 'dart:typed_data';

import 'package:collaboration_access_control/collaboration_access_control.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:identity_cryptography_adapters/identity_cryptography_adapters.dart';
import 'package:modusnote/sync/cloud_sheet.dart';
import 'package:modusnote/sync/members_sheet.dart';
import 'package:modusnote/sync/sync_controller.dart';
import 'package:offline_sync/offline_sync.dart';
import 'package:sqlite3/sqlite3.dart';

import '../notes/harness.dart';
import '../vault/support.dart';
import 'cloud_support.dart';

PasswordSecret secret(String text) => SodiumPasswordSecret.fromUtf8Bytes(
  sodium,
  Uint8List.fromList(text.codeUnits),
);

void main() {
  setUpAll(loadSodium);
  late MemorySyncServer server;
  late Database phoneDb;
  late Database browserDb;
  late UnlockedVault phone;
  late UnlockedVault browser;
  late SyncController phoneSync;
  late SyncController browserSync;

  /// The phone founds the vault and links the browser, outside the UI.
  Future<void> twoDevices() async {
    server = MemorySyncServer();
    phoneDb = memoryDatabase();
    browserDb = memoryDatabase();
    addTearDown(phoneDb.close);
    addTearDown(browserDb.close);
    phone = await keeperOn(
      phoneDb,
      gateway: server,
    ).create(secret('frase del telefono'));
    addTearDown(phone.lock);
    await keeperOn(
      phoneDb,
      gateway: server,
    ).confirm(phone, secret('frase del telefono'));
    await phone.engine.sync();
    final code = InviteCode.tryParse('K7MQ4X-T9ABC-D2EFG')!;
    final offering = await keeperOn(phoneDb, gateway: server).offerInvite(
      phone,
      secret(String.fromCharCodes(code.toBytes())),
      lookup: code.lookup,
      role: Role.owner,
    );
    final request = await keeperOn(browserDb, gateway: server).acceptInvite(
      code: secret(String.fromCharCodes(code.toBytes())),
      lookup: code.lookup,
      passphrase: secret('frase del browser'),
    );
    await offering.poll();
    browser = (await request.poll())!;
    addTearDown(browser.lock);
    SyncController controller(UnlockedVault vault) {
      final sync = SyncController(
        engine: vault.engine,
        enabled: true,
        onPulled: () async {},
        interval: const Duration(hours: 1),
      );
      addTearDown(sync.dispose);
      return sync;
    }

    phoneSync = controller(phone);
    browserSync = controller(browser);
  }

  Future<void> showMembers(WidgetTester tester, SyncController sync) async {
    await pumpApp(
      tester,
      Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => MembersSheet.show(context, sync),
            child: const Text('apri'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('apri'));
    await tester.pumpAndSettle();
  }

  Finder remove(MemberId member) =>
      find.byKey(ValueKey('remove-${member.hex}'));

  testWidgets('lists both devices, this one first and not removable', (
    tester,
  ) async {
    await twoDevices();
    await showMembers(tester, phoneSync);

    expect(find.text('Questo dispositivo'), findsOneWidget);
    expect(find.text('Dispositivo'), findsOneWidget);
    expect(
      find.text('Proprietario · impronta ${phone.member.fingerprint}'),
      findsOneWidget,
    );
    expect(remove(phone.member), findsNothing);
    expect(remove(browser.member), findsOneWidget);
  });

  testWidgets('shows the member log in a line both devices can compare', (
    tester,
  ) async {
    await twoDevices();
    await showMembers(tester, phoneSync);

    final fingerprint = phone.engine.ledger.fingerprint;
    expect(browser.engine.ledger.fingerprint, fingerprint);
    expect(
      find.text('Registro dei membri: 2 record · ${fingerprint.signature}'),
      findsOneWidget,
    );
    expect(
      find.text(
        'Sincronizza i tuoi dispositivi, poi confronta: devono mostrare tutti '
        'la stessa riga. Se una resta diversa, il server potrebbe nascondere '
        'dei record a quel dispositivo.',
      ),
      findsOneWidget,
      reason: 'a device that has not synced yet shows another line too',
    );
  });

  testWidgets('removing a device after confirming rotates the key', (
    tester,
  ) async {
    await twoDevices();
    await showMembers(tester, phoneSync);

    await tester.tap(remove(browser.member));
    await tester.pumpAndSettle();
    expect(find.text('Rimuovere questo dispositivo?'), findsOneWidget);
    expect(find.textContaining(browser.member.fingerprint), findsNWidgets(2));
    await tester.tap(find.byKey(const ValueKey('remove-confirm')));
    await tester.pumpAndSettle();

    expect(find.text('Dispositivo'), findsNothing);
    expect(find.text('Dispositivo rimosso.'), findsOneWidget);
    expect(phone.engine.currentEpoch, KeyEpoch(1));
    expect(server.membershipLog.last.change, MemberRevoked(browser.member));
  });

  testWidgets('cancelling removes nothing', (tester) async {
    await twoDevices();
    await showMembers(tester, phoneSync);

    await tester.tap(remove(browser.member));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Annulla'));
    await tester.pumpAndSettle();

    expect(find.text('Dispositivo'), findsOneWidget);
    expect(server.membershipLog, hasLength(2));
  });

  testWidgets('offline, the device stays and the sheet says so', (
    tester,
  ) async {
    await twoDevices();
    await showMembers(tester, phoneSync);
    server.online = false;

    await tester.tap(remove(browser.member));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('remove-confirm')));
    await tester.pumpAndSettle();

    expect(find.text('Dispositivo'), findsOneWidget);
    expect(
      find.text(
        'Per rimuovere un dispositivo serve il server. '
        'Collegati e riprova.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('the removed device learns it and says so', (tester) async {
    await twoDevices();
    await phoneSync.revoke(browser.member);

    await browserSync.syncNow();
    await pumpApp(tester, Scaffold(body: CloudSheet(sync: browserSync)));

    expect(browserSync.problem, SyncProblem.removed);
    expect(
      find.textContaining('Un altro dispositivo ha rimosso questo dal vault'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('members')));
    await tester.pumpAndSettle();
    expect(remove(phone.member), findsNothing);
  });
}
