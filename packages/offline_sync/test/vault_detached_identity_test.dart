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
import 'vault_passkey_test.dart' as passkey_test show FakePasskeyPrf, sodium;

late SodiumSumo sodium;

void main() {
  late FakeVaultStore vaults;
  late FakeClock clock;
  late passkey_test.FakePasskeyPrf authenticator;

  setUpAll(() async {
    sodium = await SodiumSumoInit.init();
    passkey_test.sodium = sodium;
  });

  setUp(() {
    vaults = FakeVaultStore();
    clock = FakeClock(DateTime.utc(2026, 10, 23, 11));
    authenticator = passkey_test.FakePasskeyPrf();
  });

  PasswordSecret secret(String text) => SodiumPasswordSecret.fromUtf8Bytes(
    sodium,
    Uint8List.fromList(utf8.encode(text)),
  );

  VaultKeeper keeper() => VaultKeeper(
    vaults: vaults,
    records: (_) => FakeLocalStore(),
    hasher: SodiumContentHasher(sodium),
    identities: SodiumIdentityService(sodium),
    keys: SodiumKeyDerivationService(sodium),
    subkeys: SodiumSubkeyDerivationService(sodium),
    envelopes: SodiumEnvelopeEncryptor(sodium),
    encapsulation: SodiumKeyEncapsulation(sodium),
    clock: clock,
    random: Random.secure(),
    kdf: KdfParameters.interactive,
    passkeys: authenticator,
  );

  Future<UnlockedVault> open() async {
    final vault = await keeper().create(secret('correct horse'));
    addTearDown(vault.lock);
    return vault;
  }

  test('a detached identity needs a fresh confirmation', () async {
    final vault = await open();
    await expectLater(
      keeper().createDetachedIdentity(vault, 'site.quaderno'),
      throwsA(isA<ConfirmationRequiredException>()),
    );
    expect(vaults.settings, isEmpty);
  });

  test('a detached identity is kept sealed and is not the device', () async {
    final vault = await open();
    await keeper().confirm(vault, secret('correct horse'));
    final created = await keeper().createDetachedIdentity(
      vault,
      'site.quaderno',
    );
    final key = created.publicIdentity;
    created.dispose();
    expect(MemberId.of(key), isNot(vault.member));
    expect(vaults.settings.keys, ['identity.site.quaderno']);

    final opened = await keeper().openDetachedIdentity(vault, 'site.quaderno');
    expect(opened?.publicIdentity, key);
    // It signs requests like the device does, with its own key.
    final signer = keeper().signerFor(opened!);
    expect(signer.key, key.signingKey);
    opened.dispose();

    // Under another name it does not open.
    vaults.settings['identity.site.altro'] =
        vaults.settings['identity.site.quaderno']!;
    expect(await keeper().openDetachedIdentity(vault, 'site.altro'), isNull);
    expect(await keeper().openDetachedIdentity(vault, 'site.nulla'), isNull);

    await keeper().forgetDetachedIdentity(vault, 'site.quaderno');
    expect(
      await keeper().openDetachedIdentity(vault, 'site.quaderno'),
      isNull,
    );
  });

  test('plain settings cannot reach a detached identity', () async {
    final vault = await open();
    expect(
      () => keeper().saveSetting(vault, 'identity.site.quaderno', null),
      throwsArgumentError,
    );
    expect(
      () => keeper().loadSetting(vault, 'identity.site.quaderno'),
      throwsArgumentError,
    );
  });

  test('a locked vault opens no detached identity', () async {
    final vault = await open();
    vault.lock();
    await expectLater(
      keeper().openDetachedIdentity(vault, 'site.quaderno'),
      throwsA(isA<VaultLockedException>()),
    );
  });
}
