import 'dart:async';
import 'dart:convert';

import 'package:collaboration_access_control/collaboration_access_control.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:offline_sync/offline_sync.dart';
import 'package:offline_sync_adapters/offline_sync_adapters.dart';
import 'package:test/test.dart';

final workspace = WorkspaceId.parse('00112233445566778899aabbccddeeff');
final note = RecordId.parse('0123456789abcdef0123456789abcdef');
final project = Uri.parse('https://example.supabase.co');

String hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

SealedRow row(int marker) => SealedRow(
  record: note,
  ciphertext: WorkspaceCiphertext(
    epoch: KeyEpoch(3),
    envelope: EncryptedEnvelope(
      nonce: Nonce.fromBytes(List.filled(Nonce.length, marker)),
      ciphertext: List.filled(EncryptedEnvelope.tagLength, marker),
    ),
  ),
);

Map<String, Object?> wireRow(int position, SealedRow row) => {
  'position': position,
  'record_id': row.record.hex,
  'epoch': row.ciphertext.epoch.value,
  'ciphertext': '\\x${hex(row.ciphertext.envelope.toBytes())}',
};

void main() {
  late List<http.Request> requests;
  late FutureOr<http.Response> Function(http.Request) respond;

  SupabaseSyncServer server({int pageSize = 500}) => SupabaseSyncServer(
    projectUrl: project,
    anonKey: 'public-anon-key',
    accessToken: () async => 'session-token',
    pageSize: pageSize,
    client: MockClient((request) async {
      requests.add(request);
      return respond(request);
    }),
  );

  setUp(() {
    requests = [];
    respond = (_) => http.Response('[]', 200);
  });

  group('push', () {
    test('appends rows to sync_rows as the signed-in account', () async {
      respond = (_) => http.Response('', 201);

      await server().push(workspace, [row(1), row(2)]);

      final request = requests.single;
      expect(request.method, 'POST');
      expect(request.url.path, '/rest/v1/sync_rows');
      expect(request.headers['apikey'], 'public-anon-key');
      expect(request.headers['Authorization'], 'Bearer session-token');
      expect(request.headers['Prefer'], 'return=minimal');
      expect(jsonDecode(request.body), [
        for (final r in [row(1), row(2)])
          {
            'workspace_id': workspace.hex,
            'record_id': r.record.hex,
            'epoch': 3,
            'ciphertext': '\\x${hex(r.ciphertext.envelope.toBytes())}',
          },
      ]);
    });

    test('never sends a position: the server assigns it', () async {
      respond = (_) => http.Response('', 201);

      await server().push(workspace, [row(1)]);

      expect(
        (jsonDecode(requests.single.body) as List).single,
        isNot(contains('position')),
      );
    });
  });

  group('pull', () {
    test('reads rows after the cursor, in order, page by page', () async {
      respond = (request) {
        final after = request.url.queryParameters['position']!;
        return http.Response(
          jsonEncode(switch (after) {
            'gt.0' => [wireRow(1, row(1)), wireRow(2, row(2))],
            'gt.2' => [wireRow(5, row(5))],
            _ => [],
          }),
          200,
        );
      };

      final pulled = await server(pageSize: 2).pull(workspace, after: 0);

      expect(pulled.map((p) => p.cursor), [1, 2, 5]);
      expect(pulled.map((p) => p.row), [row(1), row(2), row(5)]);
      expect(requests.first.url.queryParameters, {
        'select': 'position,record_id,epoch,ciphertext',
        'workspace_id': 'eq.${workspace.hex}',
        'position': 'gt.0',
        'order': 'position.asc',
        'limit': '2',
      });
    });

    test(
      'membership records come back contiguous from the asked sequence',
      () async {
        respond = (_) => http.Response(jsonEncode([]), 200);

        expect(await server().membership(workspace, from: 4), isEmpty);
        expect(requests.single.url.queryParameters['sequence'], 'gte.4');
      },
    );
  });

  group('availability', () {
    test('network errors, timeouts and 5xx mean offline', () async {
      for (final failure in <FutureOr<http.Response> Function(http.Request)>[
        (_) => throw http.ClientException('no route'),
        (_) => throw TimeoutException('slow'),
        (_) => http.Response('down', 503),
        (_) => http.Response('busy', 429),
      ]) {
        respond = failure;
        await expectLater(
          server().pull(workspace, after: 0),
          throwsA(isA<ServerUnavailableException>()),
        );
      }
    });

    test(
      'a refused request (expired session, RLS) is not mistaken for offline',
      () async {
        respond = (_) => http.Response('{"code":"42501"}', 403);

        await expectLater(
          server().push(workspace, [row(1)]),
          throwsA(isA<SyncServerRejectedException>()),
        );
      },
    );

    test('the access token never appears in an exception', () async {
      respond = (_) => http.Response('nope', 401);

      try {
        await server().pull(workspace, after: 0);
        fail('expected a rejection');
      } on SyncServerRejectedException catch (error) {
        expect(error.toString(), isNot(contains('session-token')));
      }
    });
  });

  group('adversary', () {
    test('rows out of order or before the cursor are refused', () async {
      for (final rows in [
        [wireRow(2, row(2)), wireRow(1, row(1))],
        [wireRow(0, row(1))],
        [wireRow(3, row(3)), wireRow(3, row(3))],
      ]) {
        respond = (_) => http.Response(jsonEncode(rows), 200);
        await expectLater(
          server().pull(workspace, after: 0),
          throwsA(isA<MalformedSyncDataException>()),
        );
      }
    });

    test('a gap in the membership sequence is refused', () async {
      final record = '\\x${hex([1, 2, 3])}';
      respond = (_) => http.Response(
        jsonEncode([
          {'sequence': 5, 'record': record},
        ]),
        200,
      );

      await expectLater(
        server().membership(workspace, from: 4),
        throwsA(isA<MalformedSyncDataException>()),
      );
    });

    test('a garbage row is dropped and the rest still arrives', () async {
      respond = (_) => http.Response(
        jsonEncode([
          wireRow(1, row(1)),
          {'position': 2, 'record_id': 'zz', 'epoch': 0, 'ciphertext': '\\x00'},
          {'position': 3, 'record_id': note.hex, 'epoch': 0, 'ciphertext': 7},
          wireRow(4, row(4)),
        ]),
        200,
      );

      final pulled = await server().pull(workspace, after: 0);

      expect(pulled.map((p) => p.cursor), [1, 4]);
    });

    test('a response that is not a JSON list is refused', () async {
      for (final body in ['{}', 'not json', '"x"']) {
        respond = (_) => http.Response(body, 200);
        await expectLater(
          server().pull(workspace, after: 0),
          throwsA(isA<MalformedSyncDataException>()),
        );
      }
    });
  });
}
