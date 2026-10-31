import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:collaboration_access_control/collaboration_access_control.dart';
import 'package:identity_cryptography/identity_cryptography.dart';

import '../core/invite.dart';
import '../core/passkey_slot.dart';
import '../core/record_revision.dart';
import '../core/sync_exception.dart';
import '../core/sync_row.dart';
import '../core/vault_backup.dart';
import '../core/vault_header.dart';
import 'bundle_order.dart';
import 'ports.dart';
import 'request_signer.dart';
import 'sync_engine.dart';

/// An open vault: the device identity, its local key and the GroupKeys, all
/// in native memory until [lock] releases them.
/// How a restore went: records written, and records the vault already had.
typedef BackupRestore = ({int added, int kept});

final class UnlockedVault {
  UnlockedVault._({
    required this._engine,
    required this.member,
    required this.workspace,
    required this._identity,
    required this._localKey,
    required this._keyring,
    required this.signer,
  });

  final MemberId member;
  final WorkspaceId workspace;
  final SyncEngine _engine;
  final IdentityKeyPair _identity;
  final SymmetricKey _localKey;
  final GroupKeyring _keyring;

  /// Signs this device's requests to the sync server, until [lock].
  final RequestSigner signer;
  var _locked = false;

  /// When the person last proved, at this device, that they hold the
  /// vault: see [VaultKeeper.confirm].
  DateTime? _confirmedAt;

  bool get isLocked => _locked;

  SyncEngine get engine =>
      _locked ? throw const VaultLockedException() : _engine;

  void lock() {
    if (_locked) return;
    _locked = true;
    _confirmedAt = null;
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
    required this._identities,
    required this._hasher,
    required this._keys,
    required this._subkeys,
    required this._envelopes,
    required KeyEncapsulation encapsulation,
    required this._clock,
    required this._random,
    required this._kdf,
    this._passkeys,
    this._gateway,
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
  final IdentityService _identities;
  final ContentHasher _hasher;
  final KeyDerivationService _keys;
  final SubkeyDerivationService _subkeys;
  final EnvelopeEncryptor _envelopes;
  final KeyEncapsulation _encapsulation;
  final PasskeyPrf? _passkeys;

  /// The sync server; null in builds without one, which stay offline.
  final SyncGateway? _gateway;
  final WorkspaceAdministration _administration;
  final Clock _clock;
  final Random _random;
  final KdfParameters _kdf;

  Future<bool> get exists async => await _vaults.loadHeader() != null;

  /// Whether this platform can unlock with a passkey at all.
  bool get offersPasskeys => _passkeys != null;

  /// Whether this build can bring other devices in with a code.
  bool get offersInvites => _gateway != null;

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
    final header =
        await _vaults.loadHeader() ?? (throw const NoVaultException());
    final (identity, slot) = await _passkeyIdentity(header);
    final SymmetricKey localKey;
    try {
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

  /// Asks for the enrolled passkey and opens the identity it seals, which
  /// must be the member the [header] pins.
  Future<(IdentityKeyPair, PasskeySlot)> _passkeyIdentity(
    VaultHeader header,
  ) async {
    final passkeys = _passkeys ?? (throw const PasskeyUnsupportedException());
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
    // The identity must also be the member the header pins, or a slot
    // could smuggle in an identity of its own.
    if (MemberId.of(identity.publicIdentity) != header.member) {
      identity.dispose();
      throw const PasskeyRejectedException();
    }
    return (identity, slot);
  }

  /// How long a confirmation lets the actions that give lasting access
  /// through: bringing a device or a person in, exporting a backup,
  /// enrolling a passkey. As long as the idle auto-lock.
  static const confirmationLifetime = Duration(minutes: 5);

  /// The person proves again, on the open [vault], that they hold its
  /// [password] (consumed): someone who only found the vault open, on an
  /// unlocked phone or a tab left alone, cannot then give themselves a way
  /// back in. Throws [WrongPassphraseException].
  Future<void> confirm(UnlockedVault vault, PasswordSecret password) async {
    final VaultHeader header;
    final SymmetricKey master;
    try {
      if (vault.isLocked) throw const VaultLockedException();
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
    try {
      identity = _identities.openIdentity(
        header.sealedIdentity,
        key: master,
        associatedData: header.identitySlot,
      );
    } on AuthenticationTagMismatchException {
      throw const WrongPassphraseException();
    } finally {
      master.dispose();
    }
    _confirmed(vault, identity);
  }

  /// [confirm] with the enrolled passkey, which asks the person (a
  /// fingerprint, a face, a PIN) at the authenticator. Throws as
  /// [unlockWithPasskey] does.
  Future<void> confirmWithPasskey(UnlockedVault vault) async {
    if (vault.isLocked) throw const VaultLockedException();
    final header =
        await _vaults.loadHeader() ?? (throw const NoVaultException());
    final (identity, _) = await _passkeyIdentity(header);
    _confirmed(vault, identity);
  }

  void _confirmed(UnlockedVault vault, IdentityKeyPair identity) {
    final member = MemberId.of(identity.publicIdentity);
    identity.dispose();
    // Another vault's header in this store would open its own identity.
    if (member != vault.member) throw const WrongPassphraseException();
    if (vault.isLocked) throw const VaultLockedException();
    vault._confirmedAt = _clock.now();
  }

  /// Whether the open [vault] was confirmed within [confirmationLifetime].
  /// A clock set back since counts as not confirmed.
  bool isConfirmed(UnlockedVault vault) {
    final at = vault._confirmedAt;
    if (vault.isLocked || at == null) return false;
    final now = _clock.now();
    return !now.isBefore(at) && now.difference(at) < confirmationLifetime;
  }

  void _requireConfirmed(UnlockedVault vault) {
    if (vault.isLocked) throw const VaultLockedException();
    if (!isConfirmed(vault)) throw const ConfirmationRequiredException();
  }

  /// Registers a new passkey and seals the open [vault]'s identity and
  /// local key under it, replacing any passkey enrolled before.
  Future<void> enrollPasskey(UnlockedVault vault) async {
    final passkeys = _passkeys ?? (throw const PasskeyUnsupportedException());
    _requireConfirmed(vault);
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
    _checkPlainSettingName(name);
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
    _checkPlainSettingName(name);
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

  /// Where [createDetachedIdentity] keeps an identity, among the settings
  /// but out of reach of [loadSetting] and [saveSetting].
  static const _detachedPrefix = 'identity.';

  /// A new signing identity of its own, for a service that must not learn
  /// which vault, device or workspace it serves (a site on serv.pub): it
  /// is never in the members' log and signs nothing of the workspace. It
  /// is sealed under the open [vault]'s local key as [name] and kept on
  /// this device only, replacing any identity kept under that name. Needs
  /// a fresh confirmation ([confirm]): whoever only found the vault open
  /// must not give themselves a key that outlives it.
  Future<IdentityKeyPair> createDetachedIdentity(
    UnlockedVault vault,
    String name,
  ) async {
    final setting = _detachedSetting(name);
    _requireConfirmed(vault);
    final identity = _identities.generateIdentity();
    try {
      final sealed = _identities.sealIdentity(
        identity,
        key: vault._localKey,
        associatedData: _detachedSlot(vault, name),
      );
      await _vaults.saveSetting(setting, sealed);
      if (vault.isLocked) throw const VaultLockedException();
    } catch (_) {
      identity.dispose();
      rethrow;
    }
    return identity;
  }

  /// The identity kept as [name] in the open [vault], owned by the caller;
  /// null when there is none or it does not open under that name.
  Future<IdentityKeyPair?> openDetachedIdentity(
    UnlockedVault vault,
    String name,
  ) async {
    final setting = _detachedSetting(name);
    if (vault.isLocked) throw const VaultLockedException();
    final sealed = await _vaults.loadSetting(setting);
    if (sealed == null) return null;
    if (vault.isLocked) throw const VaultLockedException();
    try {
      return _identities.openIdentity(
        sealed,
        key: vault._localKey,
        associatedData: _detachedSlot(vault, name),
      );
    } on AuthenticationTagMismatchException {
      return null;
    }
  }

  Future<void> forgetDetachedIdentity(UnlockedVault vault, String name) async {
    final setting = _detachedSetting(name);
    if (vault.isLocked) throw const VaultLockedException();
    await _vaults.saveSetting(setting, null);
  }

  /// Signs requests as [identity] (a detached one), which stays owned by
  /// the caller.
  RequestSigner signerFor(IdentityKeyPair identity) => _signer(identity);

  static String _detachedSetting(String name) {
    final setting = '$_detachedPrefix$name';
    _checkSettingName(setting);
    return setting;
  }

  static AssociatedData _detachedSlot(UnlockedVault vault, String name) =>
      AssociatedData.forContext(
        'modusnote.vault.identity.v1',
        '${vault.workspace.hex}.$name',
      );

  /// Every live record of the open [vault], sealed under a key stretched
  /// from [passphrase] (consumed) with a salt of its own: a file to keep
  /// elsewhere, which [openBackup] opens on any device, in any vault.
  Future<Uint8List> exportBackup(
    UnlockedVault vault,
    PasswordSecret passphrase,
  ) async {
    final salt = _keys.newSalt();
    final SymmetricKey key;
    try {
      _requireConfirmed(vault);
      key = await _keys.deriveKey(
        password: passphrase,
        salt: salt,
        parameters: _kdf,
      );
    } finally {
      passphrase.dispose();
    }
    try {
      final records = await vault.engine.records();
      final contents = BackupContents({
        for (final MapEntry(:key, :value) in records.entries) key: value.bytes,
      });
      return SealedBackup.sealing(
        salt: salt,
        kdf: _kdf,
        seal: (slot) =>
            _envelopes.seal(contents.toBytes(), key: key, associatedData: slot),
      ).toBytes();
    } finally {
      key.dispose();
    }
  }

  /// Opens a file written by [exportBackup] with [passphrase] (consumed).
  /// Throws [BackupRejectedException] for a wrong passphrase or a file that
  /// is not such a backup; costs out of bounds are refused before any
  /// Argon2id runs.
  Future<BackupContents> openBackup(
    List<int> file,
    PasswordSecret passphrase,
  ) async {
    final SealedBackup sealed;
    final SymmetricKey key;
    try {
      try {
        sealed = SealedBackup.parse(file);
      } on SyncException {
        throw const BackupRejectedException();
      }
      key = await _keys.deriveKey(
        password: passphrase,
        salt: sealed.salt,
        parameters: sealed.kdf,
      );
    } finally {
      passphrase.dispose();
    }
    try {
      return BackupContents.parse(
        _envelopes.open(sealed.sealed, key: key, associatedData: sealed.slot),
      );
    } on AuthenticationTagMismatchException {
      throw const BackupRejectedException();
    } on SyncException {
      throw const BackupRejectedException();
    } finally {
      key.dispose();
    }
  }

  /// Writes into the open [vault] each record of [backup] it has no live
  /// contents for, deleted ones included; a record it has is kept as it
  /// is, so a restore never takes an edit back.
  Future<BackupRestore> restoreBackup(
    UnlockedVault vault,
    BackupContents backup,
  ) async {
    if (vault.isLocked) throw const VaultLockedException();
    var added = 0;
    var kept = 0;
    for (final MapEntry(:key, :value) in backup.records.entries) {
      final engine = vault.engine;
      if (await engine.read(key) is RevisionContents) {
        kept++;
      } else {
        await engine.write(key, RevisionContents(value));
        added++;
      }
    }
    return (added: added, kept: kept);
  }

  static void _checkSettingName(String name) {
    if (!_settingName.hasMatch(name)) {
      throw ArgumentError.value(name, 'name', 'not a setting name');
    }
  }

  /// A name [loadSetting] and [saveSetting] may use: never a detached
  /// identity's.
  static void _checkPlainSettingName(String name) {
    _checkSettingName(name);
    if (name.startsWith(_detachedPrefix)) {
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

  /// Signs requests as [device], which stays owned by the caller.
  RequestSigner _signer(IdentityKeyPair device) => RequestSigner(
    identities: _identities,
    hasher: _hasher,
    device: device,
    clock: _clock,
    random: _random,
  );

  SyncServer _serverFor(RequestSigner signer) =>
      _gateway?.server(signer) ?? const _OfflineServer();

  UnlockedVault _open(
    VaultHeader header,
    IdentityKeyPair identity,
    SymmetricKey localKey,
    VerifiedLedger ledger,
    GroupKeyring keyring,
  ) {
    final signer = _signer(identity);
    return UnlockedVault._(
      member: MemberId.of(identity.publicIdentity),
      workspace: header.workspace,
      identity: identity,
      localKey: localKey,
      keyring: keyring,
      signer: signer,
      engine: SyncEngine(
        server: _serverFor(signer),
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
        journal: _vaults,
      ),
    );
  }

  /// How long a code stays good, on both devices.
  static const linkLifetime = Duration(minutes: 10);

  SyncGateway get _server =>
      _gateway ?? (throw UnsupportedError('no server to invite through'));

  /// Starts bringing a device into the open [vault]'s workspace: another
  /// of the owner's (with [Role.owner]) or another person's. [code] (a
  /// fresh [InviteCode], shown on screen) is stretched with Argon2id and
  /// seals the workspace's [Invitation], posted under the code's lookup.
  /// The returned [InviteOffering] admits, with [role], the device that
  /// answers with the same code.
  ///
  /// Throws [LookupTakenException] when another offer holds the lookup.
  /// [code] is consumed.
  Future<InviteOffering> offerInvite(
    UnlockedVault vault,
    PasswordSecret code, {
    required String lookup,
    required Role role,
  }) async {
    final invites = _server.invites(vault.signer);
    final salt = _keys.newSalt();
    final SymmetricKey key;
    try {
      _requireConfirmed(vault);
      key = await _keys.deriveKey(password: code, salt: salt, parameters: _kdf);
    } finally {
      code.dispose();
    }
    try {
      if (vault.isLocked) throw const VaultLockedException();
      final ledger = vault.engine.ledger;
      final invitation = Invitation(
        workspace: ledger.workspace.id,
        founder: ledger.records.first.author,
      );
      await invites.postInvite(
        ledger.workspace.id,
        InviteOffer(
          lookup: lookup,
          salt: salt,
          sealedInvitation: _envelopes.seal(
            invitation.toBytes(),
            key: key,
            associatedData: InviteOffer.associatedData(lookup),
          ),
        ),
      );
    } catch (_) {
      key.dispose();
      rethrow;
    }
    return InviteOffering._(
      keeper: this,
      vault: vault,
      invites: invites,
      lookup: lookup,
      role: role,
      key: key,
      expiresAt: _clock.now().add(linkLifetime),
    );
  }

  /// Joins a workspace with a code, on a device with no vault yet: opens
  /// the offer found under [lookup] with [code], posts this device's new
  /// identity back under the same key, and stretches [passphrase] into the MasterKey of the vault to
  /// be. The returned [LinkRequest] creates the vault once the owner has
  /// admitted this device.
  ///
  /// Throws [VaultAlreadyExistsException], [LinkCodeRejectedException] or
  /// [ServerUnavailableException]. [code] and [passphrase] are consumed.
  Future<LinkRequest> acceptInvite({
    required PasswordSecret code,
    required String lookup,
    required PasswordSecret passphrase,
  }) async {
    SymmetricKey? inviteKey;
    SymmetricKey? master;
    IdentityKeyPair? identity;
    try {
      final invites = _server.invites(null);
      if (await exists) throw const VaultAlreadyExistsException();
      final offer =
          await invites.invite(lookup) ??
          (throw const LinkCodeRejectedException());
      if (offer.lookup != lookup) throw const LinkCodeRejectedException();
      inviteKey = await _keys.deriveKey(
        password: code,
        salt: offer.salt,
        parameters: _kdf,
      );
      final Invitation invitation;
      try {
        invitation = Invitation.parse(
          _envelopes.open(
            offer.sealedInvitation,
            key: inviteKey,
            associatedData: InviteOffer.associatedData(lookup),
          ),
        );
      } on AuthenticationTagMismatchException {
        throw const LinkCodeRejectedException();
      } on CollaborationException {
        throw const LinkCodeRejectedException();
      }
      final salt = _keys.newSalt();
      master = await _keys.deriveKey(
        password: passphrase,
        salt: salt,
        parameters: _kdf,
      );
      identity = _identities.generateIdentity();
      await invites.postInviteAnswer(
        InviteAnswer(
          lookup: lookup,
          sealedJoiner: _envelopes.seal(
            InviteAnswer.joiner(identity.publicIdentity),
            key: inviteKey,
            associatedData: InviteAnswer.associatedData(lookup),
          ),
        ),
      );
      final request = LinkRequest._(
        keeper: this,
        invitation: invitation,
        salt: salt,
        master: master,
        identity: identity,
        expiresAt: _clock.now().add(linkLifetime),
      );
      master = null;
      identity = null;
      return request;
    } finally {
      code.dispose();
      passphrase.dispose();
      inviteKey?.dispose();
      master?.dispose();
      identity?.dispose();
    }
  }
}

/// A device waiting to be admitted, with its new identity and the
/// MasterKey of its vault to be, both released by [cancel].
final class LinkRequest {
  LinkRequest._({
    required this._keeper,
    required this._invitation,
    required this._salt,
    required this._master,
    required this._identity,
    required this.expiresAt,
  });

  final VaultKeeper _keeper;
  final Invitation _invitation;
  final Salt _salt;
  final SymmetricKey _master;
  final IdentityKeyPair _identity;
  final DateTime expiresAt;

  bool get isClosed => _master.isDisposed;

  /// Checks whether the other device has admitted this one: the open vault
  /// once the server shows a log that verifies against the offer's founder,
  /// with this device a member and a GroupKey for the current epoch; null
  /// until then.
  ///
  /// Throws [LinkExpiredException] past [expiresAt] or once closed,
  /// [TamperedWorkspaceDataException] for a log that does not verify, and
  /// [ServerUnavailableException] offline, after which a later call retries.
  Future<UnlockedVault?> poll() async {
    if (isClosed) throw const LinkExpiredException();
    final keeper = _keeper;
    if (!keeper._clock.now().isBefore(expiresAt)) {
      cancel();
      throw const LinkExpiredException();
    }
    final workspace = _invitation.workspace;
    // Signed by the new identity: the server answers once it is a member.
    final server = keeper._serverFor(keeper._signer(_identity));
    final List<MembershipRecord> records;
    try {
      records = await server.membership(workspace, from: 0);
    } on NotAdmittedException {
      return null;
    }
    if (records.isEmpty) return null;
    final ledger = MembershipLedger(keeper._identities)
        .verify(records, invitation: _invitation);
    final me = MemberId.of(_identity.publicIdentity);
    if (!ledger.workspace.isMember(me)) return null;

    final bundles = await server.keyBundles(workspace, after: 0);
    if (isClosed) throw const LinkExpiredException();
    final keyring = GroupKeyring(workspace);
    final granted = <KeyBundle>[];
    var cursor = 0;
    Future<SyncHeads?>? heads;
    for (final (position, bundle) in bundles) {
      if (bundle.atSequence >= ledger.records.length) {
        // Read again after the record it names, which the engine will
        // fetch, unless the server does not hold that record.
        if (await recordWillCome(bundle, heads ??= server.heads(workspace))) {
          break;
        }
        cursor = position;
        continue;
      }
      cursor = position;
      if (!bundle.grants.any((grant) => grant.recipient == me)) continue;
      try {
        keeper._administration.accept(
          bundle,
          ledger: ledger,
          me: _identity,
          keyring: keyring,
        );
        granted.add(bundle);
      } on CollaborationException {
        // A forged bundle grants nothing; a genuine one may follow.
      }
    }
    if (!keyring.holds(ledger.workspace.epoch)) {
      keyring.dispose();
      return null;
    }
    return _create(ledger, keyring, granted, keyBundleCursor: cursor);
  }

  Future<UnlockedVault> _create(
    VerifiedLedger ledger,
    GroupKeyring keyring,
    List<KeyBundle> granted, {
    required int keyBundleCursor,
  }) async {
    final keeper = _keeper;
    final VaultHeader header;
    final SymmetricKey localKey;
    try {
      header = VaultHeader.sealing(
        salt: _salt,
        kdf: keeper._kdf,
        workspace: _invitation.workspace,
        founder: _invitation.founder,
        member: MemberId.of(_identity.publicIdentity),
        localKeyId: keeper._subkeys.newSubkeyId(),
        seal: (slot) => keeper._identities.sealIdentity(
          _identity,
          key: _master,
          associatedData: slot,
        ),
      );
      localKey = keeper._localKey(_master, header);
    } catch (_) {
      keyring.dispose();
      _identity.dispose();
      rethrow;
    } finally {
      _master.dispose();
    }
    try {
      await keeper._vaults.create(
        header,
        membership: ledger.records,
        bundles: granted,
      );
      final records = keeper._records(header.workspace);
      await records.saveCursor(SyncStream.membership, ledger.records.length);
      await records.saveCursor(SyncStream.keyBundles, keyBundleCursor);
    } catch (_) {
      keyring.dispose();
      localKey.dispose();
      _identity.dispose();
      rethrow;
    }
    return keeper._open(header, _identity, localKey, ledger, keyring);
  }

  /// Gives up: the identity and the MasterKey are released and nothing is
  /// stored. The other device may already have admitted the identity; it
  /// stays an unused member until an owner revokes it.
  void cancel() {
    _master.dispose();
    _identity.dispose();
  }
}

/// An invitation offered from an open vault, waiting for the invited
/// person's device to answer. It holds the code's key until it admits a
/// device, expires or is cancelled.
final class InviteOffering {
  InviteOffering._({
    required this._keeper,
    required this._vault,
    required this._invites,
    required this.lookup,
    required this.role,
    required this._key,
    required this.expiresAt,
  });

  final VaultKeeper _keeper;
  final UnlockedVault _vault;
  final InviteChannel _invites;
  final String lookup;
  final Role role;
  final SymmetricKey _key;
  final DateTime expiresAt;

  bool get isClosed => _key.isDisposed;

  /// Looks for an answer sealed with the code and admits its device with
  /// [role]: the member id it now has, or null while no one has answered.
  /// An answer that does not open is ignored, so only the code's holder
  /// gets in.
  ///
  /// Throws [LinkExpiredException] past [expiresAt] or once closed,
  /// [VaultLockedException] once the vault is locked, and
  /// [ServerUnavailableException] offline, after which a later call retries.
  Future<MemberId?> poll() async {
    if (isClosed) throw const LinkExpiredException();
    if (_vault.isLocked) {
      cancel();
      throw const VaultLockedException();
    }
    if (!_keeper._clock.now().isBefore(expiresAt)) {
      cancel();
      throw const LinkExpiredException();
    }
    final invites = _invites;
    for (final answer in await invites.inviteAnswers(lookup)) {
      if (answer.lookup != lookup) continue;
      if (isClosed) throw const LinkExpiredException();
      final PublicIdentity device;
      try {
        device = InviteAnswer.readJoiner(
          _keeper._envelopes.open(
            answer.sealedJoiner,
            key: _key,
            associatedData: InviteAnswer.associatedData(lookup),
          ),
        );
      } on CryptographyException {
        continue;
      } on SyncException {
        continue;
      }
      final member = MemberId.of(device);
      if (member == _vault.member) continue;
      if (_vault.isLocked) throw const VaultLockedException();
      await _vault.engine.admit(device, role: role);
      _key.dispose();
      await _close();
      return member;
    }
    return null;
  }

  /// Withdraws the code: its key is released, and the server forgets the
  /// offer, so no one can answer it any longer.
  void cancel() {
    if (isClosed) return;
    _key.dispose();
    unawaited(_close());
  }

  Future<void> _close() async {
    try {
      await _invites.closeInvite(lookup);
    } on Object {
      // Offline or refused: the offer expires on the server anyway.
    }
  }
}

/// The server of a build without one: always out of reach, so edits wait
/// in the queue, already sealed.
final class _OfflineServer implements SyncServer {
  const _OfflineServer();

  Never _away() => throw const ServerUnavailableException();

  @override
  Future<String> serverId() async => _away();

  @override
  Future<void> createWorkspace(List<MembershipRecord> start) async => _away();

  @override
  Future<void> deleteWorkspace(WorkspaceId workspace) async => _away();

  @override
  Future<void> appendMembership(MembershipRecord record) async => _away();

  @override
  Future<void> push(WorkspaceId workspace, List<SealedRow> rows) async =>
      _away();

  @override
  Future<SyncHeads?> heads(WorkspaceId workspace) async => _away();

  @override
  Future<List<PulledRow>> pull(
    WorkspaceId workspace, {
    required int after,
  }) async => _away();

  @override
  Future<List<MembershipRecord>> membership(
    WorkspaceId workspace, {
    required int from,
  }) async => _away();

  @override
  Future<List<(int, KeyBundle)>> keyBundles(
    WorkspaceId workspace, {
    required int after,
  }) async => _away();

  @override
  Future<void> appendKeyBundle(KeyBundle bundle) async => _away();
}
