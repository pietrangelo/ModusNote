import 'dart:typed_data';

import 'package:collaboration_access_control/collaboration_access_control.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:identity_cryptography_adapters/identity_cryptography_adapters.dart';
import 'package:modusnote/vault/vault_gate.dart';
import 'package:offline_sync/offline_sync.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';
import 'package:sqlite3/sqlite3.dart';

import '../notes/harness.dart';
import '../sync/cloud_gate_test.dart' show lock, turnOn, unlock;
import '../sync/cloud_support.dart';
import '../sync/live_link_test.dart' show FakeLiveChannel;
import '../vault/support.dart';

/// The live channel of the gate, every connection one the test drives.
final class _Live implements LiveChannel {
  final fake = FakeLiveChannel();

  @override
  Stream<LiveSignal> open(WorkspaceId workspace, RequestSigner signer) =>
      fake.connect();
}

void main() {
  setUpAll(loadSodium);
  late Database database;
  late MemorySyncServer server;
  late _Live live;

  setUp(() {
    database = memoryDatabase();
    server = MemorySyncServer();
    live = _Live();
  });
  tearDown(() => database.close());

  Widget gate() => VaultGate(
    keeper: keeperOn(database, gateway: server),
    passwordFrom: (bytes) => SodiumPasswordSecret.fromUtf8Bytes(sodium, bytes),
    catalog: SeedSchemas.catalog,
    live: live,
  );

  /// Reads the notice mark the way the gate does, from outside it.
  Future<NoticeMark?> storedMark() async {
    final keeper = keeperOn(database);
    final vault = await keeper.unlock(passphrase('frase lunga'));
    try {
      final bytes = await keeper.loadSetting(vault, 'notices.ledger');
      return bytes == null ? null : NoticeMark.parse(bytes);
    } finally {
      vault.lock();
    }
  }

  Future<void> storeMark(List<int> bytes) async {
    final keeper = keeperOn(database);
    final vault = await keeper.unlock(passphrase('frase lunga'));
    await keeper.saveSetting(
      vault,
      'notices.ledger',
      Uint8List.fromList(bytes),
    );
    vault.lock();
  }

  testWidgets('the first unlock marks the log as seen, and later ones keep '
      'the mark', (tester) async {
    await pumpApp(tester, gate());
    await unlock(tester, create: true);
    await lock(tester);
    expect(await storedMark(), NoticeMark(1));

    await storeMark(NoticeMark(0).toBytes());
    await pumpApp(tester, gate());
    await unlock(tester, create: false);
    await lock(tester);

    expect(await storedMark(), NoticeMark(0));
  });

  testWidgets('a damaged mark is written again', (tester) async {
    await pumpApp(tester, gate());
    await unlock(tester, create: true);
    await lock(tester);
    await storeMark([9, 9]);

    await pumpApp(tester, gate());
    await unlock(tester, create: false);
    await lock(tester);

    expect(await storedMark(), NoticeMark(1));
  });

  testWidgets('the live channel opens once the sync is on, closes in the '
      'background and on lock', (tester) async {
    await pumpApp(tester, gate());
    await unlock(tester, create: true);
    expect(live.fake.connections, isEmpty);

    await turnOn(tester);
    expect(live.fake.connections, hasLength(1));

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    expect(live.fake.cancelled, 1);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(live.fake.connections, hasLength(2));

    await lock(tester);
    expect(live.fake.cancelled, 2);
  });

  testWidgets('the sync sheet and the palette open the notices', (
    tester,
  ) async {
    await pumpApp(tester, gate());
    await unlock(tester, create: true);
    await turnOn(tester);

    await tester.tap(find.byKey(const ValueKey('notices')));
    await tester.pumpAndSettle();

    expect(find.text('Sicurezza del vault'), findsOneWidget);
    expect(find.text('Nessun avviso.'), findsOneWidget);
    await tester.tapAt(const Offset(1, 1));
    await tester.pumpAndSettle();
    await lock(tester);
  });
}
