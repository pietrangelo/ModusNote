import 'dart:async';
import 'dart:math';

import 'package:offline_sync/offline_sync.dart';

/// How long [LiveLink] waits for what; tests shorten them.
final class LiveTimings {
  const LiveTimings({
    this.throttle = const Duration(seconds: 15),
    this.settled = const Duration(seconds: 60),
    this.firstRetry = const Duration(seconds: 1),
    this.firstRetryLimit = const Duration(seconds: 30),
    this.longestRetry = const Duration(minutes: 5),
  });

  /// At most one sync per this long comes from the channel's signals.
  final Duration throttle;

  /// How long a channel stays open before its retries start over.
  final Duration settled;

  /// The first wait after a close is drawn between these two, so a
  /// deploy that closes every channel does not bring them all back at once.
  final Duration firstRetry;
  final Duration firstRetryLimit;

  /// The waits double from there, with jitter, up to this.
  final Duration longestRetry;
}

/// The live channel of an open vault: the server says when another device
/// changed the workspace, and the vault syncs at once instead of at its
/// next check. Every signal is a hint: the sync signs and verifies as
/// always, and at most one sync per [LiveTimings.throttle] comes from
/// signals (one at once, one at the end of the window for those that came
/// meanwhile), however many a hostile member or server sends.
///
/// Opened by [start] once the vault synced; a channel that drops comes back
/// after a growing wait, or at once when a sync [reached] the server. A
/// device removed from the vault, a workspace deleted from the server or
/// another tab taking the channel keep it closed until the vault is
/// unlocked again; three handshakes in a row refused while the server
/// answered the vault's syncs (a browser that will not open `wss:`) keep
/// it closed until the app returns from the background. The periodic sync
/// goes on.
final class LiveLink {
  LiveLink({
    required this._connect,
    required this._sync,
    this._timings = const LiveTimings(),
    Random? random,
    DateTime Function()? clock,
  }) : _random = random ?? Random(),
       _clock = clock ?? DateTime.now;

  /// Opens a channel; cancelling the subscription closes it.
  final Stream<LiveSignal> Function() _connect;
  final Future<void> Function() _sync;
  final LiveTimings _timings;
  final Random _random;
  final DateTime Function() _clock;

  /// Handshakes in a row refused while the server was reachable before
  /// the link gives up.
  static const maxUnopened = 3;

  StreamSubscription<LiveSignal>? _channel;
  Timer? _retry;
  Timer? _trailing;
  DateTime? _openedAt;
  DateTime? _hinted;
  var _started = false;
  var _paused = false;
  var _stopped = false;

  /// Gave up after [maxUnopened] refused handshakes, until the return
  /// from the background.
  var _gaveUp = false;
  var _retries = 0;
  var _unopened = 0;

  /// A sync reached the server since the last handshake that failed: the
  /// network works, so the next failure was a refusal.
  var _reachable = false;

  /// Whether the server accepted the channel and it is still open.
  bool get isOpen => _openedAt != null;

  /// Opens the channel, once: after the vault's first sync.
  void start() {
    if (_started) return;
    _started = true;
    _open();
  }

  /// Closes the channel while the app is in the background.
  void pause() {
    _paused = true;
    _close();
  }

  /// Opens the channel again, back in the foreground, if it was open or
  /// only gave up on refused handshakes. The radio may not be up yet, so
  /// what fails now counts only after a sync reached the server.
  void resume() {
    if (!_paused) return;
    _paused = false;
    _gaveUp = false;
    _unopened = _retries = 0;
    _reachable = false;
    _open();
  }

  /// A sync reached the server: a handshake that fails from now on was
  /// refused, and a channel waiting to come back tries at once.
  void reached() {
    _reachable = true;
    if (_retry != null) _open();
  }

  /// Closes the channel until the vault is unlocked again.
  void stop() {
    _stopped = true;
    _close();
  }

  void dispose() => stop();

  void _open() {
    if (!_started || _paused || _stopped || _gaveUp || _channel != null) {
      return;
    }
    _retry?.cancel();
    _retry = null;
    int? closedWith;
    var closed = false;
    late final StreamSubscription<LiveSignal> channel;
    channel = _channel = _connect().listen(
      (signal) {
        switch (signal) {
          case LiveOpened():
            _opened();
          case LiveChanged():
            _changed();
          case LiveClosed(:final code):
            closed = true;
            closedWith = code;
        }
      },
      onError: (Object _) {
        if (_channel != channel) return;
        _channel = null;
        final opened = isOpen;
        _openedAt = null;
        opened ? _dropped(null) : _refused();
      },
      onDone: () {
        if (_channel != channel) return;
        _channel = null;
        final openedAt = _openedAt;
        _openedAt = null;
        // Ended without a word: the vault locked before it could sign.
        if (!closed) return;
        if (openedAt != null &&
            _clock().difference(openedAt) >= _timings.settled) {
          _retries = 0;
        }
        _dropped(closedWith);
      },
      cancelOnError: true,
    );
  }

  void _opened() {
    _openedAt = _clock();
    _unopened = 0;
    // What came while the channel was closed, however recent the last
    // sync: a change can land after it read the server and before the
    // server took the channel.
    _hint();
  }

  void _changed() {
    if (_trailing != null) return;
    final hinted = _hinted;
    final since = hinted == null ? null : _clock().difference(hinted);
    if (since == null || since >= _timings.throttle) return _hint();
    _trailing = Timer(_timings.throttle - since, () {
      _trailing = null;
      _hint();
    });
  }

  void _hint() {
    if (_stopped) return;
    _hinted = _clock();
    unawaited(_sync());
  }

  void _dropped(int? code) {
    switch (code) {
      case LiveClosed.removed || LiveClosed.deleted:
        // The next sync reads why, from the signed log or the server.
        _stopped = true;
        unawaited(_sync());
      case LiveClosed.evicted:
        _stopped = true;
      default:
        _later();
    }
  }

  /// A handshake that never opened. Unless a sync reached the server
  /// since the last one, the network was down: a tunnel, a lift, a radio
  /// not up yet. That says nothing about the channel.
  void _refused() {
    final refused = _reachable;
    _reachable = false;
    if (refused && ++_unopened >= maxUnopened) {
      _gaveUp = true;
      return;
    }
    _later();
  }

  void _later() {
    if (_stopped || _gaveUp || _paused) return;
    _retry = Timer(_wait(), _open);
  }

  /// A random wait between the first two bounds, then doubling with
  /// jitter up to the longest.
  Duration _wait() {
    final retry = _retries++;
    final first = _timings.firstRetry;
    final limit = _timings.firstRetryLimit;
    if (retry == 0) return first + (limit - first) * _random.nextDouble();
    final ceiling = limit * pow(2, min(retry, 20));
    final longest = ceiling < _timings.longestRetry
        ? ceiling
        : _timings.longestRetry;
    return longest * (0.5 + 0.5 * _random.nextDouble());
  }

  void _close() {
    _retry?.cancel();
    _retry = null;
    _trailing?.cancel();
    _trailing = null;
    _openedAt = null;
    final channel = _channel;
    _channel = null;
    unawaited(channel?.cancel());
  }
}
