// The live channel in the browser, compiled both ways the web build ships
// (dart test -p chrome -c dart2js|dart2wasm test/web), against the
// stand-in server running on the VM.
@TestOn('browser')
library;

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:collaboration_access_control/collaboration_access_control.dart';
import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:offline_sync/offline_sync.dart';
import 'package:offline_sync_adapters/offline_sync_adapters.dart';
import 'package:test/test.dart';

/// Signing is not what these tests are about (the VM tests verify the
/// credential with libsodium); a fixed signature keeps libsodium.js out.
final class _Identities implements IdentityService {
  @override
  Signature sign(Uint8List message, {required IdentityKeyPair signer}) =>
      Signature.fromBytes(List.filled(Signature.length, 7));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Hasher implements ContentHasher, DigestSink {
  @override
  DigestSink start() => this;

  @override
  void add(Uint8List piece) {}

  @override
  Future<ContentDigest> close() async =>
      ContentDigest.fromBytes(Uint8List(ContentDigest.length));
}

final class _Device implements IdentityKeyPair {
  @override
  final publicIdentity = PublicIdentity(
    signingKey: PublicSigningKey.fromBytes(List.filled(32, 3)),
    encryptionKey: PublicEncryptionKey.fromBytes(
      List.filled(PublicEncryptionKey.length, 4),
    ),
  );

  @override
  bool isDisposed = false;

  @override
  void dispose() => isDisposed = true;
}

final class _Clock implements Clock {
  @override
  DateTime now() => DateTime.now();
}

void main() {
  final workspace = WorkspaceId.parse('00112233445566778899aabbccddeeff');
  late StreamSink<Object?> commands;
  late StreamIterator<Object?> replies;
  late Uri origin;

  final signer = RequestSigner(
    identities: _Identities(),
    hasher: _Hasher(),
    device: _Device(),
    clock: _Clock(),
    random: Random(1),
  );

  setUp(() async {
    final channel = spawnHybridUri('../support/live_hybrid.dart');
    commands = channel.sink;
    replies = StreamIterator(channel.stream);
    await replies.moveNext();
    origin = Uri.parse(replies.current! as String);
  });

  /// Tells the stand-in server to do something; what it answers.
  Future<Object?> server(Object command) async {
    commands.add(command);
    await replies.moveNext();
    return replies.current;
  }

  Stream<LiveSignal> open() =>
      ModusLiveChannel(origin: origin).open(workspace, signer);

  test('opens with the protocol and the credential, then says what '
      'changed until the server closes', () async {
    final signals = open();
    final expectation = expectLater(
      signals,
      emitsInOrder([
        const LiveOpened(),
        const LiveChanged(),
        const LiveClosed(LiveClosed.removed),
        emitsDone,
      ]),
    );
    await server('accept');
    await server({'send': 'pong'});
    await server({'send': '{"rows":5,"bundles":0,"membership":2}'});
    await server({'close': LiveClosed.removed});

    await expectation;
    final handshake = (await server('handshake'))! as Map<Object?, Object?>;
    expect(handshake['path'], '/api/w/${workspace.hex}/live');
    final protocols = handshake['protocols']! as List<Object?>;
    expect(protocols, hasLength(2));
    expect(protocols.first, 'modusnote.live.v1');
    expect(protocols.last, startsWith('mn1.'));
  });

  test('a server that picks no protocol is not trusted', () async {
    await server({'answer': 'noProtocol'});

    await expectLater(
      open(),
      emitsInOrder([emitsError(isA<ServerUnavailableException>()), emitsDone]),
    );
  });

  test('a refused handshake is the server being unavailable', () async {
    await server({'answer': 'refuse'});

    await expectLater(
      open(),
      emitsInOrder([emitsError(isA<ServerUnavailableException>()), emitsDone]),
    );
  });

  test('a message too long closes the channel', () async {
    final expectation = expectLater(
      open(),
      emitsInOrder([const LiveOpened(), const LiveClosed(), emitsDone]),
    );
    await server('accept');
    await server({'send': 'x' * 257});

    await expectation;
    expect(await server('closed'), ModusLiveChannel.brokenProtocol);
  });

  test('cancelling closes the socket normally', () async {
    final opened = Completer<void>();
    final subscription = open().listen((_) => opened.complete());
    await server('accept');
    await opened.future;

    await subscription.cancel();

    expect(await server('closed'), 1000);
  });
}
