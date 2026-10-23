import 'package:web_socket/browser_web_socket.dart';
import 'package:web_socket/web_socket.dart';

/// Opens a WebSocket to [url] offering [protocols], in the browser. The
/// browser fails a handshake whose protocol was not offered, but takes one
/// that picks none; this refuses that too.
Future<WebSocket> connectLive(Uri url, List<String> protocols) async {
  final socket = await BrowserWebSocket.connect(url, protocols: protocols);
  if (socket.protocol != protocols.first) {
    try {
      await socket.close();
    } on WebSocketConnectionClosed {
      // Closed before it opened: nothing to close.
    }
    throw WebSocketException('the server picked another protocol');
  }
  return socket;
}
