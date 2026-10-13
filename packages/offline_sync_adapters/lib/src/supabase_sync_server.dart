import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:collaboration_access_control/collaboration_access_control.dart';
import 'package:http/http.dart' as http;
import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:offline_sync/offline_sync.dart';

/// The server understood the request and refused it: an expired session, or
/// Row Level Security denying this account. Unlike being offline, retrying
/// will not help until the account's access changes.
final class SyncServerRejectedException implements Exception {
  const SyncServerRejectedException(this.status);

  final int status;

  @override
  String toString() => 'SyncServerRejectedException: HTTP $status';
}

/// [SyncServer] on Supabase's REST API (PostgREST), over `package:http` so
/// the same code runs on mobile and web.
///
/// Only opaque ids, epochs, positions and ciphertext cross the wire; the
/// tables, their append-only privileges and Row Level Security are in
/// `supabase/migrations`. Responses are checked as strictly as any other
/// input from the server.
///
/// It is also where two devices of the same account meet to link
/// ([DeviceLinkChannel]): `device_links` holds the two sealed messages for a
/// few minutes, readable only by the account that posted them.
final class SupabaseSyncServer implements SyncServer, DeviceLinkChannel {
  SupabaseSyncServer({
    required Uri projectUrl,
    required this._anonKey,
    required this._accessToken,
    http.Client? client,
    this._pageSize = 500,
    this._timeout = const Duration(seconds: 30),
  }) : _rest = projectUrl.resolve('/rest/v1/'),
       _client = client ?? http.Client();

  final Uri _rest;
  final String _anonKey;
  final Future<String> Function() _accessToken;
  final http.Client _client;
  final int _pageSize;
  final Duration _timeout;

  @override
  Future<void> push(WorkspaceId workspace, List<SealedRow> rows) =>
      _insert('sync_rows', [
        for (final row in rows)
          {
            'workspace_id': workspace.hex,
            'record_id': row.record.hex,
            'epoch': row.ciphertext.epoch.value,
            'ciphertext': _bytea(row.ciphertext.envelope.toBytes()),
          },
      ]);

  @override
  Future<List<PulledRow>> pull(WorkspaceId workspace, {required int after}) =>
      _pages(
        'sync_rows',
        'position,record_id,epoch,ciphertext',
        workspace,
        after,
        (json) => PulledRow(
          cursor: json['position'] as int,
          row: SealedRow(
            record: RecordId.parse(json['record_id'] as String),
            ciphertext: WorkspaceCiphertext(
              epoch: KeyEpoch(json['epoch'] as int),
              envelope: EncryptedEnvelope.parse(_fromBytea(json['ciphertext'])),
            ),
          ),
        ),
      );

  @override
  Future<List<(int, KeyBundle)>> keyBundles(
    WorkspaceId workspace, {
    required int after,
  }) => _pages(
    'key_bundles',
    'position,bundle',
    workspace,
    after,
    (json) =>
        (json['position'] as int, KeyBundle.parse(_fromBytea(json['bundle']))),
  );

  /// Contiguous from [from]: a gap means the server dropped a record, which
  /// the ledger would refuse anyway, so it is refused here first.
  @override
  Future<List<MembershipRecord>> membership(
    WorkspaceId workspace, {
    required int from,
  }) async {
    final rows = await _select('membership_records', {
      'select': 'sequence,record',
      'workspace_id': 'eq.${workspace.hex}',
      'sequence': 'gte.$from',
      'order': 'sequence.asc',
    });
    final records = <MembershipRecord>[];
    for (final (index, json) in rows.indexed) {
      if (json['sequence'] != from + index) {
        throw const MalformedSyncDataException('membership sequence gap');
      }
      try {
        records.add(MembershipRecord.parse(_fromBytea(json['record'])));
      } on CollaborationException {
        throw const MalformedSyncDataException('malformed membership record');
      }
    }
    return records;
  }

  /// A workspace this account already registered (a publish cut short)
  /// answers 409, which is success here. One registered by another account
  /// answers the same, but then nothing after it is allowed by RLS, so the
  /// next append is refused.
  @override
  Future<void> createWorkspace(WorkspaceId workspace) async {
    try {
      await _insert('workspaces', [
        {'id': workspace.hex},
      ]);
    } on SyncServerRejectedException catch (error) {
      if (error.status != 409) rethrow;
    }
  }

  @override
  Future<void> appendMembership(MembershipRecord record) =>
      _insert('membership_records', [
        {
          'workspace_id': record.workspace.hex,
          'sequence': record.sequence,
          'record': _bytea(record.toBytes()),
        },
      ]);

  @override
  Future<void> appendKeyBundle(KeyBundle bundle) => _insert('key_bundles', [
    {'workspace_id': bundle.workspace.hex, 'bundle': _bytea(bundle.toBytes())},
  ]);

  @override
  Future<void> postOffer(LinkOffer offer) => _insert('device_links', [
    {
      'link_id': offer.id.hex,
      'kind': 'offer',
      'payload': _bytea(offer.toBytes()),
    },
  ]);

  @override
  Future<void> postAnswer(LinkAnswer answer) => _insert('device_links', [
    {
      'link_id': answer.id.hex,
      'kind': 'answer',
      'payload': _bytea(answer.toBytes()),
    },
  ]);

  /// Row Level Security already limits the rows to this account's recent
  /// ones; a payload that does not parse, or names another link than its
  /// row, is no offer at all.
  @override
  Future<LinkOffer?> latestOffer() async {
    final rows = await _select('device_links', {
      'select': 'link_id,payload',
      'kind': 'eq.offer',
      'order': 'id.desc',
      'limit': '1',
    });
    if (rows.isEmpty) return null;
    final offer = _link(rows.single, LinkOffer.parse);
    return offer != null && offer.id.hex == rows.single['link_id']
        ? offer
        : null;
  }

  @override
  Future<List<LinkAnswer>> answers(LinkId link) async {
    final rows = await _select('device_links', {
      'select': 'link_id,payload',
      'link_id': 'eq.${link.hex}',
      'kind': 'eq.answer',
      'order': 'id.asc',
      'limit': '$_maxAnswers',
    });
    return [
      for (final row in rows)
        if (_link(row, LinkAnswer.parse) case final answer?
            when answer.id == link)
          answer,
    ];
  }

  @override
  Future<void> close(LinkId link) => _send(
    http.Request(
      'DELETE',
      _rest
          .resolve('device_links')
          .replace(queryParameters: {'link_id': 'eq.${link.hex}'}),
    ),
  );

  /// More answers than a person could have typed are not read.
  static const _maxAnswers = 20;

  static T? _link<T>(Map<String, Object?> row, T Function(List<int>) parse) {
    try {
      return parse(_fromBytea(row['payload']));
    } on SyncException {
      return null;
    }
  }

  /// Lets another Supabase account read and append (managers only, by RLS).
  Future<void> addAccount(
    WorkspaceId workspace,
    String userId, {
    bool canManage = false,
  }) => _insert('workspace_accounts', [
    {'workspace_id': workspace.hex, 'user_id': userId, 'can_manage': canManage},
  ]);

  /// Paged select of an append-only stream. Positions must be strictly
  /// increasing and past [after]; an entry that fails to parse is dropped,
  /// since it cannot be anything the clients wrote.
  Future<List<T>> _pages<T>(
    String table,
    String columns,
    WorkspaceId workspace,
    int after,
    T Function(Map<String, Object?>) parse,
  ) async {
    final results = <T>[];
    var cursor = after;
    while (true) {
      final rows = await _select(table, {
        'select': columns,
        'workspace_id': 'eq.${workspace.hex}',
        'position': 'gt.$cursor',
        'order': 'position.asc',
        'limit': '$_pageSize',
      });
      for (final json in rows) {
        final position = json['position'];
        if (position is! int || position <= cursor) {
          throw const MalformedSyncDataException('positions out of order');
        }
        cursor = position;
        try {
          results.add(parse(json));
        } on Object catch (error) {
          if (error is! TypeError &&
              error is! SyncException &&
              error is! CollaborationException &&
              error is! CryptographyException) {
            rethrow;
          }
        }
      }
      if (rows.length < _pageSize) return results;
    }
  }

  Future<List<Map<String, Object?>>> _select(
    String table,
    Map<String, String> query,
  ) async {
    final response = await _send(
      http.Request('GET', _rest.resolve(table).replace(queryParameters: query)),
    );
    final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      throw const MalformedSyncDataException('response is not JSON');
    }
    if (decoded is! List ||
        decoded.any((row) => row is! Map<String, Object?>)) {
      throw const MalformedSyncDataException('response is not a row list');
    }
    return decoded.cast<Map<String, Object?>>();
  }

  Future<void> _insert(String table, List<Map<String, Object?>> rows) async {
    if (rows.isEmpty) return;
    await _send(
      http.Request('POST', _rest.resolve(table))
        ..headers['Content-Type'] = 'application/json'
        ..headers['Prefer'] = 'return=minimal'
        ..body = jsonEncode(rows),
    );
  }

  Future<http.Response> _send(http.Request request) async {
    request.headers
      ..['apikey'] = _anonKey
      ..['Authorization'] = 'Bearer ${await _accessToken()}';
    final http.Response response;
    try {
      response = await http.Response.fromStream(
        await _client.send(request).timeout(_timeout),
      ).timeout(_timeout);
    } on http.ClientException {
      throw const ServerUnavailableException();
    } on TimeoutException {
      throw const ServerUnavailableException();
    }
    final status = response.statusCode;
    if (status >= 200 && status < 300) return response;
    if (status >= 500 || status == 408 || status == 429) {
      throw const ServerUnavailableException();
    }
    throw SyncServerRejectedException(status);
  }

  static String _bytea(Uint8List bytes) =>
      '\\x${bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';

  static final _hexBytea = RegExp(r'^\\x([0-9a-f]{2})*$');

  static Uint8List _fromBytea(Object? value) {
    if (value is! String || !_hexBytea.hasMatch(value)) {
      throw const MalformedSyncDataException('malformed bytea');
    }
    return Uint8List.fromList([
      for (var i = 2; i < value.length; i += 2)
        int.parse(value.substring(i, i + 2), radix: 16),
    ]);
  }
}
