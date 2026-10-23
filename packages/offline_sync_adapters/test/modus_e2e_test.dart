// The app's own domain against the real Worker, served by `wrangler dev`
// with Durable Objects and R2 on this machine: `server/e2e/run.sh` sets
// MODUSNOTE_SERVER and runs this after its own checks. Skipped otherwise.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:collaboration_access_control/collaboration_access_control.dart';
import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:identity_cryptography_adapters/identity_cryptography_adapters.dart';
import 'package:offline_sync/offline_sync.dart';
import 'package:offline_sync_adapters/offline_sync_adapters.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

final _server = Platform.environment['MODUSNOTE_SERVER'];

final class _Clock implements Clock {
  _Clock([this.offset = Duration.zero]);

  final Duration offset;

  @override
  DateTime now() => DateTime.now().toUtc().add(offset);
}

void main() {
  late SodiumSumo sodium;
  late ModusServer server;
  final note = RecordId.parse('0123456789abcdef0123456789abcdef');
  final other = RecordId.parse('fedcba9876543210fedcba9876543210');

  setUpAll(() async {
    sodium = await SodiumSumoInit.init();
    server = ModusServer(
      origin: Uri.parse(_server ?? 'http://127.0.0.1:8787'),
      blake2b: blake2b256,
    );
  });

  VaultKeeper device() {
    final database = sqlite3.openInMemory();
    addTearDown(database.close);
    return VaultKeeper(
      vaults: SqliteVaultStore(database),
      records: (workspace) =>
          SqliteLocalRecordStore(database, workspace: workspace),
      identities: SodiumIdentityService(sodium),
      hasher: SodiumContentHasher(sodium),
      keys: SodiumKeyDerivationService(sodium),
      subkeys: SodiumSubkeyDerivationService(sodium),
      envelopes: SodiumEnvelopeEncryptor(sodium),
      encapsulation: SodiumKeyEncapsulation(sodium),
      clock: _Clock(),
      random: Random.secure(),
      kdf: KdfParameters.interactive,
      gateway: server,
    );
  }

  PasswordSecret secret(List<int> bytes) =>
      SodiumPasswordSecret.fromUtf8Bytes(sodium, Uint8List.fromList(bytes));

  Future<String?> read(UnlockedVault vault, RecordId id) async =>
      switch (await vault.engine.read(id)) {
        RevisionContents(:final bytes) => utf8.decode(bytes),
        _ => null,
      };

  /// Brings a new device in with [role], both sides as the screens do.
  Future<UnlockedVault> bringIn(
    VaultKeeper owner,
    UnlockedVault from,
    VaultKeeper joining,
    Role role,
  ) async {
    final code = InviteCode.random(Random.secure());
    final offering = await owner.offerInvite(
      from,
      secret(code.toBytes()),
      lookup: code.lookup,
      role: role,
    );
    final request = await joining.acceptInvite(
      code: secret(code.toBytes()),
      lookup: code.lookup,
      passphrase: secret(utf8.encode('frase del nuovo dispositivo')),
    );
    expect(await request.poll(), isNull, reason: 'not admitted yet');
    expect(await offering.poll(), isNotNull);
    final vault = (await request.poll())!;
    addTearDown(vault.lock);
    return vault;
  }

  test(
    'found, invite, write both ways, remove, delete',
    () async {
      final aliceKeeper = device();
      final alice = await aliceKeeper.create(
        secret(utf8.encode('frase di Alice, lunga')),
      );
      addTearDown(alice.lock);
      await aliceKeeper.confirm(
        alice,
        secret(utf8.encode('frase di Alice, lunga')),
      );
      await alice.engine.write(note, RevisionContents(utf8.encode('da Alice')));
      final first = await alice.engine.sync();
      expect(first.offline, isFalse);
      expect(first.pushed, 1);

      final bobKeeper = device();
      final bob = await bringIn(aliceKeeper, alice, bobKeeper, Role.editor);
      await bob.engine.sync();
      expect(await read(bob, note), 'da Alice');

      await bob.engine.write(other, RevisionContents(utf8.encode('da Bob')));
      await bob.engine.sync();
      await alice.engine.sync();
      expect(await read(alice, other), 'da Bob');

      await alice.engine.revoke(bob.member);
      await expectLater(
        bob.engine.sync(),
        throwsA(isA<RemovedFromWorkspaceException>()),
      );

      await alice.engine.deleteFromServer();
      await expectLater(
        server.server(alice.signer).heads(alice.workspace),
        throwsA(isA<NotAdmittedException>()),
      );
      expect(await read(alice, note), 'da Alice');
    },
    skip: _server == null ? 'needs MODUSNOTE_SERVER (server/e2e/run.sh)' : null,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'the live channel says when another device writes, and closes when '
    'this one is removed',
    () async {
      final aliceKeeper = device();
      final alice = await aliceKeeper.create(
        secret(utf8.encode('frase di Alice, lunga')),
      );
      addTearDown(alice.lock);
      await aliceKeeper.confirm(
        alice,
        secret(utf8.encode('frase di Alice, lunga')),
      );
      await alice.engine.sync();
      final bob = await bringIn(aliceKeeper, alice, device(), Role.editor);
      await bob.engine.sync();

      final live = ModusLiveChannel(origin: Uri.parse(_server!))
          .open(bob.workspace, bob.signer);
      final signals = StreamIterator(live);
      addTearDown(signals.cancel);
      expect(await signals.moveNext(), isTrue);
      expect(signals.current, const LiveOpened());

      await alice.engine.write(note, RevisionContents(utf8.encode('nuova')));
      await alice.engine.sync();
      expect(await signals.moveNext(), isTrue);
      expect(signals.current, const LiveChanged());

      await alice.engine.revoke(bob.member);
      LiveSignal last;
      do {
        expect(await signals.moveNext(), isTrue);
        last = signals.current;
      } while (last is LiveChanged);
      expect(last, const LiveClosed(LiveClosed.removed));
      expect(await signals.moveNext(), isFalse);
    },
    skip: _server == null ? 'needs MODUSNOTE_SERVER (server/e2e/run.sh)' : null,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'a device whose clock is ten minutes off is told the time and signs '
    'again',
    () async {
      final keeper = device();
      final vault = await keeper.create(secret(utf8.encode('frase di prova!')));
      addTearDown(vault.lock);
      await vault.engine.sync();
      final stranger = SodiumIdentityService(sodium).generateIdentity();
      addTearDown(stranger.dispose);
      final late = RequestSigner(
        identities: SodiumIdentityService(sodium),
        hasher: SodiumContentHasher(sodium),
        device: stranger,
        clock: _Clock(const Duration(minutes: -10)),
        random: Random.secure(),
      );

      // Refused for the clock first (401), which would be final; signed
      // again by the server's time, it is refused as a stranger (403).
      await expectLater(
        server.server(late).heads(vault.workspace),
        throwsA(isA<NotAdmittedException>()),
      );
    },
    skip: _server == null ? 'needs MODUSNOTE_SERVER (server/e2e/run.sh)' : null,
  );

  test('a code no one posted opens nothing', () async {
    final keeper = device();

    await expectLater(
      keeper.acceptInvite(
        code: secret(InviteCode.random(Random.secure()).toBytes()),
        lookup: 'ZZZZZZ',
        passphrase: secret(utf8.encode('frase del nuovo dispositivo')),
      ),
      throwsA(isA<LinkCodeRejectedException>()),
    );
  }, skip: _server == null ? 'needs MODUSNOTE_SERVER' : null);
}
