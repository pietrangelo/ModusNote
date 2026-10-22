import 'dart:typed_data';

import 'package:collaboration_access_control/collaboration_access_control.dart';
import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:offline_sync/offline_sync.dart';

/// The zero-knowledge server: append-only logs of opaque rows, membership
/// records and key bundles. It can be switched off to simulate no network.
final class FakeSyncServer implements SyncServer {
  var online = true;

  /// Every row ever appended; row `i` has position `i + 1`.
  final rows = <SealedRow>[];

  /// Positions removed as superseded, the way the real table's trigger
  /// removes them; [pull] skips them.
  final compacted = <int>{};

  /// Runs at the start of every [pull], to interleave a client's own work
  /// with a sync in flight.
  Future<void> Function()? onPull;
  final membershipLog = <MembershipRecord>[];
  final bundles = <KeyBundle>[];

  /// How many membership records it admits to having (for rollback tests).
  int? withholdMembershipAfter;

  /// How many membership records a read of the log returns, while [heads]
  /// already counts them all: a read made just before an append that the
  /// next reads see.
  int? staleMembershipReads;

  final createdWorkspaces = <WorkspaceId>[];

  /// What clients asked of it, in order: `workspace`, `membership <n>`,
  /// `push <rows>`.
  final calls = <String>[];

  /// The reads clients made, in order: `heads`, `membership`, `bundles`,
  /// `rows`.
  final reads = <String>[];

  /// Answers [heads] like a deployment from before it existed.
  var headless = false;

  /// Answers [heads] with zeros, as a server hiding that anything changed.
  var lieLow = false;

  /// Fails the next call to [appendMembership] or [createWorkspace] as if
  /// the network dropped.
  var dropNextAppend = false;

  /// Fails the next call to [appendKeyBundle] as if the network dropped.
  var dropNextBundle = false;

  void _check() {
    if (!online) throw const ServerUnavailableException();
  }

  @override
  Future<void> push(WorkspaceId workspace, List<SealedRow> rows) async {
    _check();
    calls.add('push ${rows.length}');
    for (final row in rows) {
      this.rows.add(row);
      for (var position = 1; position < this.rows.length; position++) {
        if (position <= row.supersedes &&
            this.rows[position - 1].record == row.record) {
          compacted.add(position);
        }
      }
    }
  }

  /// The rows a pull still returns.
  List<SealedRow> get live => [
    for (final (index, row) in rows.indexed)
      if (!compacted.contains(index + 1)) row,
  ];

  /// Keeps [genesis] as the log's first record, as the real server does;
  /// another first record already held is a conflict.
  @override
  Future<void> createWorkspace(MembershipRecord genesis) async {
    _check();
    if (dropNextAppend) {
      dropNextAppend = false;
      throw const ServerUnavailableException();
    }
    calls.add('workspace');
    if (!createdWorkspaces.contains(genesis.workspace)) {
      createdWorkspaces.add(genesis.workspace);
    }
    if (membershipLog.isEmpty) {
      membershipLog.add(genesis);
    } else if (membershipLog.first != genesis) {
      throw const LedgerRollbackException();
    }
  }

  @override
  Future<void> appendMembership(MembershipRecord record) async {
    _check();
    if (dropNextAppend) {
      dropNextAppend = false;
      throw const ServerUnavailableException();
    }
    calls.add('membership ${record.sequence}');
    // The real table's primary key: a sequence is written once.
    if (record.sequence != membershipLog.length) {
      throw StateError('membership sequence ${record.sequence} taken');
    }
    membershipLog.add(record);
  }

  @override
  Future<List<PulledRow>> pull(
    WorkspaceId workspace, {
    required int after,
  }) async {
    _check();
    reads.add('rows');
    await onPull?.call();
    return [
      for (var i = after; i < rows.length; i++)
        if (!compacted.contains(i + 1)) PulledRow(cursor: i + 1, row: rows[i]),
    ];
  }

  @override
  Future<List<MembershipRecord>> membership(
    WorkspaceId workspace, {
    required int from,
  }) async {
    _check();
    reads.add('membership');
    final visible = staleMembershipReads == null
        ? _visibleMembership
        : _visibleMembership.take(staleMembershipReads!).toList();
    return from >= visible.length ? const [] : visible.sublist(from);
  }

  @override
  Future<List<(int, KeyBundle)>> keyBundles(
    WorkspaceId workspace, {
    required int after,
  }) async {
    _check();
    reads.add('bundles');
    return [for (var i = after; i < bundles.length; i++) (i + 1, bundles[i])];
  }

  List<MembershipRecord> get _visibleMembership =>
      withholdMembershipAfter == null
      ? membershipLog
      : membershipLog.take(withholdMembershipAfter!).toList();

  @override
  Future<SyncHeads?> heads(WorkspaceId workspace) async {
    _check();
    reads.add('heads');
    if (headless) return null;
    if (lieLow) return SyncHeads(rows: 0, keyBundles: 0, membership: 0);
    return SyncHeads(
      rows: rows.length,
      keyBundles: bundles.length,
      membership: _visibleMembership.length,
    );
  }

  @override
  Future<void> appendKeyBundle(KeyBundle bundle) async {
    _check();
    if (dropNextBundle) {
      dropNextBundle = false;
      throw const ServerUnavailableException();
    }
    calls.add('bundle');
    bundles.add(bundle);
  }
}

/// What an account allowed to append bundles can put on the server: well
/// formed, signed by nobody, naming a membership record that never comes.
KeyBundle forgedBundle(WorkspaceId workspace, MemberId issuer) => KeyBundle(
  workspace: workspace,
  atSequence: 0xffffffff,
  issuer: issuer,
  grants: const [],
  signature: Signature.fromBytes(Uint8List(Signature.length)),
);

/// Where an owner and another person's device meet: it relays offers by
/// lookup and answers to whoever asks.
final class FakeInviteChannel implements InviteChannel {
  var online = true;
  final offers = <InviteOffer>[];
  final posted = <InviteAnswer>[];
  final closed = <String>[];

  void _check() {
    if (!online) throw const ServerUnavailableException();
  }

  @override
  Future<void> postInvite(WorkspaceId workspace, InviteOffer offer) async {
    _check();
    if (offers.any((held) => held.lookup == offer.lookup) &&
        !closed.contains(offer.lookup)) {
      throw const LookupTakenException();
    }
    closed.remove(offer.lookup);
    offers.add(offer);
  }

  @override
  Future<InviteOffer?> invite(String lookup) async {
    _check();
    return offers.where((offer) => offer.lookup == lookup).lastOrNull;
  }

  @override
  Future<void> postInviteAnswer(InviteAnswer answer) async {
    _check();
    posted.add(answer);
  }

  @override
  Future<List<InviteAnswer>> inviteAnswers(String lookup) async {
    _check();
    return [...posted.where((answer) => answer.lookup == lookup)];
  }

  @override
  Future<void> closeInvite(String lookup) async {
    _check();
    closed.add(lookup);
  }
}

/// The server as each device reaches it: requests are signed by the
/// device, and only members of the log the server holds are let in, the
/// way the real server checks them; a removed member still reads the log.
final class FakeGateway implements SyncGateway {
  FakeGateway(this.backend, [FakeInviteChannel? codes])
    : codes = codes ?? FakeInviteChannel();

  final FakeSyncServer backend;
  final FakeInviteChannel codes;

  /// Every request the devices signed, as `METHOD path`.
  final signed = <String>[];

  /// Whether it lets in only members; a hostile server lets in anyone.
  var checks = true;

  @override
  SyncServer server(RequestSigner signer) => _Admitting(this, signer);

  @override
  InviteChannel invites(RequestSigner? signer) => codes;
}

final class _Admitting implements SyncServer {
  _Admitting(this._gateway, this._signer);

  final FakeGateway _gateway;
  final RequestSigner _signer;

  FakeSyncServer get _backend => _gateway.backend;

  /// Signs as the real adapter does, so a released identity fails here.
  Future<void> _sign(String method, String path) async {
    _backend._check();
    await _signer.authorize(
      method,
      path.startsWith('/') ? path : '/api/w/$path',
      Uint8List(0),
    );
    _gateway.signed.add('$method $path');
  }

  Iterable<MembershipRecord> get _log => _backend.membershipLog;

  bool get _isMember {
    final members = <PublicSigningKey>{};
    for (final record in _log) {
      switch (record.change) {
        case WorkspaceFounded(:final founder):
          members.add(founder.signingKey);
        case MemberInvited(:final identity):
          members.add(identity.signingKey);
        case MemberRevoked(:final member):
          members.remove(member.signingKey);
        case RoleChanged():
          break;
      }
    }
    return members.contains(_signer.key);
  }

  bool get _wasMember => _log.any(
    (record) => switch (record.change) {
      WorkspaceFounded(:final founder) => founder.signingKey == _signer.key,
      MemberInvited(:final identity) => identity.signingKey == _signer.key,
      _ => false,
    },
  );

  Future<void> _admitted(String method, String path) async {
    await _sign(method, path);
    if (_gateway.checks && !_isMember) throw const NotAdmittedException();
  }

  @override
  Future<void> createWorkspace(MembershipRecord genesis) async {
    await _sign('POST', '/api/w/${genesis.workspace.hex}');
    if (genesis.author.signingKey != _signer.key) {
      throw const NotAdmittedException();
    }
    await _backend.createWorkspace(genesis);
  }

  @override
  Future<void> appendMembership(MembershipRecord record) async {
    await _admitted('POST', 'membership');
    await _backend.appendMembership(record);
  }

  @override
  Future<void> push(WorkspaceId workspace, List<SealedRow> rows) async {
    await _admitted('POST', 'rows');
    await _backend.push(workspace, rows);
  }

  @override
  Future<SyncHeads?> heads(WorkspaceId workspace) async {
    await _admitted('GET', 'heads');
    return _backend.heads(workspace);
  }

  @override
  Future<List<PulledRow>> pull(
    WorkspaceId workspace, {
    required int after,
  }) async {
    await _admitted('GET', 'rows');
    return _backend.pull(workspace, after: after);
  }

  @override
  Future<List<MembershipRecord>> membership(
    WorkspaceId workspace, {
    required int from,
  }) async {
    await _sign('GET', 'membership');
    if (_gateway.checks && !_wasMember) throw const NotAdmittedException();
    return _backend.membership(workspace, from: from);
  }

  @override
  Future<List<(int, KeyBundle)>> keyBundles(
    WorkspaceId workspace, {
    required int after,
  }) async {
    await _admitted('GET', 'bundles');
    return _backend.keyBundles(workspace, after: after);
  }

  @override
  Future<void> appendKeyBundle(KeyBundle bundle) async {
    await _admitted('POST', 'bundles');
    await _backend.appendKeyBundle(bundle);
  }
}

/// The local database: it is handed only sealed records and rows.
final class FakeLocalStore implements LocalRecordStore {
  final records = <RecordId, EncryptedEnvelope>{};
  var outbox = Outbox.empty;
  final cursors = <SyncStream, int>{};
  final unreadable = <RecordId, int>{};

  @override
  Future<EncryptedEnvelope?> load(RecordId id) async => records[id];

  @override
  Future<Map<RecordId, EncryptedEnvelope>> loadAll() async => {...records};

  @override
  Future<void> save(RecordId id, EncryptedEnvelope sealed) async =>
      records[id] = sealed;

  @override
  Future<Outbox> loadOutbox() async => outbox;

  @override
  Future<void> queue(SealedRow row) async => outbox = outbox.enqueue(row);

  @override
  Future<void> unqueue(Iterable<SealedRow> pushed) async =>
      outbox = outbox.acknowledge(pushed);

  @override
  Future<int> loadCursor(SyncStream stream) async => cursors[stream] ?? 0;

  @override
  Future<void> saveCursor(SyncStream stream, int cursor) async =>
      cursors[stream] = cursor;

  @override
  Future<int?> loadUnreadable(RecordId id) async => unreadable[id];

  @override
  Future<void> markUnreadable(RecordId id, int position) async {
    final known = unreadable[id];
    if (known == null || position < known) unreadable[id] = position;
  }
}

final class FakeClock implements Clock {
  FakeClock(this.current);

  DateTime current;

  @override
  DateTime now() => current;

  void advance([Duration by = const Duration(minutes: 1)]) =>
      current = current.add(by);
}

/// Where the vault header and its signed log live on the device.
final class FakeVaultStore implements VaultStore {
  VaultHeader? header;
  PasskeySlot? passkey;
  final settings = <String, EncryptedEnvelope>{};
  final membership = <MembershipRecord>[];
  final bundles = <KeyBundle>[];

  @override
  Future<VaultHeader?> loadHeader() async => header;

  @override
  Future<void> create(
    VaultHeader header, {
    required List<MembershipRecord> membership,
    required List<KeyBundle> bundles,
  }) async {
    this.header = header;
    this.membership.addAll(membership);
    this.bundles.addAll(bundles);
  }

  @override
  Future<List<MembershipRecord>> loadMembership() async => [...membership];

  @override
  Future<List<KeyBundle>> loadKeyBundles() async => [...bundles];

  @override
  Future<void> appendMembership(List<MembershipRecord> records) async {
    for (final record in records) {
      if (record.sequence == membership.length) membership.add(record);
    }
  }

  @override
  Future<void> appendKeyBundles(List<KeyBundle> bundles) async =>
      this.bundles.addAll(bundles);

  @override
  Future<PasskeySlot?> loadPasskey() async => passkey;

  @override
  Future<void> savePasskey(PasskeySlot slot) async {
    if (header == null) throw const NoVaultException();
    passkey = slot;
  }

  @override
  Future<void> removePasskey() async => passkey = null;

  @override
  Future<EncryptedEnvelope?> loadSetting(String name) async => settings[name];

  @override
  Future<void> saveSetting(String name, EncryptedEnvelope? sealed) async {
    if (sealed == null) {
      settings.remove(name);
    } else {
      settings[name] = sealed;
    }
  }
}
