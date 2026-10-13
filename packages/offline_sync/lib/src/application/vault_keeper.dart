import 'dart:math';
import 'dart:typed_data';

import 'package:collaboration_access_control/collaboration_access_control.dart';
import 'package:identity_cryptography/identity_cryptography.dart';

import '../core/device_link.dart';
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
    this._links,
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

  /// Where devices of one account meet to link; null without a server.
  final DeviceLinkChannel? _links;
  final WorkspaceAdministration _administration;
  final Clock _clock;
  final Random _random;
  final KdfParameters _kdf;

  Future<bool> get exists async => await _vaults.loadHeader() != null;

  /// Whether this platform can unlock with a passkey at all.
  bool get offersPasskeys => _passkeys != null;

  /// Whether this build can link devices into one workspace.
  bool get offersLinking => _links != null;

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
      // The identity must also be the member the header pins, or a slot
      // could smuggle in an identity of its own.
      if (MemberId.of(identity.publicIdentity) != header.member) {
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
      journal: _vaults,
    ),
  );

  /// How long a code stays good, on both devices.
  static const linkLifetime = Duration(minutes: 10);

  DeviceLinkChannel get _channel =>
      _links ?? (throw UnsupportedError('no server to link devices through'));

  /// Starts linking another device into the open [vault]'s workspace:
  /// stretches [code] (a fresh [LinkCode], shown to the user) with Argon2id
  /// and posts the workspace's [Invitation] sealed under it. The returned
  /// [LinkOffering] admits the device that answers with the same code.
  ///
  /// [code] is consumed.
  Future<LinkOffering> offerLink(
    UnlockedVault vault,
    PasswordSecret code,
  ) async {
    final links = _channel;
    final id = LinkId.random(_random);
    final salt = _keys.newSalt();
    final SymmetricKey key;
    try {
      if (vault.isLocked) throw const VaultLockedException();
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
      await links.postOffer(
        LinkOffer(
          id: id,
          salt: salt,
          sealedInvitation: _envelopes.seal(
            invitation.toBytes(),
            key: key,
            associatedData: LinkOffer.associatedData(id),
          ),
        ),
      );
    } catch (_) {
      key.dispose();
      rethrow;
    }
    return LinkOffering._(
      keeper: this,
      vault: vault,
      id: id,
      key: key,
      expiresAt: _clock.now().add(linkLifetime),
    );
  }

  /// Joins the workspace of another device of this account, on a device
  /// with no vault yet: opens that device's offer with [code], posts this
  /// device's new identity back under the same key, and stretches
  /// [passphrase] into the MasterKey of the vault to be. The returned
  /// [LinkRequest] creates the vault once the other device has admitted
  /// this one.
  ///
  /// Throws [VaultAlreadyExistsException], [LinkCodeRejectedException] or
  /// [ServerUnavailableException]. [code] and [passphrase] are consumed.
  Future<LinkRequest> join({
    required PasswordSecret code,
    required PasswordSecret passphrase,
  }) async {
    SymmetricKey? linkKey;
    SymmetricKey? master;
    IdentityKeyPair? identity;
    try {
      final links = _channel;
      if (await exists) throw const VaultAlreadyExistsException();
      final offer =
          await links.latestOffer() ??
          (throw const LinkCodeRejectedException());
      linkKey = await _keys.deriveKey(
        password: code,
        salt: offer.salt,
        parameters: _kdf,
      );
      final Invitation invitation;
      try {
        invitation = Invitation.parse(
          _envelopes.open(
            offer.sealedInvitation,
            key: linkKey,
            associatedData: LinkOffer.associatedData(offer.id),
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
      await links.postAnswer(
        LinkAnswer(
          id: offer.id,
          sealedIdentity: _envelopes.seal(
            identity.publicIdentity.toBytes(),
            key: linkKey,
            associatedData: LinkAnswer.associatedData(offer.id),
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
      linkKey?.dispose();
      master?.dispose();
      identity?.dispose();
    }
  }
}

/// A link offered from an open vault, waiting for the new device's answer.
/// It holds the code's key until it admits a device, expires or is
/// cancelled.
final class LinkOffering {
  LinkOffering._({
    required this._keeper,
    required this._vault,
    required this.id,
    required this._key,
    required this.expiresAt,
  });

  final VaultKeeper _keeper;
  final UnlockedVault _vault;
  final LinkId id;
  final SymmetricKey _key;
  final DateTime expiresAt;

  bool get isClosed => _key.isDisposed;

  /// Looks for an answer sealed with the code and admits its device: the
  /// member id it now has, or null while no one has answered. An answer
  /// that does not open is ignored, so only the code's holder gets in.
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
    final links = _keeper._channel;
    for (final answer in await links.answers(id)) {
      if (answer.id != id) continue;
      if (isClosed) throw const LinkExpiredException();
      final PublicIdentity device;
      try {
        device = PublicIdentity.parse(
          _keeper._envelopes.open(
            answer.sealedIdentity,
            key: _key,
            associatedData: LinkAnswer.associatedData(id),
          ),
        );
      } on CryptographyException {
        continue;
      }
      final member = MemberId.of(device);
      // Only the code's holder could seal it, but this device is not new.
      if (member == _vault.member) continue;
      if (_vault.isLocked) throw const VaultLockedException();
      await _vault.engine.admit(device);
      cancel();
      try {
        await links.close(id);
      } on ServerUnavailableException {
        // The rows expire on the server anyway.
      }
      return member;
    }
    return null;
  }

  void cancel() => _key.dispose();
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
    final records = await keeper._server.membership(workspace, from: 0);
    if (records.isEmpty) return null;
    final ledger = MembershipLedger(keeper._identities)
        .verify(records, invitation: _invitation);
    final me = MemberId.of(_identity.publicIdentity);
    if (!ledger.workspace.isMember(me)) return null;

    final bundles = await keeper._server.keyBundles(workspace, after: 0);
    if (isClosed) throw const LinkExpiredException();
    final keyring = GroupKeyring(workspace);
    final granted = <KeyBundle>[];
    var cursor = 0;
    for (final (position, bundle) in bundles) {
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
