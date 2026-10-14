import 'package:collaboration_access_control/collaboration_access_control.dart';
import 'package:identity_cryptography/identity_cryptography.dart';

import '../core/conflict_resolver.dart';
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

  /// Rows authenticated and merged (including ones that changed nothing).
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
  Future<SyncReport> sync() async {
    try {
      await _publishMembership();
      final pushed = await _push();
      await _catchUpMembership();
      await _acceptKeyBundles();
      return await _pull(pushed);
    } on ServerUnavailableException {
      return const SyncReport(offline: true);
    }
  }

  /// Admits another device of the same person as an owner: appends it to
  /// the membership log, publishes the record and grants it every GroupKey
  /// this device holds. Safe to repeat: a device already admitted is only
  /// granted the keys again, in case its first bundle never went out.
  Future<void> admit(PublicIdentity device) async {
    await _publishMembership();
    await _catchUpMembership();
    final id = MemberId.of(device);
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
        role: Role.owner,
      );
      await _journal?.appendMembership([update.record]);
      _ledger = update.ledger;
      await _publishMembership();
      bundle = update.bundle!;
    }
    await _server.appendKeyBundle(bundle);
  }

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

enum _Merged { applied, conflict, rejected, undecryptable }
