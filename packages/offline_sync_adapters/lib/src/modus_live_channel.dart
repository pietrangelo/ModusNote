import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:collaboration_access_control/collaboration_access_control.dart';
import 'package:offline_sync/offline_sync.dart';
import 'package:web_socket/web_socket.dart';

import 'live_socket.dart'
    if (dart.library.io) 'live_socket_io.dart'
    if (dart.library.js_interop) 'live_socket_web.dart'
    as platform;

/// [LiveChannel] on our Worker: a WebSocket to `/api/w/<workspace>/live`
/// that the workspace's Durable Object keeps while it hibernates, over
/// `package:web_socket` so the same code runs on mobile and web.
///
/// A browser cannot put an `Authorization` header on a WebSocket, so the
/// device's signed credential (the `MN1` one, for `GET` on that path with
/// no body) travels as a subprotocol, `mn1.<key>.<ms>.<nonce>.<signature>`,
/// after `modusnote.live.v1`, the one the server must pick. A handshake
/// the server refuses says nothing about why (a browser reports no
/// status), so the app opens a channel only after a signed HTTP request
/// has set the clock.
///
/// The device only ever sends `ping`; the server answers `pong` without
/// waking up, and sends the workspace's heads after another device writes.
/// Nothing the server says is data: a message of any other shape, or
/// longer than [maxMessageBytes], closes the channel.
final class ModusLiveChannel implements LiveChannel {
  ModusLiveChannel({
    required this._origin,
    this.connectTimeout = const Duration(seconds: 20),
    this.heartbeat = const Duration(seconds: 60),
    this.silence = const Duration(seconds: 150),
  });

  final Uri _origin;

  /// How long connecting may take, signature to open socket.
  final Duration connectTimeout;

  /// How often the device says `ping`.
  final Duration heartbeat;

  /// How long a channel may stay silent (not even a `pong`) before the
  /// device gives it up.
  final Duration silence;

  /// The one protocol the server must pick.
  static const protocol = 'modusnote.live.v1';

  /// The longest message the server sends is three heads.
  static const maxMessageBytes = 256;

  /// The close code the device sends when the server breaks the protocol
  /// (a browser may not send 1008 itself).
  static const brokenProtocol = 4008;

  /// The channel's URL for [workspace] on [origin]: `wss` for `https`, `ws`
  /// for `http`.
  static Uri urlFor(Uri origin, WorkspaceId workspace) {
    final target = origin.resolve('/api/w/${workspace.hex}/live');
    return target.replace(
      scheme: switch (target.scheme) {
        'https' => 'wss',
        'http' => 'ws',
        _ => throw ArgumentError.value(origin, 'origin', 'not http or https'),
      },
    );
  }

  @override
  Stream<LiveSignal> open(WorkspaceId workspace, RequestSigner signer) {
    final out = StreamController<LiveSignal>();
    final session = _Session(this, urlFor(_origin, workspace), signer, out);
    out
      ..onListen = session.run
      ..onCancel = session.cancel;
    return out.stream;
  }
}

/// One channel, from signing to its end.
final class _Session {
  _Session(this._channel, this._url, this._signer, this._out);

  final ModusLiveChannel _channel;
  final Uri _url;
  final RequestSigner _signer;
  final StreamController<LiveSignal> _out;
  WebSocket? _socket;
  Timer? _heartbeat;
  Timer? _watchdog;

  /// Nothing more reaches the stream: it ended, or was cancelled.
  var _over = false;

  Future<void> run() async {
    final String header;
    try {
      header = await _signer.authorize('GET', _url.path, Uint8List(0));
    } on VaultLockedException {
      return _end();
    } catch (_) {
      return _unavailable();
    }
    if (_over) return;
    final WebSocket socket;
    try {
      socket = await _connect('mn1.${header.substring('MN1 '.length)}');
    } catch (_) {
      // Not only exceptions: a browser that will not create the socket
      // (a policy that blocks the URL) throws a DOMException, which is
      // none under dart2js or dart2wasm.
      return _unavailable();
    }
    if (_over) return _closeSocket(socket, 1000);
    _socket = socket;
    _out.add(const LiveOpened());
    _keepWatch();
    _heartbeat = Timer.periodic(_channel.heartbeat, (_) => _ping(socket));
    socket.events.listen(
      _receive,
      onError: (Object _) => _finish(),
      onDone: _finish,
    );
  }

  Future<void> cancel() async {
    if (_over) return;
    _over = true;
    _stopTimers();
    if (_socket case final socket?) await _closeSocket(socket, 1000);
  }

  /// Connects within the deadline; a socket that opens too late is closed
  /// at once.
  Future<WebSocket> _connect(String credential) {
    final connecting = platform.connectLive(_url, [
      ModusLiveChannel.protocol,
      credential,
    ]);
    return connecting.timeout(
      _channel.connectTimeout,
      onTimeout: () {
        unawaited(
          connecting.then(
            (late) => _closeSocket(late, 1000),
            onError: (Object _) {},
          ),
        );
        throw const ServerUnavailableException();
      },
    );
  }

  void _receive(WebSocketEvent event) {
    if (_over) return;
    switch (event) {
      case CloseReceived(:final code):
        _finish(code);
      case TextDataReceived(:final text) when text == 'pong':
        _keepWatch();
      case TextDataReceived(:final text) when _isHeads(text):
        _keepWatch();
        _out.add(const LiveChanged());
      case TextDataReceived() || BinaryDataReceived():
        final socket = _socket!;
        _finish();
        unawaited(_closeSocket(socket, ModusLiveChannel.brokenProtocol));
    }
  }

  /// `{"rows":R,"bundles":B,"membership":M}` and nothing else: the numbers
  /// are not used, only their shape is checked.
  static bool _isHeads(String text) {
    if (text.length > ModusLiveChannel.maxMessageBytes ||
        utf8.encode(text).length > ModusLiveChannel.maxMessageBytes) {
      return false;
    }
    final Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException {
      return false;
    }
    bool head(Object? value) => value is int && value >= 0;
    return json is Map<String, Object?> &&
        json.length == 3 &&
        head(json['rows']) &&
        head(json['bundles']) &&
        head(json['membership']);
  }

  void _ping(WebSocket socket) {
    try {
      socket.sendText('ping');
    } on WebSocketConnectionClosed {
      // The close is on its way to [_receive].
    }
  }

  /// Gives the channel up after [ModusLiveChannel.silence] without a word.
  void _keepWatch() {
    _watchdog?.cancel();
    _watchdog = Timer(_channel.silence, () {
      final socket = _socket!;
      _finish();
      unawaited(_closeSocket(socket, 1000));
    });
  }

  /// Ends an open channel with its close code: none for a network that
  /// dropped (1005 and 1006 are what platforms report then).
  void _finish([int? code]) {
    if (_over) return;
    _over = true;
    _stopTimers();
    _out.add(LiveClosed(code == 1005 || code == 1006 ? null : code));
    _close();
  }

  void _end() {
    _over = true;
    _close();
  }

  /// Ends a channel that never opened: whatever went wrong, for the app the
  /// server is out of reach.
  void _unavailable() {
    if (_over) return;
    _over = true;
    _out.addError(const ServerUnavailableException());
    _close();
  }

  void _close() => unawaited(_out.close());

  void _stopTimers() {
    _heartbeat?.cancel();
    _watchdog?.cancel();
  }

  static Future<void> _closeSocket(WebSocket socket, int code) async {
    try {
      await socket.close(code);
    } on WebSocketException {
      // Already closed, by the server or the network.
    }
  }
}
