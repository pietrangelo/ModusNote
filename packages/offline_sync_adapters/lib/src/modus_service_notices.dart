import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:offline_sync/offline_sync.dart';

/// [ServiceNoticeSource] on the app's own origin: `notices.json`, a static
/// file the Worker serves next to the app, read without a signature (it
/// says nothing about the device) over `package:http`, as [ModusServer].
///
/// The file is read as strictly as any answer from the server, and
/// anything wrong with it (offline, another status, too large, another
/// shape) is no notices. Whether a notice is genuine is the
/// [ServiceNoticeBoard]'s to decide.
final class ModusServiceNotices implements ServiceNoticeSource {
  ModusServiceNotices({
    required Uri origin,
    http.Client? client,
    this._timeout = const Duration(seconds: 30),
  }) : _url = origin.resolve('/notices.json'),
       _client = client ?? http.Client();

  final Uri _url;
  final http.Client _client;
  final Duration _timeout;

  static final _base64 = RegExp(
    r'^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$',
  );

  @override
  Future<List<Uint8List>> fetch() async {
    try {
      final text = await _read().timeout(_timeout);
      if (text == null) return const [];
      if (jsonDecode(text) case {'notices': final List<Object?> notices}
          when notices.length <= ServiceNoticeBoard.maxPublished &&
              notices.every((n) => n is String && _base64.hasMatch(n))) {
        return [for (final n in notices.cast<String>()) base64.decode(n)];
      }
      return const [];
    } on Exception {
      // ClientException, TimeoutException, FormatException, and what
      // `dart:io` lets through: a HandshakeException before the response,
      // a SocketException while the body streams.
      return const [];
    }
  }

  /// The file's text, or null for a status other than 200 or a body over
  /// [ServiceNoticeBoard.maxPublishedBytes], which is not read further.
  Future<String?> _read() async {
    final response = await _client.send(http.Request('GET', _url));
    const limit = ServiceNoticeBoard.maxPublishedBytes;
    if (response.statusCode != 200 || (response.contentLength ?? 0) > limit) {
      unawaited(response.stream.drain<void>().catchError((Object _) {}));
      return null;
    }
    final body = BytesBuilder(copy: false);
    await for (final piece in response.stream) {
      if (body.length + piece.length > limit) return null;
      body.add(piece);
    }
    return utf8.decode(body.takeBytes());
  }
}
