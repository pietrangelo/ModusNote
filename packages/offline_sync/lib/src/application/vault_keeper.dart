import 'dart:math';

import 'package:collaboration_access_control/collaboration_access_control.dart';
import 'package:identity_cryptography/identity_cryptography.dart';

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
    required this._secrets,
    required this._keyring,
  });

  final MemberId member;
  final WorkspaceId workspace;
  final SyncEngine _engine;
  final List<Secret> _secrets;
  final GroupKeyring _keyring;
  var _locked = false;

  bool get isLocked => _locked;

  SyncEngine get engine =>
      _locked ? throw const VaultLockedException() : _engine;

  void lock() {
    if (_locked) return;
    _locked = true;
    for (final secret in _secrets) {
      secret.dispose();
    }
    _keyring.dispose();
  }
}

/// Use case: creating the device's vault from a passphrase and reopening it.
///
/// The passphrase is stretched with Argon2id into the MasterKey, which only
/// ever seals the identity and derives the device-local key; it is disposed
/// as soon as both exist. The passphrase is consumed by every call.
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
  }) : _administration = WorkspaceAdministration(
         identities: _identities,
         encapsulation: encapsulation,
         envelopes: _envelopes,
       );

  static final _localKeyContext = KeyContext('mn-local');

  final VaultStore _vaults;
  final LocalRecordStore Function(WorkspaceId) _records;
  final SyncServer _server;
  final IdentityService _identities;
  final KeyDerivationService _keys;
  final SubkeyDerivationService _subkeys;
  final EnvelopeEncryptor _envelopes;
  final WorkspaceAdministration _administration;
  final Clock _clock;
  final Random _random;
  final KdfParameters _kdf;

  Future<bool> get exists async => await _vaults.loadHeader() != null;

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
    secrets: [identity, localKey],
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
