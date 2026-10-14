import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:blob_storage_media/blob_storage_media.dart';
import 'package:http/http.dart' as http;
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

/// [RemoteBlobStore] on Cloudflare R2. The `blob-url` Edge Function checks
/// that the session's account belongs to the workspace and answers with a
/// URL for one object, valid for minutes; the bytes then go straight to R2.
/// Deleting and listing the function does itself, so R2 never gives a
/// client a URL that deletes.
///
/// The session token goes to Supabase only, never to R2, and no error
/// carries it or a presigned URL. Responses are untrusted: a URL that is
/// not HTTPS is refused, and a download is bounded by the caller
/// ([BlobReplication]) to the size the note announced.
final class R2RemoteBlobStore implements RemoteBlobStore {
  R2RemoteBlobStore({
    required Uri projectUrl,
    required this._anonKey,
    required String workspace,
    required this._accessToken,
    http.Client? client,
    this._timeout = const Duration(seconds: 30),
  }) : _function = projectUrl.resolve('/functions/v1/blob-url'),
       _workspace = _checkedWorkspace(workspace),
       _client = client ?? http.Client();

  final Uri _function;
  final String _anonKey;
  final String _workspace;
  final Future<String> Function() _accessToken;
  final http.Client _client;
  final Duration _timeout;

  static final _workspacePattern = RegExp(r'^[0-9a-f]{32}$');

  /// Ids per deletion call: the function's own limit.
  static const maxDeletions = 50;

  static String _checkedWorkspace(String workspace) {
    if (!_workspacePattern.hasMatch(workspace)) {
      throw ArgumentError.value(workspace, 'workspace', 'not a workspace id');
    }
    return workspace;
  }

  @override
  Future<void> upload(
    BlobId id,
    Stream<Uint8List> ciphertext, {
    required int length,
  }) async {
    final url = await _presign(id, 'PUT');
    final request = http.StreamedRequest('PUT', url)
      ..contentLength = length
      ..headers['Content-Type'] = 'application/octet-stream'
      // Signed into the URL: R2 only creates, never replaces.
      ..headers['If-None-Match'] = '*';
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
    await response.stream.drain<void>();
    final status = response.statusCode;
    // 412: the object exists. Blob ids are random and written once, so it
    // is this blob from an upload cut short after R2 stored it.
    if (status >= 200 && status < 300 || status == 412) return;
    throw _failure(status);
  }

  @override
  Stream<Uint8List> download(BlobId id) async* {
    final url = await _presign(id, 'GET');
    final response = await _send(http.Request('GET', url));
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
    for (var start = 0; start < ids.length; start += maxDeletions) {
      final end = start + maxDeletions < ids.length
          ? start + maxDeletions
          : ids.length;
      await _call({
        'workspace_id': _workspace,
        'method': 'DELETE',
        'blob_ids': [for (final id in ids.sublist(start, end)) id.value],
      });
    }
  }

  @override
  Future<StoredBlobPage> list({String? after}) async {
    final json = await _call({
      'workspace_id': _workspace,
      'method': 'LIST',
      'cursor': ?after,
    });
    if (json case {'blobs': final List<Object?> listed}) {
      final cursor = json['cursor'];
      if (cursor == null || cursor is String && cursor.isNotEmpty) {
        return StoredBlobPage([
          for (final entry in listed) ?_storedBlob(entry),
        ], next: cursor as String?);
      }
    }
    throw const MalformedBlobException('malformed blob listing');
  }

  static final _utcTimestamp = RegExp(
    r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?Z$',
  );

  /// One listed blob, or null for an entry that is not one: it is
  /// skipped, never deleted by mistake under another name.
  static StoredBlob? _storedBlob(Object? entry) {
    if (entry case {'id': final String id, 'stored_at': final String storedAt}
        when _utcTimestamp.hasMatch(storedAt)) {
      final time = DateTime.tryParse(storedAt);
      try {
        if (time != null) return StoredBlob(BlobId(id), storedAt: time);
      } on InvalidSchemaException {
        return null;
      }
    }
    return null;
  }

  Future<Uri> _presign(BlobId id, String method) async {
    final json = await _call({
      'workspace_id': _workspace,
      'blob_id': id.value,
      'method': method,
    });
    if (json case {'url': final String url}) {
      final uri = Uri.tryParse(url);
      if (uri != null &&
          uri.isScheme('https') &&
          uri.host.isNotEmpty &&
          uri.userInfo.isEmpty) {
        return uri;
      }
    }
    throw const MalformedBlobException('malformed presign response');
  }

  /// Asks the `blob-url` function with the session token; the decoded
  /// JSON answer.
  Future<Object?> _call(Map<String, Object> body) async {
    final String token;
    try {
      token = await _accessToken();
    } on Object {
      // Signed out or the session could not be renewed: try again later.
      throw const RemoteBlobUnavailableException();
    }
    final request = http.Request('POST', _function)
      ..headers['apikey'] = _anonKey
      ..headers['Authorization'] = 'Bearer $token'
      ..headers['Content-Type'] = 'application/json'
      ..body = jsonEncode(body);
    final response = await _send(request);
    final String text;
    try {
      text = await response.stream.bytesToString().timeout(_timeout);
    } on Object {
      throw const RemoteBlobUnavailableException();
    }
    final status = response.statusCode;
    if (status != 200) throw _failure(status);
    try {
      return jsonDecode(text);
    } on FormatException {
      throw const MalformedBlobException('malformed blob-url response');
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
