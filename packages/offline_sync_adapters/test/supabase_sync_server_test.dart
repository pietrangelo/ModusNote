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

SealedRow row(int marker, {int supersedes = 0}) => SealedRow(
  record: note,
  ciphertext: WorkspaceCiphertext(
    epoch: KeyEpoch(3),
    envelope: EncryptedEnvelope(
      nonce: Nonce.fromBytes(List.filled(Nonce.length, marker)),
      ciphertext: List.filled(EncryptedEnvelope.tagLength, marker),
    ),
  ),
  supersedes: supersedes,
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

      await server().push(workspace, [row(1, supersedes: 9), row(2)]);

      final request = requests.single;
      expect(request.method, 'POST');
      expect(request.url.path, '/rest/v1/sync_rows');
      expect(request.headers['apikey'], 'public-anon-key');
      expect(request.headers['Authorization'], 'Bearer session-token');
      expect(request.headers['Prefer'], 'return=minimal');
      expect(jsonDecode(request.body), [
        for (final (r, supersedes) in [(row(1), 9), (row(2), 0)])
          {
            'workspace_id': workspace.hex,
            'record_id': r.record.hex,
            'epoch': 3,
            'ciphertext': '\\x${hex(r.ciphertext.envelope.toBytes())}',
            'supersedes': supersedes,
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

  group('heads', () {
    test('asks sync_heads once for the three streams', () async {
      respond = (_) =>
          http.Response('[{"rows":42,"key_bundles":3,"membership":2}]', 200);

      final heads = await server().heads(workspace);

      expect(heads, SyncHeads(rows: 42, keyBundles: 3, membership: 2));
      final request = requests.single;
      expect(request.method, 'POST');
      expect(request.url.path, '/rest/v1/rpc/sync_heads');
      expect(request.headers['Authorization'], 'Bearer session-token');
      expect(jsonDecode(request.body), {'workspace': workspace.hex});
    });

    test(
      'a deployment without sync_heads means "ask for everything"',
      () async {
        respond = (_) => http.Response('{"code":"PGRST202"}', 404);

        expect(await server().heads(workspace), isNull);
      },
    );

    test('any other refusal still surfaces', () async {
      respond = (_) => http.Response('', 401);

      await expectLater(
        server().heads(workspace),
        throwsA(
          isA<SyncServerRejectedException>().having(
            (error) => error.status,
            'status',
            401,
          ),
        ),
      );
    });

    test('adversary: malformed heads are refused', () async {
      for (final body in [
        '[]',
        '[{"rows":1,"key_bundles":0,"membership":0},'
            '{"rows":2,"key_bundles":0,"membership":0}]',
        '[{"rows":-1,"key_bundles":0,"membership":0}]',
        '[{"rows":"1","key_bundles":0,"membership":0}]',
        '[{"rows":1.5,"key_bundles":0,"membership":0}]',
        '[{"rows":1,"key_bundles":0}]',
        '{"rows":1,"key_bundles":0,"membership":0}',
      ]) {
        respond = (_) => http.Response(body, 200);
        await expectLater(
          server().heads(workspace),
          throwsA(isA<MalformedSyncDataException>()),
          reason: body,
        );
      }
    });
  });

  group('createWorkspace', () {
    test('a workspace this account already registered is success', () async {
      respond = (_) => http.Response('{"code":"23505"}', 409);

      await server().createWorkspace(workspace);

      expect(requests.single.url.path, '/rest/v1/workspaces');
      expect(jsonDecode(requests.single.body), [
        {'id': workspace.hex},
      ]);
    });

    test('any other refusal still surfaces', () async {
      respond = (_) => http.Response('', 403);

      await expectLater(
        server().createWorkspace(workspace),
        throwsA(
          isA<SyncServerRejectedException>().having(
            (e) => e.status,
            'status',
            403,
          ),
        ),
      );
    });
  });

  group('device links', () {
    final link = LinkId.parse('ffeeddccbbaa99887766554433221100');
    final offer = LinkOffer(
      id: link,
      salt: Salt.fromBytes(List.filled(Salt.length, 5)),
      sealedInvitation: EncryptedEnvelope(
        nonce: Nonce.fromBytes(List.filled(Nonce.length, 6)),
        ciphertext: List.filled(
          LinkOffer.invitationLength + EncryptedEnvelope.tagLength,
          7,
        ),
      ),
    );
    LinkAnswer answer(int marker, [LinkId? id]) => LinkAnswer(
      id: id ?? link,
      sealedIdentity: EncryptedEnvelope(
        nonce: Nonce.fromBytes(List.filled(Nonce.length, marker)),
        ciphertext: List.filled(
          PublicIdentity.length + EncryptedEnvelope.tagLength,
          marker,
        ),
      ),
    );
    Map<String, Object?> wire(LinkId id, List<int> payload) => {
      'link_id': id.hex,
      'payload': '\\x${hex(payload)}',
    };

    test('an offer and an answer are posted as opaque rows', () async {
      respond = (_) => http.Response('', 201);

      await server().postOffer(offer);
      await server().postAnswer(answer(1));

      final [posted, answered] = requests;
      expect(posted.url.path, '/rest/v1/device_links');
      expect(jsonDecode(posted.body), [
        {
          'link_id': link.hex,
          'kind': 'offer',
          'payload': '\\x${hex(offer.toBytes())}',
        },
      ]);
      expect(jsonDecode(answered.body), [
        {
          'link_id': link.hex,
          'kind': 'answer',
          'payload': '\\x${hex(answer(1).toBytes())}',
        },
      ]);
    });

    test('the newest offer is read back', () async {
      respond = (_) =>
          http.Response(jsonEncode([wire(link, offer.toBytes())]), 200);

      expect(await server().latestOffer(), offer);
      final query = requests.single.url.queryParameters;
      expect(query['kind'], 'eq.offer');
      expect(query['order'], 'id.desc');
      expect(query['limit'], '1');
    });

    test('no offer reads as none', () async {
      expect(await server().latestOffer(), isNull);
    });

    test('the answers to one link are read in order', () async {
      respond = (_) => http.Response(
        jsonEncode([
          wire(link, answer(1).toBytes()),
          wire(link, answer(2).toBytes()),
        ]),
        200,
      );

      expect(await server().answers(link), [answer(1), answer(2)]);
      final query = requests.single.url.queryParameters;
      expect(query['link_id'], 'eq.${link.hex}');
      expect(query['kind'], 'eq.answer');
    });

    test('closing a link deletes its rows', () async {
      respond = (_) => http.Response('', 204);

      await server().close(link);

      expect(requests.single.method, 'DELETE');
      expect(requests.single.url.queryParameters, {
        'link_id': 'eq.${link.hex}',
      });
    });

    group('adversary', () {
      final elsewhere = LinkId.parse('00000000000000000000000000000001');

      test('garbage or a payload naming another link is dropped', () async {
        respond = (request) => http.Response(
          jsonEncode([
            wire(link, [1, 2, 3]),
            {'link_id': link.hex, 'payload': 'not bytea'},
            wire(link, answer(3, elsewhere).toBytes()),
            wire(link, offer.toBytes()),
            wire(link, answer(4).toBytes()),
          ]),
          200,
        );

        expect(await server().answers(link), [answer(4)]);
      });

      test('an offer whose row names another link is no offer', () async {
        respond = (_) =>
            http.Response(jsonEncode([wire(elsewhere, offer.toBytes())]), 200);

        expect(await server().latestOffer(), isNull);
      });

      test('an answer is not taken for an offer', () async {
        respond = (_) =>
            http.Response(jsonEncode([wire(link, answer(1).toBytes())]), 200);

        expect(await server().latestOffer(), isNull);
      });
    });
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
