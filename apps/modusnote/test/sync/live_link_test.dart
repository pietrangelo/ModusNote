import 'dart:async';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:modusnote/sync/live_link.dart';
import 'package:offline_sync/offline_sync.dart';

/// A live channel in memory: every connection is a stream the test drives.
final class FakeLiveChannel {
  final connections = <StreamController<LiveSignal>>[];

  /// The connections the link cancelled (closed from its side).
  var cancelled = 0;

  Stream<LiveSignal> connect() {
    final connection = StreamController<LiveSignal>(
      onCancel: () => cancelled++,
    );
    connections.add(connection);
    return connection.stream;
  }

  StreamController<LiveSignal> get last => connections.last;

  void open() => last.add(const LiveOpened());

  void changed() => last.add(const LiveChanged());

  Future<void> close([int? code]) async {
    final connection = last;
    connection.add(LiveClosed(code));
    await connection.close();
  }

  /// A handshake that never opened.
  Future<void> refuse() async {
    final connection = last;
    connection.addError(const ServerUnavailableException());
    await connection.close();
  }
}

/// Always the same draw, so the waits are known.
final class _Fixed implements Random {
  const _Fixed(this.value);

  final double value;

  @override
  double nextDouble() => value;

  @override
  int nextInt(int max) => (value * max).floor();

  @override
  bool nextBool() => value >= 0.5;
}

const timings = LiveTimings(
  throttle: Duration(milliseconds: 80),
  settled: Duration(milliseconds: 150),
  firstRetry: Duration(milliseconds: 10),
  firstRetryLimit: Duration(milliseconds: 30),
  longestRetry: Duration(milliseconds: 120),
);

Future<void> wait(int milliseconds) =>
    Future<void>.delayed(Duration(milliseconds: milliseconds));

void main() {
  late FakeLiveChannel channel;
  late int syncs;

  LiveLink link({Random random = const _Fixed(0)}) {
    final link = LiveLink(
      connect: channel.connect,
      sync: () async => syncs++,
      timings: timings,
      random: random,
    );
    addTearDown(link.dispose);
    return link;
  }

  setUp(() {
    channel = FakeLiveChannel();
    syncs = 0;
  });

  test('opens only once started, and says when it is open', () async {
    final live = link();
    await wait(5);
    expect(channel.connections, isEmpty);

    live.start();
    live.start();
    expect(channel.connections, hasLength(1));
    expect(live.isOpen, isFalse);

    channel.open();
    await wait(5);
    expect(live.isOpen, isTrue);
  });

  test('a change syncs at once, and a burst only once more at the end '
      'of the window', () async {
    link().start();
    channel.open();
    await wait(100);
    expect(syncs, 1, reason: 'the opening');

    channel.changed();
    await wait(5);
    expect(syncs, 2);

    for (var i = 0; i < 10; i++) {
      channel.changed();
    }
    await wait(20);
    expect(syncs, 2, reason: 'the window is not over');

    await wait(100);
    expect(syncs, 3);

    await wait(100);
    expect(syncs, 3, reason: 'nothing came meanwhile');
  });

  test('every opening syncs, however recent the last sync', () async {
    // A change can land after the vault's last read of the server and
    // before the server took the channel: nothing would say it.
    link().start();
    channel.open();
    await wait(5);
    expect(syncs, 1);

    await channel.close();
    await wait(40);
    expect(channel.connections, hasLength(2));
    channel.open();
    await wait(5);
    expect(syncs, 2, reason: 'what came while it was closed');
  });

  test('a dropped channel comes back after a short random wait, then '
      'waits longer each time', () async {
    link(random: const _Fixed(1)).start();
    channel.open();
    await wait(5);

    await channel.close();
    await wait(20);
    expect(channel.connections, hasLength(1), reason: 'waits 30 ms');
    await wait(20);
    expect(channel.connections, hasLength(2));

    channel.open();
    await channel.close();
    await wait(45);
    expect(channel.connections, hasLength(2), reason: 'waits 60 ms now');
    await wait(30);
    expect(channel.connections, hasLength(3));

    channel.open();
    await channel.close(1001);
    await wait(100);
    expect(channel.connections, hasLength(3), reason: 'never over 120 ms');
    await wait(40);
    expect(channel.connections, hasLength(4));
  });

  test('the wait starts over only after the channel stayed open', () async {
    link(random: const _Fixed(1)).start();
    channel.open();
    await channel.close();
    await wait(40);
    channel.open();
    await wait(170);
    await channel.close();

    await wait(40);
    expect(channel.connections, hasLength(3), reason: 'back to 30 ms');
  });

  test('a removed device or a deleted workspace syncs once and stays '
      'closed', () async {
    for (final code in [LiveClosed.removed, LiveClosed.deleted]) {
      channel = FakeLiveChannel();
      final live = link()..start();
      channel.open();
      await wait(5);
      syncs = 0;

      await channel.close(code);
      await wait(100);

      expect(syncs, 1, reason: 'the log tells the device in a signed record');
      expect(channel.connections, hasLength(1));
      live
        ..pause()
        ..resume();
      expect(channel.connections, hasLength(1), reason: 'not even on return');
    }
  });

  test('another tab that took its place keeps it closed', () async {
    final live = link()..start();
    channel.open();
    await wait(5);
    syncs = 0;
    await channel.close(LiveClosed.evicted);
    await wait(100);

    expect(syncs, 0);
    expect(channel.connections, hasLength(1));
    live
      ..pause()
      ..resume();
    expect(channel.connections, hasLength(1), reason: 'not even on return');
  });

  test('three handshakes in a row refused while the server is reachable '
      'give up, until the app returns from the background', () async {
    final live = link()
      ..reached()
      ..start();
    for (var i = 0; i < LiveLink.maxUnopened; i++) {
      live.reached();
      await channel.refuse();
      await wait(100);
    }
    expect(channel.connections, hasLength(3));
    live.reached();
    await wait(200);
    expect(channel.connections, hasLength(3), reason: 'it gave up');

    live
      ..pause()
      ..resume();
    expect(channel.connections, hasLength(4), reason: 'it tries again');
  });

  test('handshakes that fail while the server cannot be reached do not '
      'count', () async {
    // A tunnel, a lift: the network is down, nothing refused the channel.
    final live = link()
      ..reached()
      ..start();
    for (var i = 0; i < 5; i++) {
      await channel.refuse();
      await wait(80);
    }
    expect(channel.connections, hasLength(6));

    live.reached();
    channel.open();
    await wait(5);
    expect(live.isOpen, isTrue);
  });

  test('a sync that reaches the server brings a waiting channel back at '
      'once', () async {
    final live = link(random: const _Fixed(1))..start();
    await channel.refuse();
    await wait(5);
    expect(channel.connections, hasLength(1), reason: 'waits 30 ms');

    live.reached();

    expect(channel.connections, hasLength(2));
  });

  test('opens that fail right after the return from the background do not '
      'add up', () async {
    // The radio may not be up yet when the app comes back.
    final live = link()
      ..reached()
      ..start();
    for (var i = 0; i < LiveLink.maxUnopened + 1; i++) {
      live
        ..pause()
        ..resume();
      await channel.refuse();
    }
    await wait(40);

    expect(channel.connections, hasLength(LiveLink.maxUnopened + 3));
  });

  test('an opened channel counts the failures from scratch', () async {
    final live = link(random: const _Fixed(1))
      ..reached()
      ..start();
    await channel.refuse();
    await wait(40);
    live.reached();
    await channel.refuse();
    await wait(100);
    channel.open();
    await channel.close();
    await wait(130);
    live.reached();
    await channel.refuse();
    await wait(130);

    expect(channel.connections, hasLength(5));
  });

  test('a channel ended by the locked vault stays closed', () async {
    link().start();
    await channel.last.close();
    await wait(100);

    expect(channel.connections, hasLength(1));
  });

  test('in the background it closes, and opens again on return', () async {
    final live = link();
    live.start();
    channel.open();
    await wait(5);

    live.pause();
    expect(channel.cancelled, 1);
    expect(live.isOpen, isFalse);
    await wait(100);
    expect(channel.connections, hasLength(1));

    live.resume();
    expect(channel.connections, hasLength(2));
  });

  test('a pause before the first sync opens nothing on return', () async {
    final live = link();
    live.pause();
    live.resume();

    expect(channel.connections, isEmpty);
  });

  test('disposed, it closes and never comes back', () async {
    final live = link();
    live.start();
    channel.open();
    await wait(5);
    channel.changed();
    channel.changed();
    await wait(5);

    live.dispose();
    expect(channel.cancelled, 1);
    await wait(150);
    expect(syncs, 1, reason: 'the pending sync is dropped');
    live
      ..pause()
      ..resume()
      ..reached()
      ..start();
    expect(channel.connections, hasLength(1));
  });
}
