import 'dart:convert';

import 'package:collaboration_access_control/collaboration_access_control.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:offline_sync/offline_sync.dart';
import 'package:offline_sync_adapters/offline_sync_adapters.dart';

/// The token Supabase Auth hands out in these tests: it must never reach
/// the database file unsealed.
const issuedToken = 'access-token-7f3a9c';
const goodCode = '123456';

/// The token hash in [goodLink], which also signs in: the link a default
/// Supabase email carries in place of the code.
/// The account [goodLink] was sent to.
const linkEmail = 'pietro@example.com';

const goodLinkHash = '9d3a5f0b7c1e2d4f6a8b0c2e4f6a8b0c2e4f6a8b0c2e4f6a8b0c2e4f';
const goodLink =
    'https://project.supabase.co/auth/v1/verify?token=$goodLinkHash'
    '&type=magiclink&redirect_to=http://localhost:3000';

/// Supabase Auth over a fake HTTP client: any address gets a code, only
/// [goodCode] signs in.
final class FakeAuthServer {
  final requests = <String>[];

  /// Answers every request with this status instead.
  int? failWith;

  late final client = MockClient((request) async {
    requests.add(request.url.path);
    if (failWith case final status?) return http.Response('', status);
    final body = request.body.isEmpty
        ? const <String, Object?>{}
        : jsonDecode(request.body) as Map<String, Object?>;
    return switch (request.url.path) {
      '/auth/v1/otp' => http.Response('{}', 200),
      '/auth/v1/verify'
          when body['token'] == goodCode ||
              body['token_hash'] == goodLinkHash =>
        http.Response(
          jsonEncode({
            'access_token': issuedToken,
            'refresh_token': 'refresh-token-2b8e',
            'expires_in': 3600,
            // A link carries no email: the server knows whose it is.
            'user': {'id': 'user-1', 'email': body['email'] ?? linkEmail},
          }),
          200,
        ),
      '/auth/v1/verify' => http.Response('{}', 403),
      '/auth/v1/logout' => http.Response('', 204),
      _ => http.Response('', 404),
    };
  });

  SyncAccount account() => SyncAccount(
    SupabaseAuth(
      projectUrl: Uri.parse('https://project.supabase.co'),
      anonKey: 'publishable-key',
      client: client,
    ),
  );
}

/// The zero-knowledge server in memory, shared by every device of a test.
/// Each call first asks for the account's token, as PostgREST would, so a
/// signed-out device sees it as unreachable. Like Supabase, it also relays
/// device links (one account in these tests).
final class MemorySyncServer implements SyncServer, DeviceLinkChannel {
  MemorySyncServer(this.token);

  final Future<String> Function() token;
  var online = true;

  /// Fails every call as if the server refused the account.
  int? refuseWith;

  final workspaces = <WorkspaceId>{};
  final rows = <SealedRow>[];
  final membershipLog = <MembershipRecord>[];
  final bundles = <KeyBundle>[];
  final offers = <LinkOffer>[];
  final answered = <LinkAnswer>[];

  Future<void> _check() async {
    if (!online) throw const ServerUnavailableException();
    await token();
    if (refuseWith case final status?) {
      throw SyncServerRejectedException(status);
    }
  }

  @override
  Future<void> createWorkspace(WorkspaceId workspace) async {
    await _check();
    workspaces.add(workspace);
  }

  @override
  Future<void> appendMembership(MembershipRecord record) async {
    await _check();
    if (record.sequence != membershipLog.length) {
      throw const SyncServerRejectedException(409);
    }
    membershipLog.add(record);
  }

  @override
  Future<void> push(WorkspaceId workspace, List<SealedRow> rows) async {
    await _check();
    this.rows.addAll(rows);
  }

  @override
  Future<List<PulledRow>> pull(
    WorkspaceId workspace, {
    required int after,
  }) async {
    await _check();
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
    await _check();
    return from >= membershipLog.length
        ? const []
        : membershipLog.sublist(from);
  }

  @override
  Future<List<(int, KeyBundle)>> keyBundles(
    WorkspaceId workspace, {
    required int after,
  }) async {
    await _check();
    return [for (var i = after; i < bundles.length; i++) (i + 1, bundles[i])];
  }

  @override
  Future<void> appendKeyBundle(KeyBundle bundle) async {
    await _check();
    bundles.add(bundle);
  }

  @override
  Future<void> postOffer(LinkOffer offer) async {
    await _check();
    offers.add(offer);
  }

  @override
  Future<LinkOffer?> latestOffer() async {
    await _check();
    return offers.lastOrNull;
  }

  @override
  Future<void> postAnswer(LinkAnswer answer) async {
    await _check();
    answered.add(answer);
  }

  @override
  Future<List<LinkAnswer>> answers(LinkId link) async {
    await _check();
    return [...answered.where((answer) => answer.id == link)];
  }

  @override
  Future<void> close(LinkId link) async {
    await _check();
    offers.removeWhere((offer) => offer.id == link);
    answered.removeWhere((answer) => answer.id == link);
  }
}
