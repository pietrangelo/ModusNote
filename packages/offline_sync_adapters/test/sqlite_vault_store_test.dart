import 'dart:io';
import 'dart:typed_data';

import 'package:collaboration_access_control/collaboration_access_control.dart';
import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:identity_cryptography_adapters/identity_cryptography_adapters.dart';
import 'package:offline_sync/offline_sync.dart';
import 'package:offline_sync_adapters/offline_sync_adapters.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

final workspace = WorkspaceId.parse('00112233445566778899aabbccddeeff');

VaultHeader header(MemberId founder) => VaultHeader(
  salt: Salt.fromBytes(List.filled(Salt.length, 1)),
  kdf: KdfParameters.interactive,
  workspace: workspace,
  founder: founder,
  localKeyId: SubkeyId.fromBytes(List.filled(SubkeyId.length, 2)),
  sealedIdentity: EncryptedEnvelope(
    nonce: Nonce.fromBytes(List.filled(Nonce.length, 3)),
    ciphertext: List.filled(80, 4),
  ),
);

PasskeySlot passkey({int fill = 5}) => PasskeySlot(
  credential: PasskeyCredentialId.fromBytes(List.filled(20, fill)),
  salt: PrfSalt.fromBytes(List.filled(PrfSalt.length, 6)),
  keyId: SubkeyId.fromBytes(List.filled(SubkeyId.length, 8)),
  sealedIdentity: EncryptedEnvelope(
    nonce: Nonce.fromBytes(List.filled(Nonce.length, 3)),
    ciphertext: List.filled(80, 4),
  ),
  sealedLocalKey: SealedKey(
    encapsulation: List.filled(SealedKey.encapsulationLength, 1),
    envelope: EncryptedEnvelope(
      nonce: Nonce.fromBytes(List.filled(Nonce.length, 2)),
      ciphertext: List.filled(48, 9),
    ),
  ),
);

void main() {
  late SodiumSumo sodium;
  late FoundedWorkspace founded;
  late IdentityKeyPair founder;
  late Directory directory;
  late String path;
  late Database database;
  late SqliteVaultStore store;

  setUpAll(() async => sodium = await SodiumSumoInit.init());

  setUp(() {
    founder = SodiumIdentityService(sodium).generateIdentity();
    founded = WorkspaceAdministration(
      identities: SodiumIdentityService(sodium),
      encapsulation: SodiumKeyEncapsulation(sodium),
      envelopes: SodiumEnvelopeEncryptor(sodium),
    ).found(workspace, founder: founder);
    directory = Directory.systemTemp.createTempSync('modusnote-vault');
    path = '${directory.path}/vault.db';
    database = sqlite3.open(path);
    store = SqliteVaultStore(database);
  });

  tearDown(() {
    founder.dispose();
    founded.keyring.dispose();
    database.close();
    directory.deleteSync(recursive: true);
  });

  SqliteVaultStore reopen() {
    database.close();
    database = sqlite3.open(path);
    return SqliteVaultStore(database);
  }

  MemberId me() => MemberId.of(founder.publicIdentity);

  test('a fresh database holds no vault', () async {
    expect(await store.loadHeader(), isNull);
    expect(await store.loadMembership(), isEmpty);
    expect(await store.loadKeyBundles(), isEmpty);
  });

  test('the header and founding log survive reopening the database', () async {
    await store.create(
      header(me()),
      membership: [founded.record],
      bundles: [founded.bundle!],
    );

    final reopened = reopen();

    expect(await reopened.loadHeader(), header(me()));
    expect(await reopened.loadMembership(), [founded.record]);
    expect((await reopened.loadKeyBundles()).map((b) => b.toBytes()), [
      founded.bundle!.toBytes(),
    ]);
  });

  test('shares the file with the record store without clashing', () async {
    await store.create(
      header(me()),
      membership: [founded.record],
      bundles: const [],
    );
    final records = SqliteLocalRecordStore(database, workspace: workspace);
    await records.saveCursor(SyncStream.rows, 4);

    final reopened = reopen();

    expect(await reopened.loadHeader(), header(me()));
    expect(
      await SqliteLocalRecordStore(
        database,
        workspace: workspace,
      ).loadCursor(SyncStream.rows),
      4,
    );
  });

  test('membership and bundles learned later are kept, once each', () async {
    await store.create(
      header(me()),
      membership: [founded.record],
      bundles: [founded.bundle!],
    );
    final device = SodiumIdentityService(sodium).generateIdentity();
    addTearDown(device.dispose);
    final invited =
        WorkspaceAdministration(
          identities: SodiumIdentityService(sodium),
          encapsulation: SodiumKeyEncapsulation(sodium),
          envelopes: SodiumEnvelopeEncryptor(sodium),
        ).invite(
          founded.ledger,
          founded.keyring,
          owner: founder,
          invitee: device.publicIdentity,
          role: Role.owner,
        );

    await store.appendMembership([founded.record, invited.record]);
    await store.appendMembership([invited.record]);
    await store.appendKeyBundles([invited.bundle!]);

    final reopened = reopen();
    expect(await reopened.loadMembership(), [founded.record, invited.record]);
    expect((await reopened.loadKeyBundles()).map((b) => b.toBytes()), [
      founded.bundle!.toBytes(),
      invited.bundle!.toBytes(),
    ]);
  });

  test('a second vault cannot be written over the first', () async {
    await store.create(header(me()), membership: const [], bundles: const []);

    await expectLater(
      store.create(header(me()), membership: const [], bundles: const []),
      throwsA(isA<VaultAlreadyExistsException>()),
    );
  });

  group('passkey', () {
    test('a fresh vault has none', () async {
      await store.create(header(me()), membership: const [], bundles: const []);

      expect(await store.loadPasskey(), isNull);
    });

    test('is kept across reopening and replaced by the next', () async {
      await store.create(header(me()), membership: const [], bundles: const []);
      await store.savePasskey(passkey());

      store = reopen();
      expect(await store.loadPasskey(), passkey());

      await store.savePasskey(passkey(fill: 7));

      expect(await reopen().loadPasskey(), passkey(fill: 7));
    });

    test('can be removed', () async {
      await store.create(header(me()), membership: const [], bundles: const []);
      await store.savePasskey(passkey());

      await store.removePasskey();

      expect(await reopen().loadPasskey(), isNull);
    });

    test('cannot be saved without a vault to open', () async {
      await expectLater(
        store.savePasskey(passkey()),
        throwsA(isA<NoVaultException>()),
      );
      expect(await store.loadPasskey(), isNull);
    });

    test('a database from before passkeys gains the table', () async {
      database
        ..execute('DROP TABLE vault_passkey')
        ..execute('DROP TABLE vault_settings')
        ..execute('PRAGMA user_version = 2');
      await store.create(header(me()), membership: const [], bundles: const []);

      final reopened = reopen();

      expect(await reopened.loadHeader(), header(me()));
      expect(await reopened.loadPasskey(), isNull);
      await reopened.savePasskey(passkey());
      expect(await reopened.loadPasskey(), passkey());
    });
  });

  group('settings', () {
    final sealed = EncryptedEnvelope(
      nonce: Nonce.fromBytes(List.filled(Nonce.length, 3)),
      ciphertext: List.filled(40, 4),
    );

    test('are kept across reopening, replaced and removed', () async {
      expect(await store.loadSetting('sync.session'), isNull);

      await store.saveSetting('sync.session', sealed);
      store = reopen();
      expect(await store.loadSetting('sync.session'), sealed);

      await store.saveSetting('sync.session', null);
      expect(await reopen().loadSetting('sync.session'), isNull);
    });

    test('a corrupted setting surfaces as malformed, not a crash', () async {
      await store.saveSetting('sync.session', sealed);
      database.execute('UPDATE vault_settings SET envelope = ?', [
        Uint8List.fromList([1]),
      ]);

      await expectLater(
        store.loadSetting('sync.session'),
        throwsA(isA<MalformedSyncDataException>()),
      );
    });
  });

  group('adversary', () {
    test('a corrupted passkey surfaces as malformed, not a crash', () async {
      await store.create(header(me()), membership: const [], bundles: const []);
      await store.savePasskey(passkey());
      database.execute('UPDATE vault_passkey SET passkey = ?', [
        Uint8List.fromList([1, 2, 3]),
      ]);

      await expectLater(
        store.loadPasskey(),
        throwsA(isA<MalformedSyncDataException>()),
      );
    });

    test('a corrupted header surfaces as malformed, not a crash', () async {
      await store.create(header(me()), membership: const [], bundles: const []);
      database.execute('UPDATE vault SET header = ?', [
        Uint8List.fromList([1, 2, 3]),
      ]);

      await expectLater(
        store.loadHeader(),
        throwsA(isA<MalformedSyncDataException>()),
      );
    });

    test('a corrupted log entry surfaces as malformed, not a crash', () async {
      await store.create(
        header(me()),
        membership: [founded.record],
        bundles: [founded.bundle!],
      );
      database
        ..execute('UPDATE vault_membership SET record = ?', [
          Uint8List.fromList([7]),
        ])
        ..execute('UPDATE vault_key_bundles SET bundle = ?', [
          Uint8List.fromList([7]),
        ]);

      await expectLater(
        store.loadMembership(),
        throwsA(isA<MalformedSyncDataException>()),
      );
      await expectLater(
        store.loadKeyBundles(),
        throwsA(isA<MalformedSyncDataException>()),
      );
    });
  });
}
