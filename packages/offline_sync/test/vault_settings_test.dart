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

void main() {
  late FakeVaultStore vaults;

  setUpAll(() async => sodium = await SodiumSumoInit.init());
  setUp(() => vaults = FakeVaultStore());

  VaultKeeper keeper() => VaultKeeper(
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

  PasswordSecret password() =>
      SodiumPasswordSecret.fromUtf8Bytes(sodium, bytes('correct horse'));

  test('a setting is kept sealed across locking and unlocking', () async {
    final vault = await keeper().create(password());
    expect(await keeper().loadSetting(vault, 'sync.session'), isNull);

    await keeper().saveSetting(vault, 'sync.session', bytes('token-123'));
    vault.lock();
    final reopened = await keeper().unlock(password());
    addTearDown(reopened.lock);

    expect(
      await keeper().loadSetting(reopened, 'sync.session'),
      bytes('token-123'),
    );
  });

  test('saving null removes a setting', () async {
    final vault = await keeper().create(password());
    addTearDown(vault.lock);
    await keeper().saveSetting(vault, 'sync.session', bytes('token-123'));

    await keeper().saveSetting(vault, 'sync.session', null);

    expect(await keeper().loadSetting(vault, 'sync.session'), isNull);
    expect(vaults.settings, isEmpty);
  });

  test('names are short lowercase identifiers', () async {
    final vault = await keeper().create(password());
    addTearDown(vault.lock);

    for (final name in ['', 'Sync', 'a b', 'x' * 65, 'sync/session']) {
      await expectLater(
        keeper().saveSetting(vault, name, bytes('v')),
        throwsArgumentError,
        reason: name,
      );
    }
  });

  group('adversary', () {
    test('a locked vault neither reads nor writes settings', () async {
      final vault = await keeper().create(password());
      vault.lock();

      await expectLater(
        keeper().loadSetting(vault, 'sync.session'),
        throwsA(isA<VaultLockedException>()),
      );
      await expectLater(
        keeper().saveSetting(vault, 'sync.session', bytes('x')),
        throwsA(isA<VaultLockedException>()),
      );
    });

    test('nothing is stored in clear', () async {
      final vault = await keeper().create(password());
      addTearDown(vault.lock);

      await keeper().saveSetting(vault, 'sync.session', bytes('token-123'));

      final stored = latin1.decode(vaults.settings['sync.session']!.toBytes());
      expect(stored.contains('token-123'), isFalse);
    });

    test('a value moved to another name reads as absent', () async {
      final vault = await keeper().create(password());
      addTearDown(vault.lock);
      await keeper().saveSetting(vault, 'sync.session', bytes('token-123'));

      vaults.settings['sync.other'] = vaults.settings['sync.session']!;

      expect(await keeper().loadSetting(vault, 'sync.other'), isNull);
    });
  });
}
