import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

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

  Matcher refused() => throwsA(isA<ConfirmationRequiredException>());

  test('an open vault is not confirmed until the person confirms', () async {
    final vault = await open();
    final k = keeper();

    expect(k.isConfirmed(vault), isFalse);
    await expectLater(
      k.exportBackup(vault, secret('backup phrase')),
      refused(),
    );
    await expectLater(k.enrollPasskey(vault), refused());
    expect(authenticator.issued, isEmpty, reason: 'no ceremony started');

    await k.confirm(vault, secret('correct horse'));

    expect(k.isConfirmed(vault), isTrue);
    expect(await k.exportBackup(vault, secret('backup phrase')), isNotEmpty);
    await k.enrollPasskey(vault);
  });

  test('a wrong passphrase confirms nothing', () async {
    final vault = await open();
    final k = keeper();

    await expectLater(
      k.confirm(vault, secret('wrong horse')),
      throwsA(isA<WrongPassphraseException>()),
    );

    expect(k.isConfirmed(vault), isFalse);
    await expectLater(
      k.exportBackup(vault, secret('backup phrase')),
      refused(),
    );
  });

  test('the passphrase given is consumed either way', () async {
    final vault = await open();
    final right = secret('correct horse');
    final wrong = secret('wrong horse');

    await keeper().confirm(vault, right);
    await expectLater(keeper().confirm(vault, wrong), throwsA(anything));

    expect(right.isDisposed, isTrue);
    expect(wrong.isDisposed, isTrue);
  });

  test('a confirmation lasts five minutes', () async {
    final vault = await open();
    final k = keeper();
    await k.confirm(vault, secret('correct horse'));

    clock.advance(
      VaultKeeper.confirmationLifetime - const Duration(seconds: 1),
    );
    expect(k.isConfirmed(vault), isTrue);
    clock.advance(const Duration(seconds: 1));

    expect(k.isConfirmed(vault), isFalse);
    await expectLater(
      k.exportBackup(vault, secret('backup phrase')),
      refused(),
    );
  });

  test('locking forgets the confirmation', () async {
    final vault = await open();
    final k = keeper();
    await k.confirm(vault, secret('correct horse'));

    vault.lock();
    final reopened = await k.unlock(secret('correct horse'));
    addTearDown(reopened.lock);

    expect(k.isConfirmed(vault), isFalse);
    expect(k.isConfirmed(reopened), isFalse);
  });

  test('the enrolled passkey confirms as well', () async {
    final vault = await open();
    final k = keeper();
    await k.confirm(vault, secret('correct horse'));
    await k.enrollPasskey(vault);
    clock.advance(VaultKeeper.confirmationLifetime);
    expect(k.isConfirmed(vault), isFalse);

    await k.confirmWithPasskey(vault);

    expect(k.isConfirmed(vault), isTrue);
    expect(authenticator.issued.every((key) => key.isDisposed), isTrue);
  });

  group('adversary', () {
    test('a clock set back does not stretch a confirmation', () async {
      final vault = await open();
      final k = keeper();
      await k.confirm(vault, secret('correct horse'));

      clock.current = clock.current.subtract(const Duration(hours: 1));

      expect(k.isConfirmed(vault), isFalse);
    });

    test('another authenticator\'s answer confirms nothing', () async {
      final vault = await open();
      final k = keeper();
      await k.confirm(vault, secret('correct horse'));
      await k.enrollPasskey(vault);
      clock.advance(VaultKeeper.confirmationLifetime);
      authenticator.impostor = sodium.randombytes.buf(32);

      await expectLater(
        k.confirmWithPasskey(vault),
        throwsA(isA<PasskeyRejectedException>()),
      );
      expect(k.isConfirmed(vault), isFalse);
    });

    test('the passphrase of the vault the store now holds is not this '
        'vault\'s', () async {
      final vault = await open();
      // Another vault's header takes this one's place in the store.
      vaults = FakeVaultStore();
      (await keeper().create(secret('other horse'))).lock();

      await expectLater(
        keeper().confirm(vault, secret('other horse')),
        throwsA(isA<WrongPassphraseException>()),
      );
      expect(keeper().isConfirmed(vault), isFalse);
    });

    test('a locked vault cannot be confirmed', () async {
      final vault = await open();
      vault.lock();

      await expectLater(
        keeper().confirm(vault, secret('correct horse')),
        throwsA(isA<VaultLockedException>()),
      );
    });
  });
}
