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

PasswordSecret password(String text) => SodiumPasswordSecret.fromUtf8Bytes(
  sodium,
  Uint8List.fromList(utf8.encode(text)),
);

Uint8List bytes(String text) => Uint8List.fromList(utf8.encode(text));

void main() {
  late FakeVaultStore vaults;
  late Map<WorkspaceId, FakeLocalStore> records;
  late FakeSyncServer server;

  setUpAll(() async => sodium = await SodiumSumoInit.init());

  setUp(() {
    vaults = FakeVaultStore();
    records = {};
    server = FakeSyncServer()..online = false;
  });

  VaultKeeper keeper() => VaultKeeper(
    vaults: vaults,
    records: (workspace) => records.putIfAbsent(workspace, FakeLocalStore.new),
    hasher: SodiumContentHasher(sodium),
    gateway: FakeGateway(server),
    identities: SodiumIdentityService(sodium),
    keys: SodiumKeyDerivationService(sodium),
    subkeys: SodiumSubkeyDerivationService(sodium),
    envelopes: SodiumEnvelopeEncryptor(sodium),
    encapsulation: SodiumKeyEncapsulation(sodium),
    clock: FakeClock(DateTime.utc(2026, 10, 11, 15)),
    random: Random.secure(),
    kdf: KdfParameters.interactive,
  );

  final note = RecordId.parse('0123456789abcdef0123456789abcdef');

  test('a device has no vault until one is created', () async {
    expect(await keeper().exists, isFalse);

    (await keeper().create(password('correct horse'))).lock();

    expect(await keeper().exists, isTrue);
  });

  test('a new vault is a personal workspace this device can write', () async {
    final vault = await keeper().create(password('correct horse'));

    await vault.engine.write(note, RevisionContents(bytes('prima nota')));

    expect(
      await vault.engine.read(note),
      isA<RevisionContents>().having(
        (c) => utf8.decode(c.bytes),
        'text',
        'prima nota',
      ),
    );
    expect(vault.engine.ledger.records.single.change, isA<WorkspaceFounded>());
    vault.lock();
  });

  test('unlocking with the passphrase restores identity and notes', () async {
    final created = await keeper().create(password('correct horse'));
    await created.engine.write(note, RevisionContents(bytes('resta')));
    final member = created.member;
    created.lock();

    final unlocked = await keeper().unlock(password('correct horse'));

    expect(unlocked.member, member);
    expect(unlocked.workspace, created.workspace);
    expect(
      await unlocked.engine.read(note),
      isA<RevisionContents>().having(
        (c) => utf8.decode(c.bytes),
        'text',
        'resta',
      ),
    );
    unlocked.lock();
  });

  test('records lists every live note, not deletions', () async {
    final vault = await keeper().create(password('correct horse'));
    final other = RecordId.parse('fedcba9876543210fedcba9876543210');
    await vault.engine.write(note, RevisionContents(bytes('a')));
    await vault.engine.write(other, RevisionContents(bytes('b')));
    await vault.engine.write(other, const RevisionDeleted());

    final live = await vault.engine.records();

    expect(live.keys, [note]);
    vault.lock();
  });

  test('the vault lends its content key for blobs, by epoch', () async {
    final vault = await keeper().create(password('correct horse'));
    addTearDown(vault.lock);
    final envelopes = SodiumEnvelopeEncryptor(sodium);

    final epoch = vault.engine.currentEpoch;
    final sealed = envelopes.seal(
      bytes('audio'),
      key: vault.engine.contentKeyFor(epoch),
      associatedData: AssociatedData.empty,
    );

    expect(epoch, KeyEpoch.initial);
    expect(
      envelopes.open(
        sealed,
        key: vault.engine.contentKeyFor(epoch),
        associatedData: AssociatedData.empty,
      ),
      bytes('audio'),
    );
    expect(
      () => vault.engine.contentKeyFor(KeyEpoch(1)),
      throwsA(isA<MissingGroupKeyException>()),
    );
  });

  test('creating a second vault on the same device is refused', () async {
    (await keeper().create(password('correct horse'))).lock();

    await expectLater(
      keeper().create(password('another one')),
      throwsA(isA<VaultAlreadyExistsException>()),
    );
  });

  test('unlocking a device with no vault says so', () async {
    await expectLater(
      keeper().unlock(password('correct horse')),
      throwsA(isA<NoVaultException>()),
    );
  });

  test('the passphrase is consumed: disposed once stretched', () async {
    final secret = password('correct horse');

    (await keeper().create(secret)).lock();

    expect(secret.isDisposed, isTrue);
  });

  test('locking disposes every key the vault held', () async {
    final vault = await keeper().create(password('correct horse'));

    vault.lock();

    expect(vault.isLocked, isTrue);
    expect(() => vault.engine, throwsA(isA<VaultLockedException>()));
  });

  group('adversary', () {
    test('a wrong passphrase is refused and opens nothing', () async {
      (await keeper().create(password('correct horse'))).lock();

      await expectLater(
        keeper().unlock(password('wrong horse')),
        throwsA(isA<WrongPassphraseException>()),
      );
    });

    test('a header edited on disk no longer opens the identity', () async {
      (await keeper().create(password('correct horse'))).lock();
      final original = vaults.header!;
      vaults.header = VaultHeader(
        salt: original.salt,
        kdf: original.kdf,
        workspace: original.workspace,
        founder: MemberId(
          PublicSigningKey.fromBytes(List.filled(PublicSigningKey.length, 1)),
        ),
        localKeyId: original.localKeyId,
        sealedIdentity: original.sealedIdentity,
      );

      await expectLater(
        keeper().unlock(password('correct horse')),
        throwsA(isA<WrongPassphraseException>()),
      );
    });

    test('a membership log swapped on disk is refused', () async {
      (await keeper().create(password('correct horse'))).lock();
      final stranger = SodiumIdentityService(sodium).generateIdentity();
      final forged = MembershipLedger(SodiumIdentityService(sodium))
          .found(vaults.header!.workspace, founder: stranger);
      vaults.membership
        ..clear()
        ..addAll(forged.records);

      await expectLater(
        keeper().unlock(password('correct horse')),
        throwsA(isA<TamperedWorkspaceDataException>()),
      );
    });

    test('nothing is stored in clear: header, log and records', () async {
      final vault = await keeper().create(password('correct horse'));
      await vault.engine.write(note, RevisionContents(bytes('segreto-42')));
      vault.lock();

      final stored = [
        vaults.header!.toBytes(),
        for (final envelope in records.values.single.records.values)
          envelope.toBytes(),
        for (final row in records.values.single.outbox.pending)
          row.ciphertext.envelope.toBytes(),
      ];
      for (final blob in stored) {
        expect(latin1.decode(blob).contains('segreto-42'), isFalse);
        expect(latin1.decode(blob).contains('correct horse'), isFalse);
      }
    });
  });
}
