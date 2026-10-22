import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:collaboration_access_control/collaboration_access_control.dart';
import 'package:http/http.dart' as http;
import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:meta/meta.dart';
import 'package:offline_sync/offline_sync.dart';

/// The server understood the request and refused it for good: a workspace
/// over its quota (413), a record or bundle the log does not allow (422),
/// a request it could not authenticate (401). Unlike being offline,
/// retrying will not help.
final class SyncServerRejectedException implements Exception {
  const SyncServerRejectedException(this.status);

  final int status;

  @override
  String toString() => 'SyncServerRejectedException: HTTP $status';
}

/// What `GET /api/info` says about the server.
@immutable
final class ServerInfo {
  const ServerInfo({required this.id, required this.powBits});

  /// Changes only with a new server, whose data starts empty: a device
  /// that sees another id publishes its vault again.
  final String id;

  /// How many leading zero bits founding a workspace or answering a code
  /// must prove.
  final int powBits;
}

/// [SyncGateway] on our Worker on Cloudflare Durable Objects (`server/`),
/// over `package:http` so the same code runs on mobile and web.
///
/// Every request about a workspace is signed by one device
/// ([RequestSigner]); the server admits it only for a member of the log it
/// verified. There is no account, session or token. Founding a workspace
/// and answering a code, the two requests anyone may make, cost a proof of
/// work instead ([proofOfWork]).
///
/// Only opaque ids, positions and ciphertext cross the wire. Responses are
/// checked as strictly as any other input from the server.
final class ModusServer implements SyncGateway {
  ModusServer({
    required Uri origin,
    required this._blake2b,
    http.Client? client,
    DateTime Function()? now,
    this._timeout = const Duration(seconds: 30),
  }) : _api = origin.resolve('/api/'),
       _client = client ?? http.Client(),
       _now = now ?? DateTime.now;

  final Uri _api;

  /// BLAKE2b-256, synchronous: the proof of work hashes about a million
  /// times.
  final Uint8List Function(Uint8List message) _blake2b;
  final http.Client _client;
  final DateTime Function() _now;
  final Duration _timeout;
  Future<ServerInfo>? _info;

  /// Rows per push, the server's own limit.
  static const maxRowsPerPush = 100;

  /// What a push may weigh as JSON, well under the server's 8 MiB.
  static const maxPushBytes = 6 << 20;

  @override
  SyncServer server(RequestSigner signer) => _DeviceServer(this, signer);

  @override
  InviteChannel invites(RequestSigner? signer) => _Codes(this, signer);

  /// What the server says about itself, asked once (and again after a
  /// failure).
  Future<ServerInfo> info() =>
      _info ??= _fetchInfo().catchError((Object error) {
        _info = null;
        throw error;
      });

  Future<ServerInfo> _fetchInfo() async {
    final json = await _json('GET', 'info');
    if (json case {'server': final String id, 'pow': final int bits}
        when id.isNotEmpty && bits >= 0 && bits <= 32) {
      return ServerInfo(id: id, powBits: bits);
    }
    throw const MalformedSyncDataException('malformed server info');
  }

  /// The proof of work for [purpose] (1 founds a workspace, 2 answers a
  /// code) on [target], as the server checks it: BLAKE2b-256 of
  /// `modusnote.pow.v1 | purpose | len | target | day | nonce` starting
  /// with `bits` zero bits, `day` being today in UTC. It hands the event
  /// loop back every few thousand hashes, so the screen keeps drawing.
  @visibleForTesting
  Future<Map<String, Object>> proofOfWork(int purpose, List<int> target) async {
    final bits = (await info()).powBits;
    final day = _now().millisecondsSinceEpoch ~/ Duration.millisecondsPerDay;
    final message = Uint8List.fromList([
      ...ascii.encode('modusnote.pow.v1'),
      purpose,
      target.length,
      ...target,
      (day >> 24) & 0xff,
      (day >> 16) & 0xff,
      (day >> 8) & 0xff,
      day & 0xff,
      ...Uint8List(16),
    ]);
    final nonceAt = message.length - 16;
    for (var counter = 0; ; counter++) {
      var rest = counter;
      for (var i = message.length - 1; i >= nonceAt; i--) {
        message[i] = rest & 0xff;
        rest >>= 8;
      }
      if (_leadingZeros(_blake2b(message)) >= bits) {
        return {
          'day': day,
          'nonce': base64.encode(Uint8List.sublistView(message, nonceAt)),
        };
      }
      if (counter % 4096 == 4095) await Future<void>.delayed(Duration.zero);
    }
  }

  static int _leadingZeros(Uint8List digest) {
    var bits = 0;
    for (final byte in digest) {
      if (byte != 0) return bits + 8 - byte.bitLength;
      bits += 8;
    }
    return bits;
  }

  /// Sends one request to `/api/<path>`: signed by [signer] when given,
  /// once more with the server's time when the device's clock is off. The
  /// decoded JSON answer, or null for an empty one.
  Future<Object?> _json(
    String method,
    String path, {
    RequestSigner? signer,
    Object? body,
    Map<int, Exception> meaning = const {},
  }) async {
    final bytes = body == null
        ? Uint8List(0)
        : Uint8List.fromList(utf8.encode(jsonEncode(body)));
    final target = _api.resolve(path);
    for (var attempt = 0; ; attempt++) {
      final request = http.Request(method, target)..bodyBytes = bytes;
      if (body != null) request.headers['Content-Type'] = 'application/json';
      if (signer != null) {
        request.headers['Authorization'] = await signer.authorize(
          method,
          target.hasQuery ? '${target.path}?${target.query}' : target.path,
          bytes,
        );
      }
      final (status, text) = await _send(request);
      if (status == 401 && signer != null && attempt == 0) {
        final now = _serverTime(text);
        if (now != null) {
          signer.adjustClock(now);
          continue;
        }
      }
      if (status >= 200 && status < 300) {
        if (text.isEmpty) return null;
        try {
          return jsonDecode(text);
        } on FormatException {
          throw const MalformedSyncDataException('malformed server answer');
        }
      }
      throw meaning[status] ?? _failure(status);
    }
  }

  /// The server's time from a 401 that blames the device's clock.
  static DateTime? _serverTime(String text) {
    try {
      if (jsonDecode(text) case {'error': 'clock', 'now': final int now}
          when now > 0) {
        return DateTime.fromMillisecondsSinceEpoch(now, isUtc: true);
      }
    } on FormatException {
      return null;
    }
    return null;
  }

  Future<(int, String)> _send(http.Request request) async {
    try {
      final response = await _client.send(request).timeout(_timeout);
      final text = await response.stream.bytesToString().timeout(_timeout);
      return (response.statusCode, text);
    } on http.ClientException {
      throw const ServerUnavailableException();
    } on TimeoutException {
      throw const ServerUnavailableException();
    } on FormatException {
      throw const MalformedSyncDataException('answer is not UTF-8');
    }
  }

  static Exception _failure(int status) => switch (status) {
    403 || 404 => const NotAdmittedException(),
    408 || 429 || >= 500 => const ServerUnavailableException(),
    _ => SyncServerRejectedException(status),
  };
}

/// The server as one device reaches it.
final class _DeviceServer implements SyncServer {
  _DeviceServer(this._server, this._signer);

  final ModusServer _server;
  final RequestSigner _signer;

  Future<Object?> _call(
    String method,
    String path, {
    Object? body,
    Map<int, Exception> meaning = const {},
  }) => _server._json(
    method,
    path,
    signer: _signer,
    body: body,
    meaning: meaning,
  );

  @override
  Future<void> createWorkspace(MembershipRecord genesis) async {
    final workspace = genesis.workspace;
    await _call(
      'POST',
      'w/${workspace.hex}',
      body: {
        'record': base64.encode(genesis.toBytes()),
        'pow': await _server.proofOfWork(1, workspace.bytes),
      },
      // Another first record holds the id.
      meaning: const {409: LedgerRollbackException()},
    );
  }

  @override
  Future<void> deleteWorkspace(WorkspaceId workspace) async {
    try {
      await _call('DELETE', 'w/${workspace.hex}');
    } on NotAdmittedException {
      // Already gone, or this device is no longer a member: either way the
      // server holds nothing more it would let this device delete.
    }
  }

  @override
  Future<void> appendMembership(MembershipRecord record) => _call(
    'POST',
    'w/${record.workspace.hex}/membership',
    body: {'record': base64.encode(record.toBytes())},
  );

  @override
  Future<void> appendKeyBundle(KeyBundle bundle) => _call(
    'POST',
    'w/${bundle.workspace.hex}/bundles',
    body: {'bundle': base64.encode(bundle.toBytes())},
  );

  @override
  Future<void> push(WorkspaceId workspace, List<SealedRow> rows) async {
    var batch = <Map<String, Object>>[];
    var weight = 0;
    Future<void> send() async {
      if (batch.isEmpty) return;
      final json = await _call(
        'POST',
        'w/${workspace.hex}/rows',
        body: {'rows': batch},
      );
      if (json case {'positions': final List<Object?> positions}
          when positions.length == batch.length) {
        batch = [];
        weight = 0;
        return;
      }
      throw const MalformedSyncDataException('malformed push answer');
    }

    for (final row in rows) {
      final entry = {
        'record': row.record.hex,
        'ciphertext': base64.encode(row.ciphertext.toBytes()),
        'supersedes': row.supersedes,
      };
      final size = (entry['ciphertext']! as String).length + 100;
      if (batch.length == ModusServer.maxRowsPerPush ||
          batch.isNotEmpty && weight + size > ModusServer.maxPushBytes) {
        await send();
      }
      batch.add(entry);
      weight += size;
    }
    await send();
  }

  @override
  Future<SyncHeads?> heads(WorkspaceId workspace) async {
    final json = await _call('GET', 'w/${workspace.hex}/heads');
    if (json case {
      'rows': final int rows,
      'bundles': final int bundles,
      'membership': final int membership,
    }) {
      return SyncHeads(rows: rows, keyBundles: bundles, membership: membership);
    }
    throw const MalformedSyncDataException('malformed heads');
  }

  /// Every page after [after]; positions must strictly grow, or the
  /// server is reordering what it hands out.
  @override
  Future<List<PulledRow>> pull(WorkspaceId workspace, {required int after}) =>
      _pages('w/${workspace.hex}/rows', 'rows', after, (json) {
        if (json case {
          'position': final int position,
          'record': final String record,
          'ciphertext': final String ciphertext,
        }) {
          return PulledRow(
            cursor: position,
            row: SealedRow(
              record: RecordId.parse(record),
              ciphertext: WorkspaceCiphertext.parse(base64.decode(ciphertext)),
            ),
          );
        }
        throw const MalformedSyncDataException('malformed row');
      }, (row) => row.cursor);

  @override
  Future<List<(int, KeyBundle)>> keyBundles(
    WorkspaceId workspace, {
    required int after,
  }) => _pages('w/${workspace.hex}/bundles', 'bundles', after, (json) {
    if (json case {
      'position': final int position,
      'bundle': final String bundle,
    }) {
      return (position, KeyBundle.parse(base64.decode(bundle)));
    }
    throw const MalformedSyncDataException('malformed bundle');
  }, (entry) => entry.$1);

  Future<List<T>> _pages<T>(
    String path,
    String field,
    int after,
    T Function(Object? json) parse,
    int Function(T) position,
  ) async {
    final all = <T>[];
    var cursor = after;
    while (true) {
      final json = await _call('GET', '$path?after=$cursor');
      if (json case {'more': final bool more}
          when json[field] is List<Object?>) {
        final page = json[field]! as List<Object?>;
        for (final entry in page) {
          final T item;
          try {
            item = parse(entry);
          } on CryptographyException {
            throw const MalformedSyncDataException('malformed ciphertext');
          } on CollaborationException {
            throw const MalformedSyncDataException('malformed entry');
          } on FormatException {
            throw const MalformedSyncDataException('malformed base64');
          }
          if (position(item) <= cursor) {
            throw const MalformedSyncDataException('positions not increasing');
          }
          cursor = position(item);
          all.add(item);
        }
        if (!more) return all;
        if (page.isEmpty) {
          throw const MalformedSyncDataException('empty page with more');
        }
        continue;
      }
      throw const MalformedSyncDataException('malformed page');
    }
  }

  /// Contiguous from [from]: a gap means the server dropped a record, which
  /// the ledger would refuse anyway, so it is refused here first.
  @override
  Future<List<MembershipRecord>> membership(
    WorkspaceId workspace, {
    required int from,
  }) async {
    final json = await _call('GET', 'w/${workspace.hex}/membership?from=$from');
    if (json case {'records': final List<Object?> listed}) {
      final records = <MembershipRecord>[];
      for (final (index, entry) in listed.indexed) {
        final MembershipRecord record;
        try {
          record = MembershipRecord.parse(base64.decode(entry! as String));
        } on Object {
          throw const MalformedSyncDataException('malformed record');
        }
        if (record.sequence != from + index || record.workspace != workspace) {
          throw const MalformedSyncDataException('membership sequence gap');
        }
        records.add(record);
      }
      return records;
    }
    throw const MalformedSyncDataException('malformed membership');
  }
}

/// Where codes meet: reading an offer and answering it are open to anyone
/// (an answer costs a proof of work); posting, reading the answers and
/// closing are the owner's, signed.
final class _Codes implements InviteChannel {
  _Codes(this._server, this._signer);

  final ModusServer _server;
  final RequestSigner? _signer;

  RequestSigner get _owner =>
      _signer ?? (throw StateError('only an owner posts and reads answers'));

  static String _checked(String lookup) {
    if (InviteCode.tryParse('${lookup}0000000000')?.lookup != lookup) {
      throw const MalformedSyncDataException('not a lookup');
    }
    return lookup;
  }

  @override
  Future<void> postInvite(WorkspaceId workspace, InviteOffer offer) async {
    await _server._json(
      'POST',
      'w/${workspace.hex}/codes/${_checked(offer.lookup)}',
      signer: _owner,
      body: {'offer': base64.encode(offer.toBytes())},
      meaning: const {409: LookupTakenException()},
    );
  }

  @override
  Future<InviteOffer?> invite(String lookup) async {
    final Object? json;
    try {
      json = await _server._json('GET', 'codes/${_checked(lookup)}');
    } on NotAdmittedException {
      return null;
    }
    if (json case {'offer': final String offer}) {
      try {
        final parsed = InviteOffer.parse(base64.decode(offer));
        return parsed.lookup == lookup ? parsed : null;
      } on MalformedSyncDataException {
        return null;
      } on FormatException {
        return null;
      }
    }
    throw const MalformedSyncDataException('malformed offer');
  }

  @override
  Future<void> postInviteAnswer(InviteAnswer answer) async {
    final lookup = _checked(answer.lookup);
    await _server._json(
      'POST',
      'codes/$lookup/answers',
      body: {
        'answer': base64.encode(answer.toBytes()),
        'pow': await _server.proofOfWork(2, ascii.encode(lookup)),
      },
      // The code was closed or expired meanwhile.
      meaning: const {404: LinkExpiredException()},
    );
  }

  @override
  Future<List<InviteAnswer>> inviteAnswers(String lookup) async {
    final json = await _server._json(
      'GET',
      'codes/${_checked(lookup)}/answers',
      signer: _owner,
      meaning: const {404: LinkExpiredException()},
    );
    if (json case {'answers': final List<Object?> answers}) {
      return [
        for (final answer in answers)
          if (answer is String) ?_answer(answer),
      ];
    }
    throw const MalformedSyncDataException('malformed answers');
  }

  /// One answer, or null for one that does not parse: anyone may post
  /// one, so a bad one must not hide the genuine.
  static InviteAnswer? _answer(String text) {
    try {
      return InviteAnswer.parse(base64.decode(text));
    } on MalformedSyncDataException {
      return null;
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> closeInvite(String lookup) async {
    try {
      await _server._json(
        'DELETE',
        'codes/${_checked(lookup)}',
        signer: _owner,
      );
    } on NotAdmittedException {
      // Expired already.
    }
  }
}
