import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:blob_storage_media/blob_storage_media.dart';
import 'package:http/http.dart' as http;
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

/// Signs one request as this device: the `Authorization` header for
/// [method] on [target] (path and query, exactly as sent) carrying [body].
typedef RequestAuthorizer = Future<String> Function(
  String method,
  String target,
  Uint8List body,
);

/// [RemoteBlobStore] on our Worker (`server/`): the workspace's object
/// checks that a member signed the request and counts the size, and the
/// Worker streams the bytes to and from R2. No URL, key or token for R2
/// ever reaches the device.
///
/// An upload is signed over the digest of an *empty* body: what the bytes
/// are is proved by the BLAKE2b digest written into the note, and the
/// Worker can then pass the body to R2 without holding it. A download is
/// untrusted and bounded by the caller ([BlobReplication]) to the size the
/// note announced.
final class ModusRemoteBlobStore implements RemoteBlobStore {
  ModusRemoteBlobStore({
    required Uri origin,
    required String workspace,
    required this._authorize,
    this._serverTime,
    http.Client? client,
    this._timeout = const Duration(seconds: 30),
  }) : _blobs = origin.resolve('/api/w/${_checked(workspace)}/blobs'),
       _client = client ?? http.Client();

  final Uri _blobs;
  final RequestAuthorizer _authorize;

  /// Told the server's time when it refuses the device's clock, so the
  /// next request is signed by it.
  final void Function(DateTime server)? _serverTime;
  final http.Client _client;
  final Duration _timeout;

  static final _workspacePattern = RegExp(r'^[0-9a-f]{32}$');

  /// Ids per deletion call: the server's own limit.
  static const maxDeletions = 50;

  static String _checked(String workspace) {
    if (!_workspacePattern.hasMatch(workspace)) {
      throw ArgumentError.value(workspace, 'workspace', 'not a workspace id');
    }
    return workspace;
  }

  Uri _blob(BlobId id) => _blobs.replace(path: '${_blobs.path}/${id.value}');

  static String _target(Uri uri) =>
      uri.hasQuery ? '${uri.path}?${uri.query}' : uri.path;

  @override
  Future<void> upload(
    BlobId id,
    Stream<Uint8List> ciphertext, {
    required int length,
  }) async {
    final url = _blob(id);
    final request = http.StreamedRequest('PUT', url)
      ..contentLength = length
      ..headers['Content-Type'] = 'application/octet-stream'
      ..headers['Authorization'] = await _authorize(
        'PUT',
        _target(url),
        Uint8List(0),
      );
    // The body is piped while the request is in flight; when the request
    // fails first, nobody waits on the pipe.
    final piped = () async {
      try {
        await request.sink.addStream(ciphertext);
      } finally {
        await request.sink.close();
      }
    }();
    final http.StreamedResponse response;
    try {
      response = await _send(request);
    } on Object {
      unawaited(piped.catchError((Object _) {}));
      rethrow;
    }
    await piped;
    final status = response.statusCode;
    final text = await _text(response);
    // 200: the server already holds this blob, from an upload cut short.
    if (status == 200 || status == 201) return;
    // The body is spent: the next sync uploads again, by the server's time.
    if (_learnTime(status, text)) throw const RemoteBlobUnavailableException();
    throw _failure(status);
  }

  @override
  Stream<Uint8List> download(BlobId id) async* {
    final response = await _signed('GET', _blob(id));
    final status = response.statusCode;
    if (status == 404) {
      await response.stream.drain<void>();
      throw BlobNotFoundException(id);
    }
    if (status != 200) {
      await response.stream.drain<void>();
      throw _failure(status);
    }
    try {
      await for (final piece in response.stream.timeout(_timeout)) {
        yield Uint8List.fromList(piece);
      }
    } on http.ClientException {
      throw const RemoteBlobUnavailableException();
    } on TimeoutException {
      throw const RemoteBlobUnavailableException();
    }
  }

  @override
  Future<void> delete(List<BlobId> ids) async {
    final url = _blobs.replace(path: '${_blobs.path}/delete');
    for (var start = 0; start < ids.length; start += maxDeletions) {
      final end = start + maxDeletions < ids.length
          ? start + maxDeletions
          : ids.length;
      await _json('POST', url, {
        'ids': [for (final id in ids.sublist(start, end)) id.value],
      });
    }
  }

  @override
  Future<StoredBlobPage> list({String? after}) async {
    if (after != null) BlobId(after);
    final url = after == null ? _blobs : _blobs.replace(query: 'after=$after');
    final json = await _json('GET', url, null);
    if (json case {
      'blobs': final List<Object?> listed,
      'more': final bool more,
    }) {
      final blobs = [for (final entry in listed) ?_storedBlob(entry)];
      final last = listed.lastOrNull;
      return StoredBlobPage(
        blobs,
        next: more && last is Map && last['id'] is String
            ? last['id']! as String
            : null,
      );
    }
    throw const MalformedBlobException('malformed blob listing');
  }

  /// One listed blob, or null for an entry that is not one: it is
  /// skipped, never deleted by mistake under another name.
  static StoredBlob? _storedBlob(Object? entry) {
    if (entry case {'id': final String id, 'uploaded': final int uploaded}
        when uploaded >= 0) {
      try {
        return StoredBlob(
          BlobId(id),
          storedAt: DateTime.fromMillisecondsSinceEpoch(uploaded, isUtc: true),
        );
      } on InvalidSchemaException {
        return null;
      }
    }
    return null;
  }

  /// A signed JSON call, signed again by the server's clock once if it
  /// refused the device's; the decoded answer.
  Future<Object?> _json(String method, Uri url, Object? body) async {
    final bytes = body == null
        ? Uint8List(0)
        : Uint8List.fromList(utf8.encode(jsonEncode(body)));
    for (var attempt = 0; ; attempt++) {
      final request = http.Request(method, url)..bodyBytes = bytes;
      if (body != null) request.headers['Content-Type'] = 'application/json';
      request.headers['Authorization'] = await _authorize(
        method,
        _target(url),
        bytes,
      );
      final response = await _send(request);
      final text = await _text(response);
      final status = response.statusCode;
      if (status == 200 || status == 201) {
        try {
          return text.isEmpty ? null : jsonDecode(text);
        } on FormatException {
          throw const MalformedBlobException('malformed server answer');
        }
      }
      if (attempt == 0 && _learnTime(status, text)) continue;
      throw _failure(status);
    }
  }

  /// A signed request without a body, signed again by the server's clock
  /// once if it refused the device's.
  Future<http.StreamedResponse> _signed(String method, Uri url) async {
    for (var attempt = 0; ; attempt++) {
      final request = http.Request(method, url)
        ..headers['Authorization'] = await _authorize(
          method,
          _target(url),
          Uint8List(0),
        );
      final response = await _send(request);
      if (response.statusCode != 401 || attempt > 0) return response;
      if (!_learnTime(401, await _text(response))) {
        throw const RemoteBlobRejectedException(401);
      }
    }
  }

  /// Whether [text] is the server's refusal of the device's clock; it
  /// passes the server's time on.
  bool _learnTime(int status, String text) {
    if (status != 401) return false;
    try {
      if (jsonDecode(text) case {'error': 'clock', 'now': final int now}
          when now > 0) {
        _serverTime?.call(
          DateTime.fromMillisecondsSinceEpoch(now, isUtc: true),
        );
        return true;
      }
    } on FormatException {
      return false;
    }
    return false;
  }

  Future<String> _text(http.StreamedResponse response) async {
    try {
      return await response.stream.bytesToString().timeout(_timeout);
    } on Object {
      throw const RemoteBlobUnavailableException();
    }
  }

  Future<http.StreamedResponse> _send(http.BaseRequest request) async {
    try {
      return await _client.send(request).timeout(_timeout);
    } on http.ClientException {
      throw const RemoteBlobUnavailableException();
    } on TimeoutException {
      throw const RemoteBlobUnavailableException();
    }
  }

  static BlobException _failure(int status) =>
      status >= 500 || status == 408 || status == 429
      ? const RemoteBlobUnavailableException()
      : RemoteBlobRejectedException(status);
}
