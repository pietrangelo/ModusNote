import 'dart:convert';
import 'dart:typed_data';

import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:offline_sync/offline_sync.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  final digest = ContentDigest.fromBytes(List.filled(32, 7));
  final nonce = Uint8List.fromList(List.generate(16, (i) => i));

  SignedRequest request({
    String method = 'POST',
    String path = '/api/w/00112233445566778899aabbccddeeff/rows',
    int millis = 1792700000000,
  }) => SignedRequest(
    method: method,
    path: path,
    millis: millis,
    nonce: nonce,
    body: digest,
  );

  group('what a device signs', () {
    test('label, method, path, time, nonce and body digest, in order', () {
      final signable = request().signable;
      final reader = ByteData.sublistView(signable);
      var offset = 0;
      Uint8List take(int n) =>
          Uint8List.sublistView(signable, offset, offset += n);

      expect(ascii.decode(take(20)), 'modusnote.request.v1');
      expect(ascii.decode(take(take(1).single)), 'POST');
      final pathLength = reader.getUint16(offset);
      offset += 2;
      expect(
        ascii.decode(take(pathLength)),
        '/api/w/00112233445566778899aabbccddeeff/rows',
      );
      expect(take(8), [0, 0, 0x01, 0xa1, 0x65, 0x3f, 0x27, 0x00]);
      expect(take(16), nonce);
      expect(take(32), digest.bytes);
      expect(offset, signable.length);
    });

    test('any field changed changes what is signed', () {
      final base = request().signable;

      for (final other in [
        request(method: 'GET'),
        request(path: '/api/w/00112233445566778899aabbccddeeff/rows?after=1'),
        request(millis: 1792700000001),
        SignedRequest(
          method: 'POST',
          path: '/api/w/00112233445566778899aabbccddeeff/rows',
          millis: 1792700000000,
          nonce: Uint8List(16),
          body: digest,
        ),
        SignedRequest(
          method: 'POST',
          path: '/api/w/00112233445566778899aabbccddeeff/rows',
          millis: 1792700000000,
          nonce: nonce,
          body: ContentDigest.fromBytes(List.filled(32, 8)),
        ),
      ]) {
        expect(other.signable, isNot(base));
      }
    });

    test('refuses what the server would never route', () {
      for (final build in <void Function()>[
        () => request(method: 'post'),
        () => request(method: ''),
        () => request(method: 'P' * 17),
        () => request(path: '/rows'),
        () => request(path: '/api/w x'),
        () => request(path: '/api/é'),
        () => request(path: '/api/${'a' * 2048}'),
        () => request(millis: -1),
        () => request(millis: 1 << 53),
        () => SignedRequest(
          method: 'GET',
          path: '/api/info',
          millis: 0,
          nonce: Uint8List(15),
          body: digest,
        ),
      ]) {
        expect(build, throwsA(isA<MalformedSyncDataException>()));
      }
    });
  });

  group('the Authorization header', () {
    final credential = RequestCredential(
      key: memberOf(3).signingKey,
      millis: 1792700000000,
      nonce: nonce,
      signature: signatureOf(9),
    );

    test('carries key, time, nonce and signature, base64url', () {
      final header = credential.header;

      expect(header, startsWith('MN1 '));
      expect(header.substring(4).split('.'), [
        base64Url.encode(memberOf(3).signingKey.bytes).replaceAll('=', ''),
        '1792700000000',
        base64Url.encode(nonce).replaceAll('=', ''),
        base64Url.encode(signatureOf(9).bytes).replaceAll('=', ''),
      ]);
      expect(RequestCredential.parse(header), credential);
    });

    test('anything else does not parse', () {
      final parts = credential.header.substring(4).split('.');
      String join(List<String> p) => 'MN1 ${p.join('.')}';

      for (final header in [
        '',
        'Bearer x',
        'MN2 ${parts.join('.')}',
        'MN1  ${parts.join('.')}',
        join(parts.sublist(1)),
        join([...parts, 'x']),
        join([parts[0], '01792700000000', parts[2], parts[3]]),
        join([parts[0], '-1', parts[2], parts[3]]),
        join([parts[0], '9007199254740992', parts[2], parts[3]]),
        join([parts[0], parts[1], '${parts[2]}=', parts[3]]),
        join(['${parts[0]}A', parts[1], parts[2], parts[3]]),
        join([parts[0], parts[1], parts[2], parts[3].replaceRange(0, 1, '+')]),
      ]) {
        expect(RequestCredential.parse(header), isNull, reason: header);
      }
    });
  });
}
