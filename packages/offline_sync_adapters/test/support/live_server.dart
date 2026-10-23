import 'dart:async';
import 'dart:io';

/// How the stand-in server answers the next upgrade.
enum LiveAnswer {
  /// 101 with `Sec-WebSocket-Protocol: modusnote.live.v1`, as the Worker.
  accept,

  /// 101 without picking a protocol.
  noProtocol,

  /// 101 picking the credential instead of the protocol.
  wrongProtocol,

  /// 404 `{"error":"workspace"}`, before any upgrade.
  refuse,

  /// Never answers.
  hang,
}

/// What a device sent to open a channel.
final class LiveHandshake {
  const LiveHandshake({
    required this.path,
    required this.query,
    required this.protocols,
    required this.authorization,
  });

  final String path;
  final String query;
  final List<String> protocols;
  final String? authorization;
}

/// One accepted socket, as the server sees it.
final class LiveSocket {
  LiveSocket(this.socket) {
    socket.listen(
      (message) => received.add(message),
      onDone: () => _closed.complete(socket.closeCode),
      onError: (Object _) {
        if (!_closed.isCompleted) _closed.complete(socket.closeCode);
      },
    );
  }

  final WebSocket socket;
  final received = <Object?>[];
  final _closed = Completer<int?>();

  /// The close code the device sent, once it closed.
  Future<int?> get closed => _closed.future;

  void send(Object message) => socket.add(message);

  Future<void> close(int code) => socket.close(code);
}

/// A stand-in for the Worker's live route, on `dart:io`: it records each
/// handshake and answers as [answer] says.
final class LiveServer {
  LiveServer._(this._server) {
    _server.listen(_handle);
  }

  static Future<LiveServer> start() async =>
      LiveServer._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  static const protocol = 'modusnote.live.v1';

  final HttpServer _server;
  final handshakes = <LiveHandshake>[];
  final _waiting = <Completer<LiveSocket>>[];
  final _accepted = <LiveSocket>[];
  final _hanging = <HttpRequest>[];
  var answer = LiveAnswer.accept;

  Uri get origin => Uri.parse('http://127.0.0.1:${_server.port}');

  /// The next socket the server accepts.
  Future<LiveSocket> next() {
    if (_accepted.isNotEmpty) return Future.value(_accepted.removeAt(0));
    final waiting = Completer<LiveSocket>();
    _waiting.add(waiting);
    return waiting.future;
  }

  Future<void> close() async {
    for (final request in _hanging) {
      unawaited(
        request.response.detachSocket().then((socket) => socket.destroy()),
      );
    }
    await _server.close(force: true);
  }

  Future<void> _handle(HttpRequest request) async {
    handshakes.add(
      LiveHandshake(
        path: request.uri.path,
        query: request.uri.query,
        protocols: [
          for (final value
              in request.headers['sec-websocket-protocol'] ?? const <String>[])
            for (final part in value.split(','))
              if (part.trim().isNotEmpty) part.trim(),
        ],
        authorization: request.headers.value('authorization'),
      ),
    );
    switch (answer) {
      case LiveAnswer.hang:
        _hanging.add(request);
        return;
      case LiveAnswer.refuse:
        request.response
          ..statusCode = 404
          ..write('{"error":"workspace"}');
        await request.response.close();
        return;
      case LiveAnswer.accept ||
          LiveAnswer.noProtocol ||
          LiveAnswer.wrongProtocol:
        final socket = LiveSocket(
          await WebSocketTransformer.upgrade(
            request,
            protocolSelector: switch (answer) {
              LiveAnswer.noProtocol => null,
              LiveAnswer.wrongProtocol => (
                List<String> offered,
              ) => offered.last,
              _ => (List<String> offered) => protocol,
            },
          ),
        );
        if (_waiting.isNotEmpty) {
          _waiting.removeAt(0).complete(socket);
        } else {
          _accepted.add(socket);
        }
    }
  }
}
