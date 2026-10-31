import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:identity_cryptography_adapters/identity_cryptography_adapters.dart';
import 'package:offline_sync/offline_sync.dart';
import 'package:offline_sync_adapters/offline_sync_adapters.dart';
import 'package:publishing/publishing.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:test/test.dart';

final class _Clock implements Clock {
  @override
  DateTime now() => DateTime.utc(2026, 10, 31, 12);
}

/// A site's key as the app makes it: a detached identity's signer.
final class _Key implements SiteKey {
  _Key(this.signer);

  final RequestSigner signer;

  @override
  Future<String> authorize(String method, String path, Uint8List body) =>
      signer.authorize(method, path, body);

  @override
  void adjustClock(DateTime server) => signer.adjustClock(server);

  @override
  void release() {}
}

void main() {
  late SodiumSumo sodium;
  late IdentityKeyPair identity;
  late _Key key;
  late List<http.Request> sent;
  final name = SiteName('quaderno');

  setUpAll(() async => sodium = await SodiumSumoInit.init());

  setUp(() {
    identity = SodiumIdentityService(sodium).generateIdentity();
    addTearDown(identity.dispose);
    key = _Key(
      RequestSigner(
        identities: SodiumIdentityService(sodium),
        hasher: SodiumContentHasher(sodium),
        device: identity,
        clock: _Clock(),
        random: Random.secure(),
      ),
    );
    sent = [];
  });

  SiteGateway sites(http.Response Function(http.Request request) answer) =>
      ModusServer(
        origin: Uri.parse('https://modus.example'),
        blake2b: blake2b256,
        client: MockClient((request) async {
          sent.add(request);
          if (request.url.path == '/api/info') {
            return http.Response(jsonEncode({'server': 't', 'pow': 4}), 200);
          }
          return answer(request);
        }),
        now: () => DateTime.utc(2026, 10, 31, 12),
      ).sites();

  Future<ContentDigest> digest(List<int> body) => (SodiumContentHasher(
    sodium,
  ).start()..add(Uint8List.fromList(body))).close();

  test(
    'a claim carries the settings and a proof of work on the name',
    () async {
      await sites((_) => http.Response('{"created":true}', 201))
          .claim(key, name, {'title': 'Quaderno'});
      final request = sent.last;
      expect(request.method, 'POST');
      expect(request.url.path, '/api/s/quaderno');
      final body = jsonDecode(request.body) as Map<String, Object?>;
      expect(body['settings'], {'title': 'Quaderno'});
      final pow = body['pow']! as Map;
      final message = [
        ...ascii.encode('modusnote.pow.v1'),
        3,
        name.value.length,
        ...ascii.encode(name.value),
        ...[24, 16, 8, 0].map((s) => ((pow['day'] as int) >> s) & 0xff),
        ...base64.decode(pow['nonce'] as String),
      ];
      final hash = blake2b256(Uint8List.fromList(message));
      expect(hash[0] >> 4, 0, reason: '4 leading zero bits');
      // Signed by the site's key, never the device's.
      final credential = RequestCredential.parse(
        request.headers['Authorization']!,
      )!;
      expect(credential.key, identity.publicIdentity.signingKey);
    },
  );

  test('a name someone else holds says so', () async {
    await expectLater(
      sites((_) => http.Response('{}', 409)).claim(key, name, {}),
      throwsA(isA<SiteNameTakenException>()),
    );
  });

  test('a file goes raw, signed on an empty body, with its type', () async {
    final bytes = Uint8List.fromList(utf8.encode('OggS-payload'));
    await sites((_) => http.Response('{}', 201)).putMedia(
      key,
      name,
      MediaId('AAAAAAAAAAAAAAAAAAAAAA'),
      MediaKind.ogg,
      bytes,
    );
    final request = sent.single;
    expect(request.method, 'PUT');
    expect(request.url.path, '/api/s/quaderno/m/AAAAAAAAAAAAAAAAAAAAAA');
    expect(request.url.query, 'type=ogg');
    expect(request.bodyBytes, bytes);
    final credential = RequestCredential.parse(
      request.headers['Authorization']!,
    )!;
    final signed = SignedRequest(
      method: 'PUT',
      path: '/api/s/quaderno/m/AAAAAAAAAAAAAAAAAAAAAA?type=ogg',
      millis: credential.millis,
      nonce: credential.nonce,
      body: await digest(const []),
    );
    SodiumIdentityService(sodium).verify(
      signed.signable,
      signature: credential.signature,
      signer: credential.key,
    );
  });

  test('pages and settings go as JSON to their paths', () async {
    final gateway = sites((_) => http.Response('{"created":false}', 200));
    await gateway.putPage(key, name, PageSlug('il-faro'), {'title': 'x'});
    await gateway.putSettings(key, name, {'title': 'y'});
    await gateway.deletePage(key, name, PageSlug('il-faro'));
    await gateway.deleteMedia(key, name, MediaId('AAAAAAAAAAAAAAAAAAAAAA'));
    await gateway.deleteSite(key, name);
    expect(sent.map((r) => '${r.method} ${r.url.path}'), [
      'PUT /api/s/quaderno/p/il-faro',
      'PUT /api/s/quaderno',
      'DELETE /api/s/quaderno/p/il-faro',
      'DELETE /api/s/quaderno/m/AAAAAAAAAAAAAAAAAAAAAA',
      'DELETE /api/s/quaderno',
    ]);
    expect(jsonDecode(sent.first.body), {'title': 'x'});
    expect(sent.first.headers['Content-Type'], startsWith('application/json'));
  });

  test('refusals mean what the server means', () async {
    Future<void> put(int status) =>
        sites((_) => http.Response('{}', status))
            .putPage(key, name, PageSlug('a'), {'title': 'x'});
    Matcher rejected(PublishingRejection reason) => throwsA(
      isA<PublishingRejectedException>().having(
        (e) => e.reason,
        'reason',
        reason,
      ),
    );
    await expectLater(put(413), rejected(PublishingRejection.limit));
    await expectLater(put(422), rejected(PublishingRejection.invalid));
    await expectLater(put(400), rejected(PublishingRejection.invalid));
    await expectLater(put(403), rejected(PublishingRejection.notOwner));
    await expectLater(put(404), rejected(PublishingRejection.notOwner));
    await expectLater(put(503), throwsA(isA<PublishingUnavailableException>()));
    await expectLater(put(429), throwsA(isA<PublishingUnavailableException>()));
  });

  test('a clock the server blames is corrected once', () async {
    var calls = 0;
    await sites((_) {
      calls++;
      return calls == 1
          ? http.Response(
              jsonEncode({'error': 'clock', 'now': 1793448000000}),
              401,
            )
          : http.Response('{}', 200);
    }).deletePage(key, name, PageSlug('a'));
    expect(calls, 2);
  });
}
