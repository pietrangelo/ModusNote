import 'dart:math';
import 'dart:typed_data';

import 'package:collaboration_access_control/collaboration_access_control.dart';
import 'package:identity_cryptography/identity_cryptography.dart';

import '../core/passkey_slot.dart';
import '../core/sync_exception.dart';
import '../core/vault_header.dart';
import 'ports.dart';
import 'sync_engine.dart';

/// An open vault: the device identity, its local key and the GroupKeys, all
/// in native memory until [lock] releases them.
final class UnlockedVault {
  UnlockedVault._({
    required this._engine,
    required this.member,
    required this.workspace,
    required this._identity,
    required this._localKey,
    required this._keyring,
  });

  final MemberId member;
  final WorkspaceId workspace;
  final SyncEngine _engine;
  final IdentityKeyPair _identity;
  final SymmetricKey _localKey;
  final GroupKeyring _keyring;
  var _locked = false;

  bool get isLocked => _locked;

  SyncEngine get engine =>
      _locked ? throw const VaultLockedException() : _engine;

  void lock() {
    if (_locked) return;
    _locked = true;
    _identity.dispose();
    _localKey.dispose();
    _keyring.dispose();
  }
}

/// Use case: creating the device's vault from a passphrase and reopening it,
/// with the passphrase or with a passkey.
///
/// The passphrase is stretched with Argon2id into the MasterKey, which only
/// ever seals the identity and derives the device-local key; it is disposed
/// as soon as both exist. The passphrase is consumed by every call.
///
/// A passkey, where the platform offers one ([PasskeyPrf]), is a second
/// way in: an open vault seals its identity and local key again under a key
/// derived from the passkey's PRF output ([PasskeySlot]), so the MasterKey
/// is never needed, nor kept, to enroll. The passphrase always keeps
/// working.
final class VaultKeeper {
  VaultKeeper({
    required this._vaults,
    required this._records,
    required this._server,
    required this._identities,
    required this._keys,
    required this._subkeys,
    required this._envelopes,
    required KeyEncapsulation encapsulation,
    required this._clock,
    required this._random,
    required this._kdf,
    this._passkeys,
  }) : _encapsulation = encapsulation,
       _administration = WorkspaceAdministration(
         identities: _identities,
         encapsulation: encapsulation,
         envelopes: _envelopes,
       );

  static final _localKeyContext = KeyContext('mn-local');
  static final _passkeyContext = KeyContext('mn-passk');

  final VaultStore _vaults;
  final LocalRecordStore Function(WorkspaceId) _records;
  final SyncServer _server;
  final IdentityService _identities;
  final KeyDerivationService _keys;
  final SubkeyDerivationService _subkeys;
  final EnvelopeEncryptor _envelopes;
  final KeyEncapsulation _encapsulation;
  final PasskeyPrf? _passkeys;
  final WorkspaceAdministration _administration;
  final Clock _clock;
  final Random _random;
  final KdfParameters _kdf;

  Future<bool> get exists async => await _vaults.loadHeader() != null;

  /// Whether this platform can unlock with a passkey at all.
  bool get offersPasskeys => _passkeys != null;

  /// Whether a passkey is enrolled and this platform can use it.
  Future<bool> get hasPasskey async =>
      _passkeys != null && await _vaults.loadPasskey() != null;

  /// Founds a personal workspace owned by a new device identity.
  Future<UnlockedVault> create(PasswordSecret password) async {
    final SymmetricKey master;
    final Salt salt;
    try {
      if (await exists) throw const VaultAlreadyExistsException();
      salt = _keys.newSalt();
      master = await _keys.deriveKey(
        password: password,
        salt: salt,
        parameters: _kdf,
      );
    } finally {
      password.dispose();
    }

    final identity = _identities.generateIdentity();
    final founded = _administration.found(
      WorkspaceId.random(_random),
      founder: identity,
    );
    final SymmetricKey localKey;
    final VaultHeader header;
    try {
      header = VaultHeader.sealing(
        salt: salt,
        kdf: _kdf,
        workspace: founded.record.workspace,
        founder: MemberId.of(identity.publicIdentity),
        localKeyId: _subkeys.newSubkeyId(),
        seal: (slot) => _identities.sealIdentity(
          identity,
          key: master,
          associatedData: slot,
        ),
      );
      localKey = _localKey(master, header);
    } catch (_) {
      identity.dispose();
      founded.keyring.dispose();
      rethrow;
    } finally {
      master.dispose();
    }

    try {
      await _vaults.create(
        header,
        membership: [founded.record],
        bundles: [founded.bundle!],
      );
    } catch (_) {
      identity.dispose();
      localKey.dispose();
      founded.keyring.dispose();
      rethrow;
    }
    return _open(header, identity, localKey, founded.ledger, founded.keyring);
  }

  /// Throws [NoVaultException], [WrongPassphraseException], or
  /// [TamperedWorkspaceDataException] when the stored log does not verify.
  Future<UnlockedVault> unlock(PasswordSecret password) async {
    final VaultHeader header;
    final SymmetricKey master;
    try {
      header = await _vaults.loadHeader() ?? (throw const NoVaultException());
      master = await _keys.deriveKey(
        password: password,
        salt: header.salt,
        parameters: header.kdf,
      );
    } finally {
      password.dispose();
    }

    final IdentityKeyPair identity;
    final SymmetricKey localKey;
    try {
      identity = _identities.openIdentity(
        header.sealedIdentity,
        key: master,
        associatedData: header.identitySlot,
      );
      localKey = _localKey(master, header);
    } on AuthenticationTagMismatchException {
      throw const WrongPassphraseException();
    } finally {
      master.dispose();
    }

    return _verified(header, identity, localKey);
  }

  /// Opens the vault with the enrolled passkey: the user confirms on the
  /// authenticator and its PRF output, through a subkey, opens the identity
  /// and then the local key.
  ///
  /// Throws [NoVaultException], [NoPasskeyException],
  /// [PasskeyRejectedException], the port's [PasskeyCancelledException] or
  /// [PasskeyUnsupportedException], or [TamperedWorkspaceDataException].
  Future<UnlockedVault> unlockWithPasskey() async {
    final passkeys = _passkeys ?? (throw const PasskeyUnsupportedException());
    final header =
        await _vaults.loadHeader() ?? (throw const NoVaultException());
    final slot =
        await _vaults.loadPasskey() ?? (throw const NoPasskeyException());
    final prf = await passkeys.evaluate(slot.credential, salt: slot.salt);
    final SymmetricKey passkeyKey;
    try {
      passkeyKey = _subkeys.deriveSubkey(
        parent: prf,
        context: _passkeyContext,
        id: slot.keyId,
      );
    } finally {
      prf.dispose();
    }

    final IdentityKeyPair identity;
    try {
      identity = _identities.openIdentity(
        slot.sealedIdentity,
        key: passkeyKey,
        associatedData: slot.identitySlot(header),
      );
    } on AuthenticationTagMismatchException {
      throw const PasskeyRejectedException();
    } finally {
      passkeyKey.dispose();
    }
    final SymmetricKey localKey;
    try {
      // The identity must also be the founder the header pins, or a slot
      // could smuggle in an identity of its own.
      if (MemberId.of(identity.publicIdentity) != header.founder) {
        throw const PasskeyRejectedException();
      }
      localKey = _encapsulation.open(
        slot.sealedLocalKey,
        recipient: identity,
        associatedData: slot.localKeySlot(header),
      );
    } on AuthenticationTagMismatchException {
      identity.dispose();
      throw const PasskeyRejectedException();
    } catch (_) {
      identity.dispose();
      rethrow;
    }
    return _verified(header, identity, localKey);
  }

  /// Registers a new passkey and seals the open [vault]'s identity and
  /// local key under it, replacing any passkey enrolled before.
  Future<void> enrollPasskey(UnlockedVault vault) async {
    final passkeys = _passkeys ?? (throw const PasskeyUnsupportedException());
    if (vault.isLocked) throw const VaultLockedException();
    final header =
        await _vaults.loadHeader() ?? (throw const NoVaultException());
    final previous = await _vaults.loadPasskey();
    final salt = PrfSalt.fromBytes(
      List.generate(PrfSalt.length, (_) => _random.nextInt(256)),
    );
    final registered = await passkeys.register(salt: salt);
    final keyId = _subkeys.newSubkeyId();
    final PasskeySlot slot;
    try {
      // Locked while the user was at the authenticator: nothing to seal.
      if (vault.isLocked) throw const VaultLockedException();
      final passkeyKey = _subkeys.deriveSubkey(
        parent: registered.key,
        context: _passkeyContext,
        id: keyId,
      );
      try {
        slot = PasskeySlot.sealing(
          header: header,
          credential: registered.credential,
          salt: salt,
          keyId: keyId,
          sealIdentity: (data) => _identities.sealIdentity(
            vault._identity,
            key: passkeyKey,
            associatedData: data,
          ),
          sealLocalKey: (data) => _encapsulation.seal(
            vault._localKey,
            recipient: vault._identity.publicIdentity.encryptionKey,
            associatedData: data,
          ),
        );
      } finally {
        passkeyKey.dispose();
      }
    } catch (_) {
      await passkeys.forget(registered.credential);
      rethrow;
    } finally {
      registered.key.dispose();
    }
    await _vaults.savePasskey(slot);
    if (previous != null && previous.credential != slot.credential) {
      await passkeys.forget(previous.credential);
    }
  }

  /// Removes the enrolled passkey; the passphrase remains the only way in.
  Future<void> removePasskey() async {
    final slot = await _vaults.loadPasskey();
    if (slot == null) return;
    await _vaults.removePasskey();
    await _passkeys?.forget(slot.credential);
  }

  static final _settingName = RegExp(r'^[a-z0-9][a-z0-9.-]{0,63}$');

  /// A small device-only value, such as the sync account's session, sealed
  /// under the open [vault]'s local key; null when none is stored. A value
  /// that does not open under [name] (moved, edited) reads as absent.
  Future<Uint8List?> loadSetting(UnlockedVault vault, String name) async {
    _checkSettingName(name);
    if (vault.isLocked) throw const VaultLockedException();
    final sealed = await _vaults.loadSetting(name);
    if (sealed == null) return null;
    if (vault.isLocked) throw const VaultLockedException();
    try {
      return _envelopes.open(
        sealed,
        key: vault._localKey,
        associatedData: _settingSlot(vault, name),
      );
    } on AuthenticationTagMismatchException {
      return null;
    }
  }

  /// Seals [value] under [name] in the open [vault], or removes the setting
  /// when [value] is null.
  Future<void> saveSetting(
    UnlockedVault vault,
    String name,
    Uint8List? value,
  ) async {
    _checkSettingName(name);
    if (vault.isLocked) throw const VaultLockedException();
    await _vaults.saveSetting(
      name,
      value == null
          ? null
          : _envelopes.seal(
              value,
              key: vault._localKey,
              associatedData: _settingSlot(vault, name),
            ),
    );
  }

  static void _checkSettingName(String name) {
    if (!_settingName.hasMatch(name)) {
      throw ArgumentError.value(name, 'name', 'not a setting name');
    }
  }

  static AssociatedData _settingSlot(UnlockedVault vault, String name) =>
      AssociatedData.forContext(
        'modusnote.vault.setting.v1',
        '${vault.workspace.hex}.$name',
      );

  /// Verifies the stored log against the founder the header pins and
  /// accepts the stored key bundles, then opens the vault.
  Future<UnlockedVault> _verified(
    VaultHeader header,
    IdentityKeyPair identity,
    SymmetricKey localKey,
  ) async {
    final keyring = GroupKeyring(header.workspace);
    try {
      final ledger = MembershipLedger(_identities).verify(
        await _vaults.loadMembership(),
        invitation: Invitation(
          workspace: header.workspace,
          founder: header.founder,
        ),
      );
      for (final bundle in await _vaults.loadKeyBundles()) {
        _administration.accept(
          bundle,
          ledger: ledger,
          me: identity,
          keyring: keyring,
        );
      }
      return _open(header, identity, localKey, ledger, keyring);
    } catch (_) {
      identity.dispose();
      localKey.dispose();
      keyring.dispose();
      rethrow;
    }
  }

  SymmetricKey _localKey(SymmetricKey master, VaultHeader header) =>
      _subkeys.deriveSubkey(
        parent: master,
        context: _localKeyContext,
        id: header.localKeyId,
      );

  UnlockedVault _open(
    VaultHeader header,
    IdentityKeyPair identity,
    SymmetricKey localKey,
    VerifiedLedger ledger,
    GroupKeyring keyring,
  ) => UnlockedVault._(
    member: MemberId.of(identity.publicIdentity),
    workspace: header.workspace,
    identity: identity,
    localKey: localKey,
    keyring: keyring,
    engine: SyncEngine(
      server: _server,
      store: _records(header.workspace),
      identities: _identities,
      administration: _administration,
      contents: WorkspaceContentCipher(_envelopes),
      envelopes: _envelopes,
      localKey: localKey,
      clock: _clock,
      me: identity,
      ledger: ledger,
      keyring: keyring,
    ),
  );
}
