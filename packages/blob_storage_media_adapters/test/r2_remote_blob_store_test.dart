import 'dart:convert';
import 'dart:typed_data';

import 'package:blob_storage_media/blob_storage_media.dart';
import 'package:blob_storage_media_adapters/remote_blobs.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';
import 'package:test/test.dart';

const workspace = '0123456789abcdef0123456789abcdef';
const token = 'session-token-5d1e';
const presigned =
    'https://acct.r2.cloudflarestorage.com/modusnote/'
    '$workspace/take-1.enc?X-Amz-Signature=abc';

/// The Edge Function and R2 behind one fake client.
final class FakeCloud {
  final requests = <http.BaseRequest>[];
  final bodies = <String, Uint8List>{};
  final objects = <String, Uint8List>{};

  /// Status the Edge Function answers with instead of a URL.
  int? presignStatus;

  /// Body the Edge Function answers with instead of a URL.
  String? presignBody;

  /// Status R2 answers with instead of doing the work.
  int? r2Status;

  /// Fails every request as if the network were down.
  var offline = false;

  late final client = MockClient.streaming((request, body) async {
    requests.add(request);
    final bytes = await body.toBytes();
    bodies['${request.method} ${request.url.host}'] = bytes;
    if (offline) throw http.ClientException('no network');
    if (request.url.path == '/functions/v1/blob-url') {
      if (presignStatus case final status?) {
        return http.StreamedResponse(Stream.value(utf8.encode('{}')), status);
      }
      return http.StreamedResponse(
        Stream.value(
          utf8.encode(presignBody ?? jsonEncode({'url': presigned})),
        ),
        200,
      );
    }
    final key = request.url.path;
    if (r2Status case final status?) {
      return http.StreamedResponse(const Stream.empty(), status);
    }
    switch (request.method) {
      case 'PUT':
        if (objects.containsKey(key)) {
          return http.StreamedResponse(const Stream.empty(), 412);
        }
        objects[key] = bytes;
        return http.StreamedResponse(const Stream.empty(), 200);
      case 'GET':
        final stored = objects[key];
        if (stored == null) {
          return http.StreamedResponse(const Stream.empty(), 404);
        }
        return http.StreamedResponse(
          Stream.fromIterable([
            for (var i = 0; i < stored.length; i += 1000)
              stored.sublist(
                i,
                i + 1000 > stored.length ? stored.length : i + 1000,
              ),
          ]),
          200,
        );
    }
    return http.StreamedResponse(const Stream.empty(), 405);
  });
}

void main() {
  late FakeCloud cloud;
  final id = BlobId('take-1');
  final ciphertext = Uint8List.fromList([
    for (var i = 0; i < 4321; i++) i & 0xFF,
  ]);

  setUp(() => cloud = FakeCloud());

  R2RemoteBlobStore store({Future<String> Function()? accessToken}) =>
      R2RemoteBlobStore(
        projectUrl: Uri.parse('https://project.supabase.co'),
        anonKey: 'publishable-key',
        workspace: workspace,
        accessToken: accessToken ?? () async => token,
        client: cloud.client,
      );

  Future<void> upload([R2RemoteBlobStore? into]) => (into ?? store()).upload(
    id,
    Stream.value(ciphertext),
    length: ciphertext.length,
  );

  Future<Uint8List> download() async {
    final builder = BytesBuilder();
    await for (final piece in store().download(id)) {
      builder.add(piece);
    }
    return builder.takeBytes();
  }

  test(
    'an upload asks the function for a URL, then sends the bytes to R2',
    () async {
      await upload();

      final [presign, put] = cloud.requests;
      expect(
        presign.url,
        Uri.parse('https://project.supabase.co/functions/v1/blob-url'),
      );
      expect(presign.headers['apikey'], 'publishable-key');
      expect(presign.headers['Authorization'], 'Bearer $token');
      expect(
        jsonDecode(utf8.decode(cloud.bodies['POST project.supabase.co']!)),
        {'workspace_id': workspace, 'blob_id': 'take-1', 'method': 'PUT'},
      );
      expect(put.url, Uri.parse(presigned));
      expect(put.method, 'PUT');
      expect(put.headers['If-None-Match'], '*');
      expect(put.contentLength, ciphertext.length);
      expect(cloud.objects.values.single, ciphertext);
    },
  );

  test('a download returns the stored bytes', () async {
    await upload();

    expect(await download(), ciphertext);
  });

  test('an object R2 already holds counts as uploaded', () async {
    await upload();

    await upload();

    expect(cloud.objects, hasLength(1));
  });

  test('a blob R2 does not hold is not found', () async {
    await expectLater(download(), throwsA(isA<BlobNotFoundException>()));
  });

  group('failures', () {
    test('no network is unavailable, to be retried', () async {
      cloud.offline = true;

      await expectLater(
        upload(),
        throwsA(isA<RemoteBlobUnavailableException>()),
      );
      await expectLater(
        download(),
        throwsA(isA<RemoteBlobUnavailableException>()),
      );
    });

    test('a signed-out account is unavailable, not an error', () async {
      final signedOut = store(
        accessToken: () => Future.error(StateError('no session')),
      );

      await expectLater(
        upload(signedOut),
        throwsA(isA<RemoteBlobUnavailableException>()),
      );
      expect(cloud.requests, isEmpty);
    });

    for (final status in [500, 503, 408, 429]) {
      test('status $status from the function is unavailable', () async {
        cloud.presignStatus = status;

        await expectLater(
          upload(),
          throwsA(isA<RemoteBlobUnavailableException>()),
        );
      });
    }

    test('an account outside the workspace is refused', () async {
      cloud.presignStatus = 403;

      await expectLater(
        upload(),
        throwsA(
          isA<RemoteBlobRejectedException>().having(
            (e) => e.status,
            'status',
            403,
          ),
        ),
      );
    });

    test('R2 refusing the upload is refused', () async {
      cloud.r2Status = 403;

      await expectLater(upload(), throwsA(isA<RemoteBlobRejectedException>()));
    });
  });

  group('adversary', () {
    test('the session token never reaches R2', () async {
      await upload();
      await download();

      for (final request in cloud.requests.where(
        (r) => r.url.host != 'project.supabase.co',
      )) {
        expect(
          request.headers.keys.map((k) => k.toLowerCase()),
          isNot(contains('authorization')),
        );
        expect(request.headers.values.join(), isNot(contains(token)));
        expect(request.url.toString(), isNot(contains(token)));
      }
    });

    for (final (name, body) in [
      (
        'plain HTTP',
        jsonEncode({'url': 'http://acct.r2.cloudflarestorage.com/x'}),
      ),
      (
        'credentials in the URL',
        jsonEncode({'url': 'https://u:p@acct.r2.cloudflarestorage.com/x'}),
      ),
      ('no URL', jsonEncode({'href': presigned})),
      ('not JSON', '<html>'),
    ]) {
      test('a presign answer with $name sends nothing to it', () async {
        cloud.presignBody = body;

        await expectLater(upload(), throwsA(isA<MalformedBlobException>()));
        expect(cloud.requests, hasLength(1));
      });
    }

    test('errors carry neither the token nor the URL', () async {
      cloud.r2Status = 403;
      Object? failure;
      try {
        await upload();
      } on Object catch (error) {
        failure = error;
      }

      expect('$failure', isNot(contains(token)));
      expect('$failure', isNot(contains('X-Amz-Signature')));
    });

    test('a workspace id that could steer the path is refused', () {
      expect(
        () => R2RemoteBlobStore(
          projectUrl: Uri.parse('https://project.supabase.co'),
          anonKey: 'k',
          workspace: '../other',
          accessToken: () async => token,
        ),
        throwsArgumentError,
      );
    });
  });
}
