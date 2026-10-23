import 'package:collaboration_access_control/collaboration_access_control.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modusnote/sync/invite_sheet.dart';
import 'package:modusnote/sync/members_sheet.dart';
import 'package:modusnote/sync/sync_controller.dart';
import 'package:offline_sync/offline_sync.dart';
import 'package:sqlite3/sqlite3.dart';

import '../notes/harness.dart';
import '../vault/support.dart';
import 'cloud_support.dart';
import 'link_gate_test.dart' show gate, secret, tapOn, work;

void main() {
  setUpAll(loadSodium);
  late MemorySyncServer server;
  late Database ownerDb;
  late Database friendDb;
  late UnlockedVault owner;

  setUp(() async {
    server = MemorySyncServer();
    ownerDb = memoryDatabase();
    friendDb = memoryDatabase();
    addTearDown(ownerDb.close);
    addTearDown(friendDb.close);
    owner = await keeperOn(
      ownerDb,
      gateway: server,
    ).create(secret('frase del telefono'.codeUnits));
    addTearDown(owner.lock);
    await keeperOn(
      ownerDb,
      gateway: server,
    ).confirm(owner, secret('frase del telefono'.codeUnits));
    await owner.engine.sync();
  });

  Future<InviteOffering> offer(InviteCode code, Role role) => keeperOn(
    ownerDb,
    gateway: server,
  ).offerInvite(owner, secret(code.toBytes()), lookup: code.lookup, role: role);

  /// The invited person's device, outside the UI.
  Future<LinkRequest> accept(InviteCode code) =>
      keeperOn(friendDb, gateway: server).acceptInvite(
        code: secret(code.toBytes()),
        lookup: code.lookup,
        passphrase: secret('frase di Bea'.codeUnits),
      );

  Future<UnlockedVault> admitted(Role role) async {
    final code = InviteCode.tryParse('K7MQ4X-T9ABC-D2EFG')!;
    final offering = await offer(code, role);
    final request = await accept(code);
    expect(await offering.poll(), isNotNull);
    final vault = (await request.poll())!;
    addTearDown(vault.lock);
    return vault;
  }

  SyncController controllerFor(UnlockedVault vault) {
    final sync = SyncController(
      engine: vault.engine,
      onPulled: () async {},
      enabled: true,
      interval: const Duration(hours: 1),
    );
    addTearDown(sync.dispose);
    return sync;
  }

  Future<void> showMembers(
    WidgetTester tester,
    SyncController sync, {
    VoidCallback? onInvite,
  }) async {
    await pumpApp(
      tester,
      Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () =>
                MembersSheet.show(context, sync, onInvite: onInvite),
            child: const Text('apri'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('apri'));
    await tester.pumpAndSettle();
  }

  group('the invite sheet', () {
    testWidgets('admits the person with the role chosen', (tester) async {
      var invited = 0;
      await pumpApp(
        tester,
        Scaffold(
          body: InviteSheet(offer: offer, onInvited: () => invited++),
        ),
      );
      expect(find.text('Legge e modifica le note.'), findsOneWidget);

      await tester.tap(find.text('Può leggere'));
      await tester.pump();
      expect(
        find.text('Legge le note ma non può modificarle.'),
        findsOneWidget,
      );
      await tapOn(tester, find.byKey(const ValueKey('invite-create')));
      await work(tester);

      final shown = tester
          .widget<SelectableText>(find.byKey(const ValueKey('link-code')))
          .data!;
      final code = InviteCode.tryParse(shown)!;
      expect(shown, code.display);
      final request = await accept(code);
      await tester.pump(const Duration(seconds: 2));
      await work(tester);

      expect(find.byKey(const ValueKey('link-done')), findsOneWidget);
      expect(invited, 1);
      final friend = (await request.poll())!;
      addTearDown(friend.lock);
      expect(
        owner.engine.ledger.workspace.member(friend.member)?.role,
        Role.viewer,
      );
    });

    testWidgets('a code whose lookup another offer holds is made again', (
      tester,
    ) async {
      var offered = 0;
      await pumpApp(
        tester,
        Scaffold(
          body: InviteSheet(
            offer: (code, role) {
              // The first code drawn collides with an open offer.
              if (offered++ == 0) throw const LookupTakenException();
              return offer(code, role);
            },
          ),
        ),
      );

      await tapOn(tester, find.byKey(const ValueKey('invite-create')));
      await work(tester);

      expect(offered, 2);
      expect(find.byKey(const ValueKey('link-code')), findsOneWidget);
    });

    testWidgets('closing the sheet withdraws the code', (tester) async {
      await pumpApp(tester, Scaffold(body: InviteSheet(offer: offer)));
      await tapOn(tester, find.byKey(const ValueKey('invite-create')));
      await work(tester);
      final code = InviteCode.tryParse(
        tester
            .widget<SelectableText>(find.byKey(const ValueKey('link-code')))
            .data!,
      )!;

      await pumpApp(tester, const SizedBox());
      await tester.pump();

      expect(server.closed, contains(code.lookup));
      expect(server.membershipLog, hasLength(1));
    });
  });

  group('the members sheet', () {
    testWidgets('offers an invitation to an owner', (tester) async {
      final sync = controllerFor(owner);
      await sync.syncNow();
      var opened = 0;
      await showMembers(tester, sync, onInvite: () => opened++);

      await tester.ensureVisible(find.byKey(const ValueKey('invite')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('invite')));
      expect(opened, 1);
    });

    testWidgets('says why the invitation waits for a sync', (tester) async {
      final sync = controllerFor(owner);
      await showMembers(tester, sync, onInvite: () {});

      expect(
        tester
            .widget<ButtonStyleButton>(find.byKey(const ValueKey('invite')))
            .onPressed,
        isNull,
      );
      expect(
        find.text('Disponibile quando il vault è sincronizzato.'),
        findsOneWidget,
      );
    });

    testWidgets('a reader sees the members but cannot invite or remove', (
      tester,
    ) async {
      final reader = await admitted(Role.viewer);
      final sync = controllerFor(reader);
      await sync.syncNow();
      await showMembers(tester, sync, onInvite: () {});

      expect(
        find.text(
          'Può leggere · impronta '
          '${reader.member.fingerprint}',
        ),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('invite')), findsNothing);
      expect(find.byKey(ValueKey('remove-${owner.member.hex}')), findsNothing);
    });
  });

  testWidgets('the invited device joins with the role chosen and syncs', (
    tester,
  ) async {
    final code = InviteCode.tryParse('K7MQ4X-T9ABC-D2EFG')!;
    final offering = await offer(code, Role.editor);
    await pumpApp(tester, gate(friendDb, server));
    await tester.pumpAndSettle();

    await tapOn(tester, find.byKey(const ValueKey('join-vault')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('join-code')),
      'k7mq4x t9abc d2efg',
    );
    for (final key in ['passphrase', 'passphrase-confirm']) {
      await tester.enterText(find.byKey(ValueKey(key)), 'frase di Bea');
    }
    await tapOn(tester, find.byKey(const ValueKey('passphrase-acknowledged')));
    await tapOn(tester, find.byKey(const ValueKey('join-submit')));
    await work(tester);

    final member = await offering.poll();
    expect(member, isNotNull);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();

    expect(find.byTooltip('Sincronizzazione: aggiornato'), findsOneWidget);
    expect(owner.engine.ledger.workspace.member(member!)?.role, Role.editor);
  });
}
