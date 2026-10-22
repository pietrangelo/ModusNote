import 'dart:math';
import 'dart:typed_data';

import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:identity_cryptography_adapters/identity_cryptography_adapters.dart';
import 'package:offline_sync/offline_sync.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:test/test.dart';

import 'fakes.dart';

void main() {
  late SodiumSumo sodium;
  late SodiumIdentityService identities;
  late IdentityKeyPair device;
  late FakeClock clock;
  late RequestSigner signer;
  const path = '/api/w/00112233445566778899aabbccddeeff/rows?after=3';

  setUpAll(() async => sodium = await SodiumSumoInit.init());

  setUp(() {
    identities = SodiumIdentityService(sodium);
    device = identities.generateIdentity();
    addTearDown(() {
      if (!device.isDisposed) device.dispose();
    });
    clock = FakeClock(DateTime.utc(2026, 10, 22, 12));
    signer = RequestSigner(
      identities: identities,
      hasher: SodiumContentHasher(sodium),
      device: device,
      clock: clock,
      random: Random.secure(),
    );
  });

  Future<ContentDigest> digestOf(List<int> body) async {
    final sink = SodiumContentHasher(sodium).start()
      ..add(Uint8List.fromList(body));
    return sink.close();
  }

  /// Checks [header] the way the server does.
  Future<RequestCredential> verified(
    String header,
    String method,
    String target,
    List<int> body,
  ) async {
    final credential = RequestCredential.parse(header)!;
    identities.verify(
      SignedRequest(
        method: method,
        path: target,
        millis: credential.millis,
        nonce: credential.nonce,
        body: await digestOf(body),
      ).signable,
      signature: credential.signature,
      signer: credential.key,
    );
    return credential;
  }

  test('signs as the device, over method, path, time and body', () async {
    final body = Uint8List.fromList([1, 2, 3]);

    final header = await signer.authorize('POST', path, body);
    final credential = await verified(header, 'POST', path, body);

    expect(credential.key, device.publicIdentity.signingKey);
    expect(signer.key, credential.key);
    expect(credential.millis, clock.now().millisecondsSinceEpoch);
  });

  test('another body, path or method does not verify', () async {
    final header = await signer.authorize('POST', path, Uint8List(1));

    for (final (method, target, body) in [
      ('POST', path, [1]),
      ('POST', '/api/w/00112233445566778899aabbccddeeff/rows?after=4', [0]),
      ('PUT', path, [0]),
    ]) {
      await expectLater(
        verified(header, method, target, body),
        throwsA(isA<InvalidSignatureException>()),
      );
    }
  });

  test('every request has a fresh nonce', () async {
    final nonces = {
      for (var i = 0; i < 20; i++)
        RequestCredential.parse(
          await signer.authorize('GET', path, Uint8List(0)),
        )!.nonce.join(','),
    };

    expect(nonces, hasLength(20));
  });

  test('after the server tells its time, requests carry it', () async {
    final server = clock.now().add(const Duration(minutes: 7));
    signer.adjustClock(server);
    clock.advance(const Duration(seconds: 30));

    final credential = RequestCredential.parse(
      await signer.authorize('GET', path, Uint8List(0)),
    )!;

    expect(
      credential.millis,
      server.add(const Duration(seconds: 30)).millisecondsSinceEpoch,
    );
  });

  test('a released identity signs nothing', () async {
    device.dispose();

    await expectLater(
      signer.authorize('GET', path, Uint8List(0)),
      throwsA(isA<VaultLockedException>()),
    );
  });
}
