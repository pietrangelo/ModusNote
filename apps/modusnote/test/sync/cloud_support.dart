import 'dart:typed_data';

import 'package:collaboration_access_control/collaboration_access_control.dart';
import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:offline_sync/offline_sync.dart';
import 'package:offline_sync_adapters/offline_sync_adapters.dart';

/// The zero-knowledge server in memory, shared by every device of a test.
/// Each device reaches it through [server], signing every request as the
/// real adapter does; like the Worker, it lets in only the members of the
/// log it holds (a removed member still reads the log), and relays codes.
final class MemorySyncServer implements SyncGateway {
  var online = true;

  /// Fails every call as if the server refused it.
  int? refuseWith;

  /// Every call waits for it first.
  Future<void>? hold;

  final workspaces = <WorkspaceId>{};
  final deleted = <WorkspaceId>{};
  final rows = <SealedRow>[];
  final membershipLog = <MembershipRecord>[];
  final bundles = <KeyBundle>[];
  final offers = <InviteOffer>[];
  final inviteAnswered = <InviteAnswer>[];
  final closed = <String>{};

  /// Every request the devices signed, as `METHOD path`.
  final signed = <String>[];

  var headsAsked = 0;

  @override
  SyncServer server(RequestSigner signer) => _DeviceServer(this, signer);

  @override
  InviteChannel invites(RequestSigner? signer) => _Codes(this, signer);

  Future<void> _check() async {
    if (hold case final hold?) await hold;
    if (!online) throw const ServerUnavailableException();
    if (refuseWith case final status?) {
      throw SyncServerRejectedException(status);
    }
  }

  Set<PublicSigningKey> get _members {
    final members = <PublicSigningKey>{};
    for (final record in membershipLog) {
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
    return members;
  }

  bool _wasMember(PublicSigningKey key) => membershipLog.any(
    (record) => switch (record.change) {
      WorkspaceFounded(:final founder) => founder.signingKey == key,
      MemberInvited(:final identity) => identity.signingKey == key,
      _ => false,
    },
  );
}

final class _DeviceServer implements SyncServer {
  _DeviceServer(this._backend, this._signer);

  final MemorySyncServer _backend;
  final RequestSigner _signer;

  /// Signs as the real adapter does, so a released identity fails here.
  Future<void> _sign(String method, String path) async {
    await _backend._check();
    await _signer.authorize(method, '/api/w/$path', Uint8List(0));
    _backend.signed.add('$method $path');
  }

  Future<void> _admitted(String method, String path) async {
    await _sign(method, path);
    if (!_backend._members.contains(_signer.key)) {
      throw const NotAdmittedException();
    }
  }

  @override
  Future<void> createWorkspace(MembershipRecord genesis) async {
    await _sign('POST', 'workspace');
    if (genesis.author.signingKey != _signer.key ||
        _backend.deleted.contains(genesis.workspace)) {
      throw const NotAdmittedException();
    }
    if (_backend.membershipLog.firstOrNull case final held?) {
      if (held != genesis) throw const LedgerRollbackException();
      return;
    }
    _backend.workspaces.add(genesis.workspace);
    _backend.membershipLog.add(genesis);
  }

  @override
  Future<void> deleteWorkspace(WorkspaceId workspace) async {
    await _admitted('DELETE', 'workspace');
    _backend
      ..workspaces.remove(workspace)
      ..deleted.add(workspace)
      ..rows.clear()
      ..membershipLog.clear()
      ..bundles.clear();
  }

  @override
  Future<void> appendMembership(MembershipRecord record) async {
    await _admitted('POST', 'membership');
    if (record.sequence != _backend.membershipLog.length) {
      throw const LedgerRollbackException();
    }
    _backend.membershipLog.add(record);
  }

  @override
  Future<void> push(WorkspaceId workspace, List<SealedRow> rows) async {
    await _admitted('POST', 'rows');
    _backend.rows.addAll(rows);
  }

  @override
  Future<SyncHeads?> heads(WorkspaceId workspace) async {
    _backend.headsAsked++;
    await _admitted('GET', 'heads');
    return SyncHeads(
      rows: _backend.rows.length,
      keyBundles: _backend.bundles.length,
      membership: _backend.membershipLog.length,
    );
  }

  @override
  Future<List<PulledRow>> pull(
    WorkspaceId workspace, {
    required int after,
  }) async {
    await _admitted('GET', 'rows');
    final rows = _backend.rows;
    return [
      for (var i = after; i < rows.length; i++)
        PulledRow(cursor: i + 1, row: rows[i]),
    ];
  }

  @override
  Future<List<MembershipRecord>> membership(
    WorkspaceId workspace, {
    required int from,
  }) async {
    await _sign('GET', 'membership');
    if (!_backend._wasMember(_signer.key)) throw const NotAdmittedException();
    final log = _backend.membershipLog;
    return from >= log.length ? const [] : log.sublist(from);
  }

  @override
  Future<List<(int, KeyBundle)>> keyBundles(
    WorkspaceId workspace, {
    required int after,
  }) async {
    await _admitted('GET', 'bundles');
    final bundles = _backend.bundles;
    return [for (var i = after; i < bundles.length; i++) (i + 1, bundles[i])];
  }

  @override
  Future<void> appendKeyBundle(KeyBundle bundle) async {
    await _admitted('POST', 'bundles');
    _backend.bundles.add(bundle);
  }
}

final class _Codes implements InviteChannel {
  _Codes(this._backend, this._signer);

  final MemorySyncServer _backend;
  final RequestSigner? _signer;

  RequestSigner get _owner =>
      _signer ?? (throw StateError('posting a code needs the owner'));

  @override
  Future<void> postInvite(WorkspaceId workspace, InviteOffer offer) async {
    await _backend._check();
    await _owner.authorize('POST', '/api/codes', Uint8List(0));
    final held = _backend.offers.any((held) => held.lookup == offer.lookup);
    if (held && !_backend.closed.contains(offer.lookup)) {
      throw const LookupTakenException();
    }
    _backend
      ..closed.remove(offer.lookup)
      ..offers.add(offer);
  }

  @override
  Future<InviteOffer?> invite(String lookup) async {
    await _backend._check();
    if (_backend.closed.contains(lookup)) return null;
    return _backend.offers.where((offer) => offer.lookup == lookup).lastOrNull;
  }

  @override
  Future<void> postInviteAnswer(InviteAnswer answer) async {
    await _backend._check();
    if (_backend.closed.contains(answer.lookup)) {
      throw const LinkExpiredException();
    }
    _backend.inviteAnswered.add(answer);
  }

  @override
  Future<List<InviteAnswer>> inviteAnswers(String lookup) async {
    await _backend._check();
    await _owner.authorize('GET', '/api/codes', Uint8List(0));
    return [
      ..._backend.inviteAnswered.where((answer) => answer.lookup == lookup),
    ];
  }

  @override
  Future<void> closeInvite(String lookup) async {
    await _backend._check();
    await _owner.authorize('DELETE', '/api/codes', Uint8List(0));
    _backend
      ..closed.add(lookup)
      ..inviteAnswered.removeWhere((answer) => answer.lookup == lookup);
  }
}
