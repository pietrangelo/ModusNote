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

/// An authenticator in memory: each passkey is a random secret, and its PRF
/// is a hash of secret and salt, as `hmac-secret` is an HMAC of both.
final class FakePasskeyPrf implements PasskeyPrf {
  final _secrets = <PasskeyCredentialId, Uint8List>{};
  final issued = <SymmetricKey>[];
  final forgotten = <PasskeyCredentialId>[];
  final evaluatedSalts = <PrfSalt>[];

  /// Thrown by the next request instead of answering it.
  Object? failNext;

  /// Answers with another passkey's secret, as a different authenticator
  /// would.
  Uint8List? impostor;

  @override
  Future<RegisteredPasskey> register({required PrfSalt salt}) async {
    _maybeFail();
    final credential = PasskeyCredentialId.fromBytes(
      sodium.randombytes.buf(32),
    );
    _secrets[credential] = sodium.randombytes.buf(32);
    return RegisteredPasskey(
      credential: credential,
      key: _prf(credential, salt),
    );
  }

  @override
  Future<SymmetricKey> evaluate(
    PasskeyCredentialId credential, {
    required PrfSalt salt,
  }) async {
    _maybeFail();
    // The browser finds no such passkey and the prompt ends unanswered.
    if (!_secrets.containsKey(credential)) {
      throw const PasskeyCancelledException();
    }
    evaluatedSalts.add(salt);
    return _prf(credential, salt);
  }

  @override
  Future<void> forget(PasskeyCredentialId credential) async {
    forgotten.add(credential);
    _secrets.remove(credential);
  }

  void _maybeFail() {
    final failure = failNext;
    failNext = null;
    if (failure != null) throw failure;
  }

  SymmetricKey _prf(PasskeyCredentialId credential, PrfSalt salt) {
    final output = sodium.crypto.genericHash(
      message: Uint8List.fromList([
        ...impostor ?? _secrets[credential]!,
        ...salt.bytes,
      ]),
    );
    final key = SodiumSymmetricKey.wrap(sodium.secureCopy(output));
    issued.add(key);
    return key;
  }
}

void main() {
  late FakeVaultStore vaults;
  late Map<WorkspaceId, FakeLocalStore> records;
  late FakePasskeyPrf passkeys;

  setUpAll(() async => sodium = await SodiumSumoInit.init());

  setUp(() {
    vaults = FakeVaultStore();
    records = {};
    passkeys = FakePasskeyPrf();
  });

  VaultKeeper keeper({bool withPasskeys = true}) => VaultKeeper(
    vaults: vaults,
    records: (workspace) => records.putIfAbsent(workspace, FakeLocalStore.new),
    hasher: SodiumContentHasher(sodium),
    identities: SodiumIdentityService(sodium),
    keys: SodiumKeyDerivationService(sodium),
    subkeys: SodiumSubkeyDerivationService(sodium),
    envelopes: SodiumEnvelopeEncryptor(sodium),
    encapsulation: SodiumKeyEncapsulation(sodium),
    clock: FakeClock(DateTime.utc(2026, 10, 13, 9)),
    random: Random.secure(),
    kdf: KdfParameters.interactive,
    passkeys: withPasskeys ? passkeys : null,
  );

  final note = RecordId.parse('0123456789abcdef0123456789abcdef');

  Future<UnlockedVault> enrolledVault() async {
    final vault = await keeper().create(password('correct horse'));
    await vault.engine.write(note, RevisionContents(bytes('con la passkey')));
    await keeper().enrollPasskey(vault);
    return vault;
  }

  test('a vault has no passkey until one is enrolled', () async {
    final vault = await keeper().create(password('correct horse'));
    addTearDown(vault.lock);

    expect(keeper().offersPasskeys, isTrue);
    expect(await keeper().hasPasskey, isFalse);

    await keeper().enrollPasskey(vault);

    expect(await keeper().hasPasskey, isTrue);
  });

  test('without a passkey port the vault offers only the passphrase', () async {
    final vault = await keeper(withPasskeys: false)
        .create(password('correct horse'));
    addTearDown(vault.lock);

    expect(keeper(withPasskeys: false).offersPasskeys, isFalse);
    await expectLater(
      keeper(withPasskeys: false).enrollPasskey(vault),
      throwsA(isA<PasskeyUnsupportedException>()),
    );
    await keeper().enrollPasskey(vault);
    expect(await keeper(withPasskeys: false).hasPasskey, isFalse);
  });

  test('the passkey reopens the same identity and notes', () async {
    final enrolled = await enrolledVault();
    final member = enrolled.member;
    enrolled.lock();

    final unlocked = await keeper().unlockWithPasskey();
    addTearDown(unlocked.lock);

    expect(unlocked.member, member);
    expect(unlocked.workspace, enrolled.workspace);
    expect(
      await unlocked.engine.read(note),
      isA<RevisionContents>().having(
        (c) => utf8.decode(c.bytes),
        'text',
        'con la passkey',
      ),
    );
    await unlocked.engine.write(note, RevisionContents(bytes('scritta')));
  });

  test('the passphrase keeps working next to the passkey', () async {
    (await enrolledVault()).lock();

    final unlocked = await keeper().unlock(password('correct horse'));
    addTearDown(unlocked.lock);

    expect(await unlocked.engine.read(note), isA<RevisionContents>());
  });

  test(
    'notes written after a passkey unlock open with the passphrase',
    () async {
      (await enrolledVault()).lock();
      final viaPasskey = await keeper().unlockWithPasskey();
      await viaPasskey.engine.write(note, RevisionContents(bytes('dopo')));
      viaPasskey.lock();

      final viaPassphrase = await keeper().unlock(password('correct horse'));
      addTearDown(viaPassphrase.lock);

      expect(
        await viaPassphrase.engine.read(note),
        isA<RevisionContents>().having(
          (c) => utf8.decode(c.bytes),
          'text',
          'dopo',
        ),
      );
    },
  );

  test('every PRF key is disposed as soon as it has been used', () async {
    (await enrolledVault()).lock();
    (await keeper().unlockWithPasskey()).lock();

    expect(passkeys.issued, hasLength(2));
    expect(passkeys.issued.every((key) => key.isDisposed), isTrue);
  });

  test('the PRF salt is fresh for every enrollment', () async {
    final vault = await enrolledVault();
    addTearDown(vault.lock);
    final first = vaults.passkey!;

    await keeper().enrollPasskey(vault);

    expect(vaults.passkey!.salt, isNot(first.salt));
    expect(vaults.passkey!.keyId, isNot(first.keyId));
  });

  test(
    'enrolling again replaces the passkey and forgets the old one',
    () async {
      final vault = await enrolledVault();
      addTearDown(vault.lock);
      final old = vaults.passkey!.credential;

      await keeper().enrollPasskey(vault);

      expect(vaults.passkey!.credential, isNot(old));
      expect(passkeys.forgotten, [old]);
    },
  );

  test('removing the passkey leaves only the passphrase', () async {
    (await enrolledVault()).lock();
    final credential = vaults.passkey!.credential;

    await keeper().removePasskey();

    expect(await keeper().hasPasskey, isFalse);
    expect(passkeys.forgotten, [credential]);
    await expectLater(
      keeper().unlockWithPasskey(),
      throwsA(isA<NoPasskeyException>()),
    );
    (await keeper().unlock(password('correct horse'))).lock();
  });

  test('unlocking with a passkey on a device without one says so', () async {
    await expectLater(
      keeper().unlockWithPasskey(),
      throwsA(isA<NoVaultException>()),
    );
    (await keeper().create(password('correct horse'))).lock();
    await expectLater(
      keeper().unlockWithPasskey(),
      throwsA(isA<NoPasskeyException>()),
    );
  });

  test('a cancelled prompt changes nothing', () async {
    final vault = await keeper().create(password('correct horse'));
    addTearDown(vault.lock);
    passkeys.failNext = const PasskeyCancelledException();

    await expectLater(
      keeper().enrollPasskey(vault),
      throwsA(isA<PasskeyCancelledException>()),
    );
    expect(await keeper().hasPasskey, isFalse);

    await keeper().enrollPasskey(vault);
    vault.lock();
    passkeys.failNext = const PasskeyCancelledException();
    await expectLater(
      keeper().unlockWithPasskey(),
      throwsA(isA<PasskeyCancelledException>()),
    );
    (await keeper().unlockWithPasskey()).lock();
  });

  group('adversary', () {
    test('a locked vault cannot enroll a passkey', () async {
      final vault = await keeper().create(password('correct horse'));
      vault.lock();

      await expectLater(
        keeper().enrollPasskey(vault),
        throwsA(isA<VaultLockedException>()),
      );
      expect(passkeys.issued, isEmpty);
    });

    test('another authenticator\'s answer opens nothing', () async {
      (await enrolledVault()).lock();
      passkeys.impostor = sodium.randombytes.buf(32);

      await expectLater(
        keeper().unlockWithPasskey(),
        throwsA(isA<PasskeyRejectedException>()),
      );
      expect(passkeys.issued.last.isDisposed, isTrue);
    });

    test('a slot copied from another vault is refused', () async {
      (await enrolledVault()).lock();
      final foreign = vaults.passkey!;
      vaults = FakeVaultStore();
      (await keeper().create(password('correct horse'))).lock();
      vaults.passkey = foreign;

      await expectLater(
        keeper().unlockWithPasskey(),
        throwsA(isA<PasskeyRejectedException>()),
      );
    });

    test('a header edited after enrolling no longer opens the slot', () async {
      (await enrolledVault()).lock();
      final original = vaults.header!;
      vaults.header = VaultHeader(
        salt: original.salt,
        kdf: original.kdf,
        workspace: original.workspace,
        founder: original.founder,
        localKeyId: SubkeyId.fromBytes(List.filled(SubkeyId.length, 1)),
        sealedIdentity: original.sealedIdentity,
      );

      await expectLater(
        keeper().unlockWithPasskey(),
        throwsA(isA<PasskeyRejectedException>()),
      );
    });

    test('mixing the secrets of two enrollments is refused', () async {
      final vault = await enrolledVault();
      final first = vaults.passkey!;
      await keeper().enrollPasskey(vault);
      vault.lock();
      final second = vaults.passkey!;
      // The newer identity seal with the older local key: both are genuine,
      // but they were bound to different slots.
      vaults.passkey = PasskeySlot(
        credential: second.credential,
        salt: second.salt,
        keyId: second.keyId,
        sealedIdentity: second.sealedIdentity,
        sealedLocalKey: first.sealedLocalKey,
      );

      await expectLater(
        keeper().unlockWithPasskey(),
        throwsA(isA<PasskeyRejectedException>()),
      );
    });

    test('a slot whose salt was edited is refused', () async {
      (await enrolledVault()).lock();
      final slot = vaults.passkey!;
      vaults.passkey = PasskeySlot(
        credential: slot.credential,
        salt: PrfSalt.fromBytes(List.filled(PrfSalt.length, 0)),
        keyId: slot.keyId,
        sealedIdentity: slot.sealedIdentity,
        sealedLocalKey: slot.sealedLocalKey,
      );

      await expectLater(
        keeper().unlockWithPasskey(),
        throwsA(isA<PasskeyRejectedException>()),
      );
    });

    test(
      'a membership log swapped on disk is refused after a passkey too',
      () async {
        (await enrolledVault()).lock();
        final stranger = SodiumIdentityService(sodium).generateIdentity();
        final forged = MembershipLedger(SodiumIdentityService(sodium))
            .found(vaults.header!.workspace, founder: stranger);
        vaults.membership
          ..clear()
          ..addAll(forged.records);

        await expectLater(
          keeper().unlockWithPasskey(),
          throwsA(isA<TamperedWorkspaceDataException>()),
        );
      },
    );

    test('the slot stores no key and no note in clear', () async {
      (await enrolledVault()).lock();
      final stored = latin1.decode(vaults.passkey!.toBytes());

      expect(stored.contains('con la passkey'), isFalse);
      expect(stored.contains('correct horse'), isFalse);
      for (final key in passkeys.issued) {
        expect(key.toString(), 'SymmetricKey(redacted)');
      }
    });
  });
}
