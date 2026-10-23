import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:offline_sync_adapters/offline_sync_adapters.dart';
import 'package:test/test.dart';

void main() {
  late List<http.BaseRequest> sent;

  setUp(() => sent = []);

  /// The notices as fetched from a server answering [answer].
  Future<List<Uint8List>> fetch(
    FutureOr<http.Response> Function(http.Request request) answer,
  ) => ModusServiceNotices(
    origin: Uri.parse('https://modus.example/app/'),
    client: MockClient((request) async {
      sent.add(request);
      return answer(request);
    }),
  ).fetch();

  http.Response notices(List<Object?> list, [int status = 200]) =>
      http.Response(jsonEncode({'notices': list}), status);

  test('asks for notices.json on the origin, unsigned', () async {
    await fetch((_) => notices([]));

    final request = sent.single;
    expect(request.method, 'GET');
    expect(request.url, Uri.parse('https://modus.example/notices.json'));
    expect(
      request.headers.keys.map((k) => k.toLowerCase()),
      isNot(contains('authorization')),
    );
  });

  test('hands over the envelopes as published, in order', () async {
    final envelopes = await fetch(
      (_) => notices([
        base64.encode([1, 2, 3, 0xfb, 0xff]),
        base64.encode([4]),
      ]),
    );

    expect(envelopes, [
      [1, 2, 3, 0xfb, 0xff],
      [4],
    ]);
  });

  test('reads past the highest serial the operator\'s tool keeps', () async {
    final envelopes = await fetch(
      (_) => http.Response(
        jsonEncode({
          'lastSerial': 12,
          'notices': [
            base64.encode([7]),
          ],
        }),
        200,
      ),
    );

    expect(envelopes, [
      [7],
    ]);
  });

  test('anything wrong is no notices', () async {
    final answers = <String, FutureOr<http.Response> Function(http.Request)>{
      'not found': (_) => notices([
        base64.encode([1]),
      ], 404),
      'server error': (_) => notices([
        base64.encode([1]),
      ], 500),
      'not JSON': (_) => http.Response('<html>', 200),
      'another shape': (_) => http.Response('[]', 200),
      'not strings': (_) => notices([1]),
      'not base64': (_) => notices(['***']),
      'base64url': (_) => notices([
        base64Url.encode([0xfb, 0xff]),
      ]),
      'unpadded': (_) => notices(['AQ']),
      'too many': (_) => notices([
        for (var i = 0; i < 17; i++) base64.encode([i]),
      ]),
      'too large': (_) => notices([base64.encode(Uint8List(48 * 1024))]),
      'offline': (_) => throw http.ClientException('offline'),
      'not UTF-8': (_) => http.Response.bytes([0x7b, 0xff, 0x7d], 200),
    };
    for (final MapEntry(:key, :value) in answers.entries) {
      expect(await fetch(value), isEmpty, reason: key);
    }
  });

  test('a response that says it is too large is not read', () async {
    final envelopes = await ModusServiceNotices(
      origin: Uri.parse('https://modus.example'),
      client: MockClient.streaming((request, _) async {
        sent.add(request);
        return http.StreamedResponse(
          Stream.fromIterable([utf8.encode('{"notices":[]}')]),
          200,
          contentLength: 64 * 1024 + 1,
        );
      }),
    ).fetch();

    expect(envelopes, isEmpty);
  });

  // The port promises never to throw; a TLS failure (HandshakeException)
  // or a connection reset while the body streams (SocketException) is no
  // ClientException.
  test('any other failure, before or during the body, is no notices', () async {
    final failing = [
      MockClient.streaming((request, _) => throw const _Unreachable()),
      MockClient.streaming(
        (request, _) async => http.StreamedResponse(_cutShort(), 200),
      ),
    ];
    for (final client in failing) {
      final envelopes = await ModusServiceNotices(
        origin: Uri.parse('https://modus.example'),
        client: client,
      ).fetch();

      expect(envelopes, isEmpty);
    }
  });

  test('a slow server is no notices', () async {
    final envelopes = await ModusServiceNotices(
      origin: Uri.parse('https://modus.example'),
      timeout: const Duration(milliseconds: 50),
      client: MockClient((request) async {
        await Future<void>.delayed(const Duration(seconds: 1));
        return notices([]);
      }),
    ).fetch();

    expect(envelopes, isEmpty);
  });
}

/// Not an `http.ClientException`, as `dart:io` throws them.
final class _Unreachable implements Exception {
  const _Unreachable();
}

/// The start of a body, then the connection is gone.
Stream<List<int>> _cutShort() async* {
  yield utf8.encode('{"notices":[');
  throw const _Unreachable();
}
