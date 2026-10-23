import 'dart:io' as io;

import 'package:web_socket/io_web_socket.dart';
import 'package:web_socket/web_socket.dart';

/// Opens a WebSocket to [url] offering [protocols], on `dart:io`: at most
/// 15 s to reach the server, no compression. `dart:io` does not check the
/// protocol the server picked, so this does: anything but the first is a
/// protocol error (1002).
Future<WebSocket> connectLive(Uri url, List<String> protocols) async {
  final client = io.HttpClient()
    ..connectionTimeout = const Duration(seconds: 15);
  final io.WebSocket socket;
  try {
    socket = await io.WebSocket.connect(
      url.toString(),
      protocols: protocols,
      compression: io.CompressionOptions.compressionOff,
      customClient: client,
    );
  } finally {
    // The socket, once upgraded, no longer belongs to the client.
    client.close();
  }
  if (socket.protocol != protocols.first) {
    await socket.close(1002);
    throw WebSocketException('the server picked another protocol');
  }
  return IOWebSocket.fromWebSocket(socket);
}
