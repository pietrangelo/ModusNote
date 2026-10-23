import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:blob_storage_media/blob_storage_media.dart';
import 'package:blob_storage_media_adapters/remote_blobs.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';
import 'package:test/test.dart';

const workspace = '0123456789abcdef0123456789abcdef';

/// The Worker behind one fake client: it stores what is put and answers
/// what is asked, the way the real one does.
final class FakeWorker {
  final requests = <http.BaseRequest>[];
  final bodies = <String, Uint8List>{};
  final objects = <String, Uint8List>{};

  /// What every request was signed over: `METHOD target body-length`.
  final signed = <String>[];

  /// Status to answer with instead of doing the work.
  int? status;

  /// Body to answer with instead of doing the work.
  String? answer;

  /// Refuses the next request for the device's clock.
  var clockOff = false;

  /// Fails every request as if the network were down.
  var offline = false;

  late final client = MockClient.streaming((request, body) async {
    requests.add(request);
    final bytes = await body.toBytes();
    bodies['${request.method} ${request.url.path}'] = bytes;
    if (offline) throw http.ClientException('no network');
    if (clockOff) {
      clockOff = false;
      return _reply(401, '{"error":"clock","now":1792700000000}');
    }
    if (status case final status?) return _reply(status, answer ?? '{}');
    final path = request.url.path;
    final id = path.split('/').last;
    switch (request.method) {
      case 'PUT':
        final fresh = !objects.containsKey(id);
        objects[id] = bytes;
        return _reply(fresh ? 201 : 200, '');
      case 'GET' when path.endsWith('/blobs'):
        return _reply(
          200,
          answer ??
              jsonEncode({
                'blobs': [
                  for (final MapEntry(:key, :value) in objects.entries)
                    {'id': key, 'size': value.length, 'uploaded': 1000},
                ],
                'more': false,
              }),
        );
      case 'GET':
        final object = objects[id];
        return object == null
            ? _reply(404, '{"error":"not_found"}')
            : http.StreamedResponse(Stream.value(object), 200);
      case 'POST':
        final ids = (jsonDecode(utf8.decode(bytes)) as Map)['ids'] as List;
        ids.forEach(objects.remove);
        return _reply(200, '');
    }
    return _reply(405, '{}');
  });

  http.StreamedResponse _reply(int status, String body) =>
      http.StreamedResponse(Stream.value(utf8.encode(body)), status);
}

void main() {
  late FakeWorker worker;
  late ModusRemoteBlobStore store;
  final times = <DateTime>[];
  final take = BlobId('take-1');

  setUp(() {
    worker = FakeWorker();
    times.clear();
    store = ModusRemoteBlobStore(
      origin: Uri.parse('https://modus.example'),
      workspace: workspace,
      authorize: (method, target, body) async {
        worker.signed.add('$method $target ${body.length}');
        return 'MN1 signed';
      },
      serverTime: times.add,
      client: worker.client,
    );
  });

  Stream<Uint8List> chunks(List<int> bytes) =>
      Stream.fromIterable([Uint8List.fromList(bytes)]);

  test(
    'an upload is signed over an empty body and streams the bytes',
    () async {
      await store.upload(take, chunks([1, 2, 3, 4]), length: 4);

      final request = worker.requests.single;
      expect(request.url.path, '/api/w/$workspace/blobs/take-1');
      expect(request.headers['Authorization'], 'MN1 signed');
      expect(request.contentLength, 4);
      expect(worker.signed, ['PUT /api/w/$workspace/blobs/take-1 0']);
      expect(worker.objects['take-1'], [1, 2, 3, 4]);
    },
  );

  test('a blob the server already holds counts as uploaded', () async {
    await store.upload(take, chunks([1]), length: 1);

    await store.upload(take, chunks([1]), length: 1);
  });

  test('a download returns the stored bytes', () async {
    worker.objects['take-1'] = Uint8List.fromList([5, 6, 7]);

    final bytes = await store.download(take).expand((piece) => piece).toList();

    expect(bytes, [5, 6, 7]);
    expect(worker.signed, ['GET /api/w/$workspace/blobs/take-1 0']);
  });

  test('a blob the server does not hold is not found', () {
    expect(
      store.download(take).drain<void>(),
      throwsA(isA<BlobNotFoundException>()),
    );
  });

  test(
    'a download refused for the clock is signed again by the server time',
    () async {
      worker.objects['take-1'] = Uint8List.fromList([9]);
      worker.clockOff = true;

      final bytes = await store
          .download(take)
          .expand((piece) => piece)
          .toList();

      expect(bytes, [9]);
      expect(times, [
        DateTime.fromMillisecondsSinceEpoch(1792700000000, isUtc: true),
      ]);
      expect(worker.requests, hasLength(2));
    },
  );

  test('an upload refused for the clock is retried by the next sync', () async {
    worker.clockOff = true;

    await expectLater(
      store.upload(take, chunks([1]), length: 1),
      throwsA(isA<RemoteBlobUnavailableException>()),
    );
    expect(times, hasLength(1));
  });

  group('deleting', () {
    test('at most 50 a call', () async {
      for (var i = 0; i < 120; i++) {
        worker.objects['b$i'] = Uint8List(1);
      }

      await store.delete([for (var i = 0; i < 120; i++) BlobId('b$i')]);

      expect(worker.objects, isEmpty);
      expect(
        worker.requests.map((request) => request.url.path),
        everyElement('/api/w/$workspace/blobs/delete'),
      );
      expect(worker.requests, hasLength(3));
    });

    test('nothing to delete sends nothing', () async {
      await store.delete(const []);

      expect(worker.requests, isEmpty);
    });
  });

  group('listing', () {
    test('ids and upload times, in pages that say if more follow', () async {
      worker.answer = jsonEncode({
        'blobs': [
          {'id': 'a', 'size': 3, 'uploaded': 1792700000000},
          {'id': 'b', 'size': 4, 'uploaded': 1792700001000},
        ],
        'more': true,
      });

      final page = await store.list();

      expect(page.blobs.map((blob) => blob.id.value), ['a', 'b']);
      expect(
        page.blobs.first.storedAt,
        DateTime.fromMillisecondsSinceEpoch(1792700000000, isUtc: true),
      );
      expect(page.next, 'b');
      expect(worker.requests.single.url.query, isEmpty);
    });

    test('the next page starts after the cursor; the last has none', () async {
      final page = await store.list(after: 'b');

      expect(worker.requests.single.url.query, 'after=b');
      expect(page.next, isNull);
    });

    test('a cursor that is not a blob id never reaches the server', () {
      expect(
        () => store.list(after: '../x'),
        throwsA(isA<InvalidSchemaException>()),
      );
      expect(worker.requests, isEmpty);
    });
  });

  group('failures', () {
    test('no network is unavailable, to be retried', () async {
      worker.offline = true;

      await expectLater(
        store.upload(take, chunks([1]), length: 1),
        throwsA(isA<RemoteBlobUnavailableException>()),
      );
      await expectLater(
        store.list(),
        throwsA(isA<RemoteBlobUnavailableException>()),
      );
    });

    for (final status in [408, 429, 500, 503]) {
      test('status $status is unavailable', () async {
        worker.status = status;

        await expectLater(
          store.list(),
          throwsA(isA<RemoteBlobUnavailableException>()),
        );
      });
    }

    for (final status in [403, 409, 413]) {
      test('status $status is refused', () async {
        worker.status = status;

        await expectLater(
          store.upload(take, chunks([1]), length: 1),
          throwsA(
            isA<RemoteBlobRejectedException>().having(
              (error) => error.status,
              'status',
              status,
            ),
          ),
        );
      });
    }
  });

  group('a slow connection', () {
    ModusRemoteBlobStore storeOn(http.Client client) => ModusRemoteBlobStore(
      origin: Uri.parse('https://modus.example'),
      workspace: workspace,
      authorize: (method, target, body) async => 'MN1 signed',
      client: client,
      timeout: const Duration(milliseconds: 80),
    );

    test('an upload that keeps moving takes as long as it needs', () async {
      Stream<Uint8List> slow() async* {
        for (var i = 0; i < 6; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 30));
          yield Uint8List.fromList([i]);
        }
      }

      await storeOn(worker.client).upload(take, slow(), length: 6);

      expect(worker.objects['take-1'], [0, 1, 2, 3, 4, 5]);
    });

    test('an upload that stalls is aborted, to be retried', () async {
      final body = StreamController<Uint8List>();
      addTearDown(body.close);
      body.add(Uint8List.fromList([1]));
      final client = _StallingClient();

      await expectLater(
        storeOn(client).upload(take, body.stream, length: 2),
        throwsA(isA<RemoteBlobUnavailableException>()),
      );
      expect(client.aborted, isTrue);
    });
  });

  group('adversary', () {
    for (final (name, body) in [
      ('no more flag', '{"blobs":[]}'),
      ('blobs that are not a list', '{"blobs":{},"more":false}'),
      ('no JSON', '<html>'),
    ]) {
      test('a listing with $name is malformed', () async {
        worker.answer = body;
        worker.status = 200;

        await expectLater(store.list(), throwsA(isA<MalformedBlobException>()));
      });
    }

    test('entries that are not blobs are skipped, never renamed', () async {
      worker.answer = jsonEncode({
        'blobs': [
          {'id': '../a', 'size': 1, 'uploaded': 1},
          {'id': 'b', 'size': 1, 'uploaded': 'yesterday'},
          {'id': 'c', 'size': 1, 'uploaded': 1},
        ],
        'more': false,
      });

      final page = await store.list();

      expect(page.blobs.map((blob) => blob.id.value), ['c']);
    });

    test('a workspace id that could steer the path is refused', () {
      for (final id in [
        '',
        '../x',
        '0123456789ABCDEF0123456789ABCDEF',
        '$workspace/..',
      ]) {
        expect(
          () => ModusRemoteBlobStore(
            origin: Uri.parse('https://modus.example'),
            workspace: id,
            authorize: (_, _, _) async => '',
          ),
          throwsArgumentError,
          reason: id,
        );
      }
    });
  });
}

/// Reads whatever body comes and never answers, until the request is
/// aborted.
final class _StallingClient extends http.BaseClient {
  var aborted = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.finalize().listen((_) {});
    final done = Completer<http.StreamedResponse>();
    if (request case http.Abortable(:final abortTrigger?)) {
      abortTrigger.then((_) {
        aborted = true;
        done.completeError(http.RequestAbortedException(request.url));
      });
    }
    return done.future;
  }
}
