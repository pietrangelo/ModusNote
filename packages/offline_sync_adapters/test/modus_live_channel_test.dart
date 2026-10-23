@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:collaboration_access_control/collaboration_access_control.dart';
import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:identity_cryptography_adapters/identity_cryptography_adapters.dart';
import 'package:offline_sync/offline_sync.dart';
import 'package:offline_sync_adapters/offline_sync_adapters.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:test/test.dart';

import 'support/live_server.dart';

final class _Clock implements Clock {
  @override
  DateTime now() => DateTime.now().toUtc();
}

void main() {
  late SodiumSumo sodium;
  late IdentityKeyPair device;
  late RequestSigner signer;
  late LiveServer server;
  final workspace = WorkspaceId.parse('00112233445566778899aabbccddeeff');
  const heads = '{"rows":12,"bundles":3,"membership":4}';

  setUpAll(() async => sodium = await SodiumSumoInit.init());

  setUp(() async {
    device = SodiumIdentityService(sodium).generateIdentity();
    addTearDown(device.dispose);
    signer = RequestSigner(
      identities: SodiumIdentityService(sodium),
      hasher: SodiumContentHasher(sodium),
      device: device,
      clock: _Clock(),
      random: Random.secure(),
    );
    server = await LiveServer.start();
    addTearDown(server.close);
  });

  Stream<LiveSignal> open({
    Duration heartbeat = const Duration(seconds: 60),
    Duration silence = const Duration(seconds: 150),
    Duration connectTimeout = const Duration(seconds: 20),
    Uri? origin,
  }) => ModusLiveChannel(
    origin: origin ?? server.origin,
    heartbeat: heartbeat,
    silence: silence,
    connectTimeout: connectTimeout,
  ).open(workspace, signer);

  group('handshake', () {
    test('offers the protocol, then the signed credential, on the live '
        'route', () async {
      final signals = open();
      final opened = expectLater(signals, emits(const LiveOpened()));
      await server.next();
      await opened;

      final handshake = server.handshakes.single;
      expect(handshake.path, '/api/w/${workspace.hex}/live');
      expect(handshake.query, isEmpty);
      expect(handshake.authorization, isNull);
      expect(handshake.protocols, hasLength(2));
      expect(handshake.protocols.first, 'modusnote.live.v1');
      final token = handshake.protocols.last;
      expect(token, startsWith('mn1.'));

      // The same credential as the MN1 header, for a GET with no body.
      final credential = RequestCredential.parse(
        'MN1 ${token.substring('mn1.'.length)}',
      )!;
      expect(credential.key, signer.key);
      final empty = await (SodiumContentHasher(
        sodium,
      ).start()..add(Uint8List(0))).close();
      final signed = SignedRequest(
        method: 'GET',
        path: '/api/w/${workspace.hex}/live',
        millis: credential.millis,
        nonce: credential.nonce,
        body: empty,
      );
      SodiumIdentityService(sodium).verify(
        signed.signable,
        signature: credential.signature,
        signer: credential.key,
      );
    });

    test('an https origin opens a wss channel', () {
      expect(
        ModusLiveChannel.urlFor(Uri.parse('https://modus.serv.run'), workspace),
        Uri.parse('wss://modus.serv.run/api/w/${workspace.hex}/live'),
      );
      expect(
        ModusLiveChannel.urlFor(Uri.parse('http://localhost:8787'), workspace),
        Uri.parse('ws://localhost:8787/api/w/${workspace.hex}/live'),
      );
    });

    test('a server that does not pick the protocol is not trusted', () async {
      for (final answer in [LiveAnswer.noProtocol, LiveAnswer.wrongProtocol]) {
        server.answer = answer;
        final signals = open();
        final failed = expectLater(
          signals,
          emitsInOrder([
            emitsError(isA<ServerUnavailableException>()),
            emitsDone,
          ]),
        );
        final socket = await server.next();

        await failed;
        expect(await socket.closed, 1002, reason: '$answer');
      }
    });

    test('a refused handshake is the server being unavailable', () async {
      server.answer = LiveAnswer.refuse;

      await expectLater(
        open(),
        emitsInOrder([
          emitsError(isA<ServerUnavailableException>()),
          emitsDone,
        ]),
      );
    });

    test('a server that does not answer in time is given up', () async {
      server.answer = LiveAnswer.hang;
      final started = DateTime.now();

      await expectLater(
        open(connectTimeout: const Duration(milliseconds: 300)),
        emitsInOrder([
          emitsError(isA<ServerUnavailableException>()),
          emitsDone,
        ]),
      );
      expect(
        DateTime.now().difference(started),
        lessThan(const Duration(seconds: 5)),
      );
    });

    test('no server at all is the server being unavailable', () async {
      final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final origin = Uri.parse('http://127.0.0.1:${closed.port}');
      await closed.close();

      await expectLater(
        open(origin: origin),
        emitsInOrder([
          emitsError(isA<ServerUnavailableException>()),
          emitsDone,
        ]),
      );
    });

    test('a locked vault ends the stream without connecting', () async {
      device.dispose();

      await expectLater(open(), emitsDone);
      expect(server.handshakes, isEmpty);
    });
  });

  group('messages', () {
    test('new heads say something changed; pong says nothing', () async {
      final signals = open();
      final expectation = expectLater(
        signals,
        emitsInOrder([
          const LiveOpened(),
          const LiveChanged(),
          const LiveChanged(),
          const LiveClosed(LiveClosed.removed),
          emitsDone,
        ]),
      );
      final socket = await server.next();
      socket
        ..send(heads)
        ..send('pong')
        ..send('{"membership":0,"rows":0,"bundles":0}');
      await socket.close(LiveClosed.removed);

      await expectation;
    });

    test('the server\'s close codes reach the end of the stream', () async {
      for (final code in [
        LiveClosed.removed,
        LiveClosed.deleted,
        LiveClosed.evicted,
        LiveClosed.policy,
      ]) {
        final signals = open();
        final expectation = expectLater(
          signals,
          emitsInOrder([const LiveOpened(), LiveClosed(code), emitsDone]),
        );
        await (await server.next()).close(code);

        await expectation;
      }
    });

    test('anything else from the server closes the channel', () async {
      for (final message in <Object>[
        'x' * 257,
        '{"rows":1,"bundles":1,"membership":1,"padding":"${'x' * 220}"}',
        'not json',
        '[1,2,3]',
        '{"rows":1,"bundles":1}',
        '{"rows":1,"bundles":1,"membership":1,"more":1}',
        '{"rows":-1,"bundles":1,"membership":1}',
        '{"rows":1.5,"bundles":1,"membership":1}',
        '{"rows":"1","bundles":1,"membership":1}',
        'ping',
        [1, 2, 3],
      ]) {
        final signals = open();
        final expectation = expectLater(
          signals,
          emitsInOrder([const LiveOpened(), const LiveClosed(), emitsDone]),
        );
        final socket = await server.next();
        socket.send(message);

        await expectation;
        expect(
          await socket.closed,
          ModusLiveChannel.brokenProtocol,
          reason: '$message',
        );
      }
    });

    test('pings every heartbeat, and nothing else', () async {
      final signals = open(heartbeat: const Duration(milliseconds: 50));
      final subscription = signals.listen(null);
      addTearDown(subscription.cancel);
      final socket = await server.next();

      await Future<void>.delayed(const Duration(milliseconds: 180));

      expect(socket.received, isNotEmpty);
      expect(socket.received.toSet(), {'ping'});
    });

    test('a channel silent for too long is closed', () async {
      final signals = open(
        heartbeat: const Duration(seconds: 60),
        silence: const Duration(milliseconds: 200),
      );
      final expectation = expectLater(
        signals,
        emitsInOrder([const LiveOpened(), const LiveClosed(), emitsDone]),
      );
      final socket = await server.next();

      await expectation;
      expect(await socket.closed, 1000);
    });

    test('a message keeps a channel alive', () async {
      final signals = open(silence: const Duration(milliseconds: 300));
      final events = <LiveSignal>[];
      final subscription = signals.listen(events.add);
      addTearDown(subscription.cancel);
      final socket = await server.next();

      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 150));
        socket.send('pong');
      }

      expect(events, [const LiveOpened()]);
    });
  });

  group('closing', () {
    test('cancelling closes the socket normally', () async {
      final subscription = open().listen(null);
      final socket = await server.next();

      await subscription.cancel();

      expect(await socket.closed, 1000);
    });

    test('cancelling after the server closed is safe', () async {
      final signals = <LiveSignal>[];
      final subscription = open().listen(signals.add);
      final socket = await server.next();
      await socket.close(LiveClosed.deleted);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      await subscription.cancel();

      expect(signals, [const LiveOpened(), const LiveClosed(4404)]);
    });

    test('cancelling while connecting closes what connects', () async {
      final subscription = open().listen(null);
      final socket = server.next();
      while (server.handshakes.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }

      await subscription.cancel();

      expect(await (await socket).closed, 1000);
    });
  });
}
