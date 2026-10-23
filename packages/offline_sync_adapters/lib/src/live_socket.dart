import 'package:web_socket/web_socket.dart';

/// Opens a WebSocket to [url] offering [protocols]; fails unless the
/// server picks the first. Replaced on every platform that has sockets.
Future<WebSocket> connectLive(Uri url, List<String> protocols) =>
    throw UnsupportedError('no WebSocket on this platform');
