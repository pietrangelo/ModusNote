import 'dart:typed_data';

import 'package:collaboration_access_control/collaboration_access_control.dart';
import 'package:identity_cryptography/identity_cryptography.dart';

import '../core/conflict_resolver.dart';
import '../core/device_link.dart';
import '../core/local_record.dart';
import '../core/record_revision.dart';
import '../core/sync_exception.dart';
import '../core/sync_row.dart';
import '../core/version_vector.dart';
import 'ports.dart';
import 'revision_authenticator.dart';

/// What one [SyncEngine.sync] did.
final class SyncReport {
  const SyncReport({
    this.offline = false,
    this.pushed = 0,
    this.pulled = 0,
    this.conflicts = 0,
    this.rejected = 0,
    this.undecryptable = 0,
  });

  /// The server was unreachable; queued edits are still queued.
  final bool offline;
  final int pushed;

  /// Rows authenticated and merged that changed the local copy (a device's
  /// own row coming back changes nothing, so it does not count).
  final int pulled;

  /// Concurrent edits resolved by last-writer-wins.
  final int conflicts;

  /// Rows that failed decryption, parsing or authentication: discarded.
  final int rejected;

  /// Rows under an epoch this device holds no key for.
  final int undecryptable;
}

/// Use case: offline-first editing and sync of one workspace's records.
///
/// Writes land locally first (sealed under the device-local key) and in the
/// outbox (sealed under the GroupKey); [sync] publishes membership records
/// the server lacks (the whole log, the first time a founder syncs), pushes
/// the outbox, catches up on membership and key bundles, then pulls and
/// merges new rows.
final class SyncEngine {
  SyncEngine({
    required this._server,
    required this._store,
    required this._identities,
    required this._administration,
    required this._contents,
    required this._envelopes,
    required this._localKey,
    required this._clock,
    required this._me,
    required this._ledger,
    required this._keyring,
    this._journal,
    this._accounts,
  }) : _ledgers = MembershipLedger(_identities),
       _authenticator = RevisionAuthenticator(_identities);

  final SyncServer _server;
  final LocalRecordStore _store;
  final IdentityService _identities;
  final WorkspaceAdministration _administration;
  final WorkspaceContentCipher _contents;
  final EnvelopeEncryptor _envelopes;
  final SymmetricKey _localKey;
  final Clock _clock;
  final IdentityKeyPair _me;
  final GroupKeyring _keyring;

  /// Where verified membership and the bundles granting this device keys
  /// are kept, so the vault reopens offline knowing all it learned.
  final VaultStore? _journal;

  /// Which server account each member uses; null where the server keeps
  /// no such list (offline builds, tests).
  final MemberAccounts? _accounts;
  final MembershipLedger _ledgers;
  final RevisionAuthenticator _authenticator;
  VerifiedLedger _ledger;

  VerifiedLedger get ledger => _ledger;

  WorkspaceId get _workspace => _ledger.workspace.id;

  MemberId get _myId => MemberId.of(_me.publicIdentity);

  LedgerHead get ledgerHead => LedgerHead(
    sequence: _ledger.records.last.sequence,
    signature: _ledger.records.last.signature,
  );

  /// The epoch new content is sealed under.
  KeyEpoch get currentEpoch => _ledger.workspace.epoch;

  /// This device's own member id.
  MemberId get me => _myId;

  /// An owner removed this device: it no longer syncs nor writes.
  bool get removed => !_ledger.workspace.isMember(_myId);

  /// The GroupKey of [epoch], as the parent of BlobKeys. It stays owned by
  /// this engine's keyring: callers use it and never dispose it. Throws
  /// [MissingGroupKeyException] for an epoch this device holds no key for.
  SymmetricKey contentKeyFor(KeyEpoch epoch) => _keyring.keyFor(epoch);

  Future<RevisionBody?> read(RecordId id) async =>
      (await _loadLocal(id))?.current.revision.body;

  /// Every record that currently has contents; deleted ones are left out.
  Future<Map<RecordId, RevisionContents>> records() async {
    final live = <RecordId, RevisionContents>{};
    for (final id in await _store.recordIds()) {
      if (await read(id) case final RevisionContents contents) {
        live[id] = contents;
      }
    }
    return live;
  }

  /// Records an edit (or a deletion) locally and queues it for the server.
  /// Works offline; fails only if this device may not write.
  Future<void> write(RecordId id, RevisionBody body) async {
    // Read before the local record: every row up to this cursor has been
    // merged into what is loaded next, even if a pull finishes in between.
    final pulled = await _store.loadCursor(SyncStream.rows);
    final unreadable = await _store.loadUnreadable(id);
    final local = await _loadLocal(id);
    final version = (local?.seen ?? VersionVector.empty).increment(_myId);
    final revision = RecordRevision(
      record: id,
      workspace: _workspace,
      version: version,
      author: _myId,
      writtenAt: _after(local?.latest, _clock.now().toUtc()),
      ledgerHead: ledgerHead,
      body: body,
    );
    final signed = SignedRevision(
      revision: revision,
      signature: _identities.sign(revision.signable, signer: _me),
    );
    final row = SealedRow(
      record: id,
      ciphertext: _contents.seal(
        signed.toBytes(),
        workspace: _ledger.workspace,
        author: _myId,
        keyring: _keyring,
        recordId: id.hex,
      ),
      // Annotated now, not when pushed: a pull before the push may bring a
      // concurrent revision this one has not seen.
      supersedes: unreadable == null || unreadable > pulled
          ? pulled
          : unreadable - 1,
    );
    await _saveLocal(LocalRecord(current: signed, seen: version));
    await _store.saveOutbox((await _store.loadOutbox()).enqueue(row));
  }

  /// The largest time the wire carries (2^53 - 1 µs, in 2255).
  static const _maxMicroseconds = 9007199254740991;

  /// [now], unless the record has a revision written at or after it: then
  /// one microsecond later than that, so an edit is always later than what
  /// it saw, even on a clock running behind.
  static DateTime _after(DateTime? latest, DateTime now) {
    if (latest == null || now.isAfter(latest)) return now;
    final micros = latest.microsecondsSinceEpoch;
    return micros >= _maxMicroseconds
        ? latest
        : DateTime.fromMicrosecondsSinceEpoch(micros + 1, isUtc: true);
  }

  /// Whether edits written here still wait in the queue for the server.
  Future<bool> hasUnsentWrites() async =>
      (await _store.loadOutbox()).pending.isNotEmpty;

  /// Throws [LedgerRollbackException] when the server hides or forks the
  /// membership log, and [TamperedWorkspaceDataException] when it serves a
  /// log that fails verification; nothing past that point is applied.
  ///
  /// Throws [RemovedFromWorkspaceException] once this device learns that an
  /// owner removed it.
  Future<SyncReport> sync() async {
    if (removed) throw const RemovedFromWorkspaceException();
    try {
      await _publishMembership();
      await _publishPendingBundle();
      await _publishPendingRemovals();
      final pushed = await _push();
      final heads = await _server.heads(_workspace);
      if (heads == null || heads.membership > _ledger.records.length) {
        await _catchUpMembership();
        if (removed) throw const RemovedFromWorkspaceException();
      }
      if (heads == null ||
          heads.keyBundles > await _store.loadCursor(SyncStream.keyBundles)) {
        await _acceptKeyBundles();
      }
      if (heads == null ||
          heads.rows > await _store.loadCursor(SyncStream.rows)) {
        return await _pull(pushed);
      }
      return SyncReport(pushed: pushed);
    } on ServerUnavailableException {
      return const SyncReport(offline: true);
    }
  }

  /// Admits [device] with [role]: lets its server [account] in (this
  /// device's own when null, for another device of the same person),
  /// appends it to the membership log, publishes the record and grants it
  /// every GroupKey this device holds. Safe to repeat: a device already
  /// admitted is only granted the keys again, in case its first bundle
  /// never went out.
  Future<void> admit(
    PublicIdentity device, {
    Role role = Role.owner,
    AccountId? account,
  }) async {
    if (removed) throw const RemovedFromWorkspaceException();
    await _publishMembership();
    await _catchUpMembership();
    final id = MemberId.of(device);
    await _accounts?.admitMember(
      _workspace,
      id,
      account: account,
      manages: role.managesMembers,
      writes: role.writesContent,
    );
    final KeyBundle bundle;
    if (_ledger.workspace.isMember(id)) {
      bundle = _administration.grantAll(
        _ledger,
        _keyring,
        issuer: _me,
        recipient: id,
      );
    } else {
      final update = _administration.invite(
        _ledger,
        _keyring,
        owner: _me,
        invitee: device,
        role: role,
      );
      await _journal?.appendMembership([update.record]);
      _ledger = update.ledger;
      await _publishMembership();
      bundle = update.bundle!;
    }
    await _server.appendKeyBundle(bundle);
  }

  /// Removes [member], another device or person, and rotates the GroupKey:
  /// what anyone writes from now on is sealed under a key granted only to
  /// those who remain. [member] keeps what it already holds.
  ///
  /// Needs the server, to see the latest membership first; offline it
  /// throws [ServerUnavailableException] with nothing changed. Once the
  /// signed record exists here, a failure to publish it or its keys is
  /// finished by the next [sync], even after the vault was locked.
  Future<void> revoke(MemberId member) async {
    if (removed) throw const RemovedFromWorkspaceException();
    await _publishMembership();
    await _publishPendingBundle();
    await _catchUpMembership();
    final update = _administration.revoke(
      _ledger,
      _keyring,
      owner: _me,
      member: member,
    );
    final bundle = update.bundle!;
    // Kept before anything leaves: the new key exists nowhere else yet, and
    // the vault must reopen holding it.
    await _journal?.appendMembership([update.record]);
    await _journal?.appendKeyBundles([bundle]);
    await _savePendingBundle(bundle);
    _ledger = update.ledger;
    await _savePendingRemovals({...await _loadPendingRemovals(), member});
    await _publishMembership();
    await _publishPendingBundle();
    await _publishPendingRemovals();
  }

  /// Members removed here whose server accounts are still to be shut out.
  static const _pendingRemovals = 'sync.pending-removals';

  Future<Set<MemberId>> _loadPendingRemovals() async {
    final journal = _journal;
    if (_accounts == null) return {};
    if (journal == null) return {..._unsavedRemovals};
    final sealed = await journal.loadSetting(_pendingRemovals);
    if (sealed == null) return {};
    try {
      final bytes = _envelopes.open(
        sealed,
        key: _localKey,
        associatedData: _removalsSlot,
      );
      final keys = <MemberId>{};
      for (var i = 0; i + 32 <= bytes.length; i += 32) {
        keys.add(
          MemberId(
            PublicSigningKey.fromBytes(Uint8List.sublistView(bytes, i, i + 32)),
          ),
        );
      }
      return keys;
    } on CryptographyException {
      return {};
    }
  }

  Future<void> _savePendingRemovals(Set<MemberId> members) async {
    final journal = _journal;
    if (_accounts == null) return;
    if (journal == null) {
      _unsavedRemovals = members;
      return;
    }
    await journal.saveSetting(
      _pendingRemovals,
      members.isEmpty
          ? null
          : _envelopes.seal(
              Uint8List.fromList([
                for (final member in members) ...member.signingKey.bytes,
              ]),
              key: _localKey,
              associatedData: _removalsSlot,
            ),
    );
  }

  Set<MemberId> _unsavedRemovals = {};

  Future<void> _publishPendingRemovals() async {
    final accounts = _accounts;
    if (accounts == null) return;
    final pending = await _loadPendingRemovals();
    if (pending.isEmpty) return;
    for (final member in pending) {
      await accounts.removeMember(_workspace, member);
    }
    await _savePendingRemovals({});
  }

  AssociatedData get _removalsSlot => AssociatedData.forContext(
    'modusnote.pending-removals.v1',
    _workspace.hex,
  );

  /// A rotation's bundle waits here until the server holds it: until then
  /// the other members cannot write under the new epoch.
  static const _pendingBundle = 'sync.pending-bundle';

  Future<void> _savePendingBundle(KeyBundle? bundle) async {
    final journal = _journal;
    if (journal == null) {
      _unsavedBundle = bundle;
      return;
    }
    await journal.saveSetting(
      _pendingBundle,
      bundle == null
          ? null
          : _envelopes.seal(
              bundle.toBytes(),
              key: _localKey,
              associatedData: _pendingSlot,
            ),
    );
  }

  /// Where there is no journal (tests), the pending bundle lives here.
  KeyBundle? _unsavedBundle;

  Future<KeyBundle?> _loadPendingBundle() async {
    final journal = _journal;
    if (journal == null) return _unsavedBundle;
    final sealed = await journal.loadSetting(_pendingBundle);
    if (sealed == null) return null;
    try {
      return KeyBundle.parse(
        _envelopes.open(sealed, key: _localKey, associatedData: _pendingSlot),
      );
    } on CryptographyException {
      return null;
    } on CollaborationException {
      return null;
    }
  }

  Future<void> _publishPendingBundle() async {
    final bundle = await _loadPendingBundle();
    if (bundle == null) return;
    // Sent again if the first answer was lost: a repeated grant changes
    // nothing for those who receive it.
    await _server.appendKeyBundle(bundle);
    await _savePendingBundle(null);
  }

  AssociatedData get _pendingSlot =>
      AssociatedData.forContext('modusnote.pending-bundle.v1', _workspace.hex);

  Future<int> _push() async {
    final rows = (await _store.loadOutbox()).pending;
    if (rows.isEmpty) return 0;
    await _server.push(_workspace, rows);
    // Re-read: an edit made while the push was in flight stays queued.
    await _store.saveOutbox((await _store.loadOutbox()).acknowledge(rows));
    return rows.length;
  }

  /// Appends the local membership records the server does not hold yet.
  /// The founder first registers the workspace; records the server already
  /// holds (a sync cut short after appending them) must be ours, or the
  /// server is serving another log under this workspace.
  Future<void> _publishMembership() async {
    final local = _ledger.records;
    var published = await _store.loadCursor(SyncStream.membership);
    if (published >= local.length) return;
    if (published == 0 && local.first.author == _myId) {
      await _server.createWorkspace(_workspace);
    }
    final held = await _server.membership(_workspace, from: published);
    for (final record in held) {
      if (record.sequence >= local.length) break;
      if (record != local[record.sequence]) {
        throw const LedgerRollbackException();
      }
      published = record.sequence + 1;
    }
    for (final record in local.skip(published)) {
      await _server.appendMembership(record);
      await _store.saveCursor(SyncStream.membership, record.sequence + 1);
    }
    await _store.saveCursor(SyncStream.membership, local.length);
  }

  Future<void> _catchUpMembership() async {
    final newer = await _server.membership(
      _workspace,
      from: _ledger.records.length,
    );
    if (newer.isNotEmpty) {
      _ledger = _ledgers.extend(_ledger, newer);
      await _journal?.appendMembership(newer);
    }
    // Whatever came from the server, the server holds.
    await _store.saveCursor(SyncStream.membership, _ledger.records.length);
  }

  Future<void> _acceptKeyBundles() async {
    var cursor = await _store.loadCursor(SyncStream.keyBundles);
    final granted = <KeyBundle>[];
    for (final (position, bundle) in await _server.keyBundles(
      _workspace,
      after: cursor,
    )) {
      // A bundle can arrive before the record it names: wait for that
      // record instead of skipping a key this device may need.
      if (bundle.atSequence >= _ledger.records.length) break;
      try {
        _administration.accept(
          bundle,
          ledger: _ledger,
          me: _me,
          keyring: _keyring,
        );
        if (bundle.grants.any((grant) => grant.recipient == _myId)) {
          granted.add(bundle);
        }
      } on CollaborationException {
        // A bundle that fails verification grants nothing; the next one
        // may still be valid.
      }
      cursor = position;
    }
    if (granted.isNotEmpty) await _journal?.appendKeyBundles(granted);
    await _store.saveCursor(SyncStream.keyBundles, cursor);
  }

  Future<SyncReport> _pull(int pushed) async {
    var cursor = await _store.loadCursor(SyncStream.rows);
    var pulled = 0;
    var conflicts = 0;
    var rejected = 0;
    var undecryptable = 0;
    try {
      for (final PulledRow(cursor: position, :row) in await _server.pull(
        _workspace,
        after: cursor,
      )) {
        switch (await _merge(row, position)) {
          case _Merged.applied:
            pulled++;
          case _Merged.conflict:
            pulled++;
            conflicts++;
          case _Merged.rejected:
            rejected++;
          case _Merged.undecryptable:
            undecryptable++;
          case _Merged.unchanged:
        }
        cursor = position;
      }
    } finally {
      // Rows already merged stay merged even if a later one stops the sync.
      await _store.saveCursor(SyncStream.rows, cursor);
    }
    return SyncReport(
      pushed: pushed,
      pulled: pulled,
      conflicts: conflicts,
      rejected: rejected,
      undecryptable: undecryptable,
    );
  }

  Future<_Merged> _merge(SealedRow row, int position) async {
    final SignedRevision incoming;
    try {
      incoming = SignedRevision.parse(
        _contents.open(
          row.ciphertext,
          keyring: _keyring,
          recordId: row.record.hex,
        ),
      );
      await _authenticate(incoming, row);
    } on MissingGroupKeyException {
      // Another device may read it: no edit here may claim to supersede it.
      await _store.markUnreadable(row.record, position);
      return _Merged.undecryptable;
    } on CryptographyException {
      return _Merged.rejected;
    } on MalformedSyncDataException {
      return _Merged.rejected;
    } on RejectedRevisionException {
      return _Merged.rejected;
    }

    final local = await _loadLocal(row.record);
    if (local == null) {
      await _saveLocal(
        LocalRecord(current: incoming, seen: incoming.revision.version),
      );
      return _Merged.applied;
    }
    final resolution = ConflictResolver.resolve(local.current, incoming);
    final latest = local.latestWith(incoming.revision.writtenAt);
    if (resolution.changed ||
        resolution.seen != local.seen ||
        latest != local.latest) {
      await _saveLocal(
        LocalRecord(
          current: resolution.winner,
          seen: resolution.seen,
          latest: latest,
        ),
      );
    } else {
      return _Merged.unchanged;
    }
    return resolution.concurrent ? _Merged.conflict : _Merged.applied;
  }

  /// A revision citing membership this device has not seen triggers one
  /// catch-up; if the server still cannot show it, it is hiding the log.
  Future<void> _authenticate(SignedRevision incoming, SealedRow row) async {
    final context = SealedRowContext(
      record: row.record,
      epoch: row.ciphertext.epoch,
    );
    try {
      _authenticator.authenticate(incoming, row: context, ledger: _ledger);
    } on LedgerBehindException {
      await _catchUpMembership();
      try {
        _authenticator.authenticate(incoming, row: context, ledger: _ledger);
      } on LedgerBehindException {
        if (_authenticator.rejectsUnknownHead(incoming, _ledger)) {
          throw const RejectedRevisionException('unknown log position');
        }
        throw const LedgerRollbackException();
      }
    }
  }

  Future<LocalRecord?> _loadLocal(RecordId id) async {
    final sealed = await _store.load(id);
    if (sealed == null) return null;
    return LocalRecord.parse(
      _envelopes.open(sealed, key: _localKey, associatedData: _localSlot(id)),
    );
  }

  Future<void> _saveLocal(LocalRecord record) async {
    final id = record.current.revision.record;
    await _store.save(
      id,
      _envelopes.seal(
        record.toBytes(),
        key: _localKey,
        associatedData: _localSlot(id),
      ),
    );
  }

  AssociatedData _localSlot(RecordId id) =>
      AssociatedData.forContext('modusnote.local.v1', '${_workspace.hex}:$id');
}

enum _Merged { applied, unchanged, conflict, rejected, undecryptable }
