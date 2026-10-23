import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:identity_cryptography_adapters/identity_cryptography_adapters.dart';
import 'package:offline_sync/offline_sync.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:test/test.dart';

import 'fakes.dart';

late SodiumSumo sodium;

Uint8List bytes(String text) => Uint8List.fromList(utf8.encode(text));

final note = RecordId.parse('0000000000000000000000000000000a');
final song = RecordId.parse('0000000000000000000000000000000b');
final gone = RecordId.parse('0000000000000000000000000000000c');

void main() {
  setUpAll(() async => sodium = await SodiumSumoInit.init());

  VaultKeeper keeper(FakeVaultStore vaults) => VaultKeeper(
    vaults: vaults,
    records: (_) => FakeLocalStore(),
    hasher: SodiumContentHasher(sodium),
    identities: SodiumIdentityService(sodium),
    keys: SodiumKeyDerivationService(sodium),
    subkeys: SodiumSubkeyDerivationService(sodium),
    envelopes: SodiumEnvelopeEncryptor(sodium),
    encapsulation: SodiumKeyEncapsulation(sodium),
    clock: FakeClock(DateTime.utc(2026, 10, 13, 10)),
    random: Random.secure(),
    kdf: KdfParameters.interactive,
  );

  PasswordSecret secret(String text) =>
      SodiumPasswordSecret.fromUtf8Bytes(sodium, bytes(text));

  Future<UnlockedVault> vaultWith(
    VaultKeeper keeper,
    Map<RecordId, String> records,
  ) async {
    final vault = await keeper.create(secret('correct horse'));
    addTearDown(vault.lock);
    await keeper.confirm(vault, secret('correct horse'));
    for (final MapEntry(:key, :value) in records.entries) {
      await vault.engine.write(key, RevisionContents(bytes(value)));
    }
    return vault;
  }

  Future<Map<RecordId, String>> contentsOf(UnlockedVault vault) async => {
    for (final MapEntry(:key, :value) in (await vault.engine.records()).entries)
      key: utf8.decode(value.bytes),
  };

  test('a backup carries every live record into another vault', () async {
    final from = keeper(FakeVaultStore());
    final source = await vaultWith(from, {note: 'nota', song: 'canzone'});
    await source.engine.write(gone, RevisionContents(bytes('via')));
    await source.engine.write(gone, const RevisionDeleted());

    final file = await from.exportBackup(source, secret('backup phrase'));

    final to = keeper(FakeVaultStore());
    final target = await vaultWith(to, {});
    final backup = await to.openBackup(file, secret('backup phrase'));
    expect(backup.records.keys, unorderedEquals([note, song]));
    final restore = await to.restoreBackup(target, backup);

    expect(restore.added, 2);
    expect(restore.kept, 0);
    expect(await contentsOf(target), {note: 'nota', song: 'canzone'});
  });

  test('restoring never overwrites a record the vault already has', () async {
    final vaults = FakeVaultStore();
    final k = keeper(vaults);
    final vault = await vaultWith(k, {note: 'vecchia', song: 'canzone'});
    final file = await k.exportBackup(vault, secret('backup phrase'));

    await vault.engine.write(note, RevisionContents(bytes('nuova')));
    await vault.engine.write(song, const RevisionDeleted());
    final restore = await k.restoreBackup(
      vault,
      await k.openBackup(file, secret('backup phrase')),
    );

    expect(restore.added, 1, reason: 'the deleted song comes back');
    expect(restore.kept, 1);
    expect(await contentsOf(vault), {note: 'nuova', song: 'canzone'});
  });

  test('the file holds no record in clear', () async {
    final k = keeper(FakeVaultStore());
    final vault = await vaultWith(k, {note: 'segretissimo'});

    final file = await k.exportBackup(vault, secret('backup phrase'));

    expect(latin1.decode(file), isNot(contains('segretissimo')));
    expect(latin1.decode(file.sublist(0, 4)), 'MNBK');
  });

  group('adversary', () {
    late VaultKeeper k;
    late Uint8List file;

    setUp(() async {
      k = keeper(FakeVaultStore());
      final vault = await vaultWith(k, {note: 'nota'});
      file = await k.exportBackup(vault, secret('backup phrase'));
    });

    test('a wrong passphrase is rejected', () async {
      await expectLater(
        k.openBackup(file, secret('wrong phrase')),
        throwsA(isA<BackupRejectedException>()),
      );
    });

    test('any flipped byte is rejected', () async {
      for (final at in [0, 4, 5, 21, 25, file.length - 1]) {
        final bent = Uint8List.fromList(file);
        bent[at] ^= 1;
        await expectLater(
          k.openBackup(bent, secret('backup phrase')),
          throwsA(isA<BackupRejectedException>()),
          reason: 'byte $at',
        );
      }
    });

    test('not a backup, cut short or with bytes after it', () async {
      for (final wrong in [
        Uint8List(0),
        bytes('hello world, not a backup at all'),
        file.sublist(0, file.length - 1),
        Uint8List.fromList([...file, 0]),
      ]) {
        await expectLater(
          k.openBackup(wrong, secret('backup phrase')),
          throwsA(isA<BackupRejectedException>()),
        );
      }
    });

    test('a file asking for a ruinous Argon2id is refused unopened', () {
      final bent = Uint8List.fromList(file);
      // memLimit, right after magic, version, salt and opsLimit.
      ByteData.sublistView(bent).setUint32(4 + 1 + 16 + 4, 0xFFFFFFFF);
      expect(
        () => k.openBackup(bent, secret('backup phrase')),
        throwsA(isA<BackupRejectedException>()),
      );
    });

    test('a locked vault neither exports nor restores', () async {
      final other = keeper(FakeVaultStore());
      final vault = await other.create(secret('correct horse'));
      await other.confirm(vault, secret('correct horse'));
      final backup = await other.openBackup(file, secret('backup phrase'));
      vault.lock();

      await expectLater(
        other.exportBackup(vault, secret('backup phrase')),
        throwsA(isA<VaultLockedException>()),
      );
      await expectLater(
        other.restoreBackup(vault, backup),
        throwsA(isA<VaultLockedException>()),
      );
    });
  });

  group('contents', () {
    test('round trip', () {
      final contents = BackupContents({note: bytes('a'), song: bytes('')});
      final again = BackupContents.parse(contents.toBytes());
      expect(again.records.keys, unorderedEquals([note, song]));
      expect(again.records[note], bytes('a'));
    });

    test('a record listed twice is malformed', () {
      final one = BackupContents({note: bytes('a')}).toBytes();
      final twice = Uint8List.fromList(one)
        ..buffer.asByteData().setUint32(1, 2);
      final doubled = Uint8List.fromList([...twice, ...one.sublist(5)]);
      expect(
        () => BackupContents.parse(doubled),
        throwsA(isA<MalformedSyncDataException>()),
      );
    });
  });
}
