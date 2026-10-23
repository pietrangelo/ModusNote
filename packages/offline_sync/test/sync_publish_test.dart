import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:collaboration_access_control/collaboration_access_control.dart';
import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:identity_cryptography_adapters/identity_cryptography_adapters.dart';
import 'package:offline_sync/offline_sync.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:test/test.dart';

import 'fakes.dart';

late SodiumSumo sodium;

void main() {
  late FakeVaultStore vaults;
  late FakeLocalStore records;
  late FakeSyncServer server;
  final note = RecordId.parse('0123456789abcdef0123456789abcdef');

  setUpAll(() async => sodium = await SodiumSumoInit.init());

  setUp(() {
    vaults = FakeVaultStore();
    records = FakeLocalStore();
    server = FakeSyncServer();
  });

  VaultKeeper keeper() => VaultKeeper(
    vaults: vaults,
    records: (_) => records,
    hasher: SodiumContentHasher(sodium),
    gateway: FakeGateway(server),
    identities: SodiumIdentityService(sodium),
    keys: SodiumKeyDerivationService(sodium),
    subkeys: SodiumSubkeyDerivationService(sodium),
    envelopes: SodiumEnvelopeEncryptor(sodium),
    encapsulation: SodiumKeyEncapsulation(sodium),
    clock: FakeClock(DateTime.utc(2026, 10, 13, 10)),
    random: Random.secure(),
    kdf: KdfParameters.interactive,
  );

  Future<UnlockedVault> newVault() async {
    final vault = await keeper().create(
      SodiumPasswordSecret.fromUtf8Bytes(
        sodium,
        Uint8List.fromList(utf8.encode('correct horse')),
      ),
    );
    addTearDown(vault.lock);
    return vault;
  }

  Future<void> write(UnlockedVault vault, String text) => vault.engine.write(
    note,
    RevisionContents(Uint8List.fromList(utf8.encode(text))),
  );

  test(
    'the first sync founds the workspace with its first record, then rows',
    () async {
      final vault = await newVault();
      await write(vault, 'prima');

      final report = await vault.engine.sync();

      expect(report.offline, isFalse);
      expect(report.pushed, 1);
      expect(server.createdWorkspaces, [vault.workspace]);
      expect(server.membershipLog, vault.engine.ledger.records);
      // The founder's own grant goes too, as every bundle it keeps.
      expect(server.calls, ['workspace 1', 'bundle', 'push 1']);
    },
  );

  test('later syncs publish nothing twice', () async {
    final vault = await newVault();
    await vault.engine.sync();
    server.calls.clear();

    await write(vault, 'seconda');
    await vault.engine.sync();

    expect(server.calls, ['push 1']);
    expect(server.membershipLog, hasLength(1));
  });

  test('an offline vault publishes once the server is back', () async {
    final vault = await newVault();
    await write(vault, 'offline');
    server.online = false;

    expect((await vault.engine.sync()).offline, isTrue);
    expect(server.createdWorkspaces, isEmpty);

    server.online = true;
    final report = await vault.engine.sync();

    expect(report.pushed, 1);
    expect(server.membershipLog, hasLength(1));
  });

  test('a founding cut short is retried by the next sync', () async {
    final vault = await newVault();
    server.dropNextAppend = true;

    expect((await vault.engine.sync()).offline, isTrue);
    expect(server.membershipLog, isEmpty);

    await vault.engine.sync();

    expect(server.membershipLog, vault.engine.ledger.records);
  });

  test('a log the server already holds is not appended again', () async {
    final vault = await newVault();
    // An earlier sync got the record through but stopped before noting it.
    server.membershipLog.addAll(vault.engine.ledger.records);

    await vault.engine.sync();

    expect(
      server.calls.where((call) => call.startsWith('membership')),
      isEmpty,
    );
    expect(server.membershipLog, hasLength(1));
  });

  group('a new server', () {
    Future<UnlockedVault> unlockAgain(UnlockedVault vault) async {
      vault.lock();
      final again = await keeper().unlock(
        SodiumPasswordSecret.fromUtf8Bytes(
          sodium,
          Uint8List.fromList(utf8.encode('correct horse')),
        ),
      );
      addTearDown(again.lock);
      return again;
    }

    test('is met once: the next unlock syncs as usual', () async {
      final vault = await newVault();
      await write(vault, 'prima');
      expect((await vault.engine.sync()).moved, isTrue);

      final again = await unlockAgain(vault);
      final report = await again.engine.sync();

      expect(report.moved, isFalse);
      expect(server.rows, hasLength(1));
    });

    test(
      'gets the vault again, its log, keys and notes, after an unlock',
      () async {
        final vault = await newVault();
        await write(vault, 'prima');
        await vault.engine.sync();
        server.replace();

        final again = await unlockAgain(vault);
        final report = await again.engine.sync();

        expect(report.moved, isTrue);
        expect(report.pushed, 1);
        expect(server.membershipLog, again.engine.ledger.records);
        expect(server.bundles, hasLength(1));
        expect(server.live, hasLength(1));
        expect((await again.engine.sync()).moved, isFalse);
      },
    );
  });

  group('adversary', () {
    test(
      'a server holding another log for the workspace stops the sync',
      () async {
        final vault = await newVault();
        await write(vault, 'non per altri');
        final stranger = SodiumIdentityService(sodium).generateIdentity();
        addTearDown(stranger.dispose);
        server.membershipLog.addAll(
          MembershipLedger(SodiumIdentityService(sodium))
              .found(vault.workspace, founder: stranger)
              .records,
        );

        await expectLater(
          vault.engine.sync(),
          throwsA(isA<LedgerRollbackException>()),
        );
        expect(server.rows, isEmpty);
      },
    );
  });
}
