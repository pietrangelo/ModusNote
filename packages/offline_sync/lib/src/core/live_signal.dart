import 'package:meta/meta.dart';

/// What a live channel to the server says about one workspace. Every
/// signal is a hint, never data: the device still syncs as always, signing
/// each request, and trusts only what it verifies.
@immutable
sealed class LiveSignal {
  const LiveSignal();
}

/// The server accepted the channel: from now on it tells this device when
/// the workspace changes.
final class LiveOpened extends LiveSignal {
  const LiveOpened();

  @override
  bool operator ==(Object other) => other is LiveOpened;

  @override
  int get hashCode => (LiveOpened).hashCode;
}

/// Something in the workspace changed (rows, key bundles or the log), as
/// another device wrote it: time to sync.
final class LiveChanged extends LiveSignal {
  const LiveChanged();

  @override
  bool operator ==(Object other) => other is LiveChanged;

  @override
  int get hashCode => (LiveChanged).hashCode;
}

/// The channel closed after it had opened; the last signal. [code] is the
/// WebSocket close code, null when there was none (the network dropped,
/// or the device closed a channel that went silent or broke the rules).
final class LiveClosed extends LiveSignal {
  const LiveClosed([this.code]);

  /// This device's key is no longer a member: the log, read by the next
  /// sync, says so in a signed record.
  static const removed = 4403;

  /// The workspace was deleted from the server, or expired.
  static const deleted = 4404;

  /// The same key opened another channel (another tab of the same vault),
  /// which took this one's place.
  static const evicted = 4409;

  /// The server found this channel breaking the protocol.
  static const policy = 1008;

  final int? code;

  @override
  bool operator ==(Object other) => other is LiveClosed && other.code == code;

  @override
  int get hashCode => Object.hash(LiveClosed, code);

  @override
  String toString() => 'LiveClosed($code)';
}
