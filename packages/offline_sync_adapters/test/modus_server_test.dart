import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:collaboration_access_control/collaboration_access_control.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:identity_cryptography_adapters/identity_cryptography_adapters.dart';
import 'package:offline_sync/offline_sync.dart';
import 'package:offline_sync_adapters/offline_sync_adapters.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:test/test.dart';

final class _Clock implements Clock {
  @override
  DateTime now() => DateTime.utc(2026, 10, 22, 12);
}

void main() {
  late SodiumSumo sodium;
  late IdentityKeyPair device;
  late RequestSigner signer;
  final workspace = WorkspaceId.parse('00112233445566778899aabbccddeeff');
  final record = RecordId.parse('0123456789abcdef0123456789abcdef');
  late List<http.Request> sent;

  setUpAll(() async => sodium = await SodiumSumoInit.init());

  setUp(() {
    device = SodiumIdentityService(sodium).generateIdentity();
    addTearDown(device.dispose);
    signer = RequestSigner(
      identities: SodiumIdentityService(sodium),
      hasher: SodiumContentHasher(sodium),
      device: device,
      clock: _Clock(),
      random: Random.secure(),
    );
    sent = [];
  });

  /// A server answering [answer] to every request it gets.
  SyncServer serverAnswering(
    http.Response Function(http.Request request) answer,
  ) => ModusServer(
    origin: Uri.parse('https://modus.example'),
    blake2b: blake2b256,
    client: MockClient((request) async {
      sent.add(request);
      return answer(request);
    }),
  ).server(signer);

  http.Response json(Object body, [int status = 200]) =>
      http.Response(jsonEncode(body), status);

  SealedRow row(int size) => SealedRow(
    record: record,
    ciphertext: WorkspaceCiphertext(
      epoch: KeyEpoch(0),
      envelope: EncryptedEnvelope(
        nonce: Nonce.fromBytes(List.filled(Nonce.length, 1)),
        ciphertext: List.filled(size + EncryptedEnvelope.tagLength, 2),
      ),
    ),
  );

  Map<String, Object> pulled(int position) => {
    'position': position,
    'record': record.hex,
    'ciphertext': base64.encode(row(4).ciphertext.toBytes()),
  };

  group('requests', () {
    test('every request is signed over its path, query included', () async {
      final server = serverAnswering(
        (_) => json({'rows': <Object>[], 'more': false}),
      );

      await server.pull(workspace, after: 7);

      final request = sent.single;
      expect(request.url.path, '/api/w/${workspace.hex}/rows');
      expect(request.url.query, 'after=7');
      final credential = RequestCredential.parse(
        request.headers['Authorization']!,
      )!;
      final digest = await (SodiumContentHasher(
        sodium,
      ).start()..add(Uint8List(0))).close();
      SodiumIdentityService(sodium).verify(
        SignedRequest(
          method: 'GET',
          path: '/api/w/${workspace.hex}/rows?after=7',
          millis: credential.millis,
          nonce: credential.nonce,
          body: digest,
        ).signable,
        signature: credential.signature,
        signer: device.publicIdentity.signingKey,
      );
    });

    test('a clock refused once is corrected and the request signed again', () {
      final serverNow = DateTime.utc(2026, 10, 22, 12, 9);
      var calls = 0;
      final server = serverAnswering((_) {
        calls++;
        return calls == 1
            ? json({
                'error': 'clock',
                'now': serverNow.millisecondsSinceEpoch,
              }, 401)
            : json({'rows': 0, 'bundles': 0, 'membership': 1});
      });

      return server.heads(workspace).then((heads) {
        expect(heads?.membership, 1);
        final second = RequestCredential.parse(
          sent.last.headers['Authorization']!,
        )!;
        expect(second.millis, serverNow.millisecondsSinceEpoch);
      });
    });

    test('a second clock refusal is final', () async {
      final server = serverAnswering(
        (_) => json({'error': 'clock', 'now': 1}, 401),
      );

      await expectLater(
        server.heads(workspace),
        throwsA(
          isA<SyncServerRejectedException>().having(
            (error) => error.status,
            'status',
            401,
          ),
        ),
      );
      expect(sent, hasLength(2));
    });

    test('what each refusal means', () async {
      for (final (status, matcher) in [
        (403, isA<NotAdmittedException>()),
        (404, isA<NotAdmittedException>()),
        (408, isA<ServerUnavailableException>()),
        (429, isA<ServerUnavailableException>()),
        (503, isA<ServerUnavailableException>()),
        (413, isA<SyncServerRejectedException>()),
        (422, isA<SyncServerRejectedException>()),
      ]) {
        final server = serverAnswering((_) => json({'error': 'x'}, status));
        await expectLater(
          server.heads(workspace),
          throwsA(matcher),
          reason: '$status',
        );
      }
    });

    test('no network is offline', () async {
      final server = serverAnswering((_) => throw http.ClientException('down'));

      await expectLater(
        server.heads(workspace),
        throwsA(isA<ServerUnavailableException>()),
      );
    });
  });

  group('rows', () {
    test('a pull reads every page', () async {
      final server = serverAnswering(
        (request) => request.url.query == 'after=0'
            ? json({
                'rows': [pulled(1), pulled(3)],
                'more': true,
              })
            : json({
                'rows': [pulled(4)],
                'more': false,
              }),
      );

      final rows = await server.pull(workspace, after: 0);

      expect(rows.map((row) => row.cursor), [1, 3, 4]);
      expect(sent.map((request) => request.url.query), ['after=0', 'after=3']);
    });

    test('a push goes in batches of at most a hundred rows', () async {
      final server = serverAnswering((request) {
        final rows = (jsonDecode(request.body) as Map)['rows'] as List;
        return json({
          'positions': [for (var i = 0; i < rows.length; i++) i + 1],
        }, 201);
      });

      await server.push(workspace, [for (var i = 0; i < 250; i++) row(10)]);

      expect(
        sent.map(
          (request) =>
              ((jsonDecode(request.body) as Map)['rows'] as List).length,
        ),
        [100, 100, 50],
      );
    });

    test('a push of large rows stays under the size of a request', () async {
      final server = serverAnswering(
        (request) => json({
          'positions': [
            for (final _ in (jsonDecode(request.body) as Map)['rows'] as List)
              1,
          ],
        }, 201),
      );

      await server.push(workspace, [for (var i = 0; i < 10; i++) row(1 << 20)]);

      for (final request in sent) {
        expect(request.bodyBytes.length, lessThan(8 << 20));
      }
      expect(sent.length, greaterThan(1));
    });

    test('the row carries its epoch with the ciphertext, and supersedes', () {
      final server = serverAnswering(
        (_) => json({
          'positions': [1],
        }, 201),
      );
      final sealed = SealedRow(
        record: record,
        ciphertext: row(4).ciphertext,
        supersedes: 9,
      );

      return server.push(workspace, [sealed]).then((_) {
        final body = jsonDecode(sent.single.body) as Map;
        expect(body, {
          'rows': [
            {
              'record': record.hex,
              'ciphertext': base64.encode(sealed.ciphertext.toBytes()),
              'supersedes': 9,
            },
          ],
        });
      });
    });
  });

  group('adversary', () {
    test('positions that do not grow are refused', () async {
      final server = serverAnswering(
        (_) => json({
          'rows': [pulled(3), pulled(3)],
          'more': false,
        }),
      );

      await expectLater(
        server.pull(workspace, after: 0),
        throwsA(isA<MalformedSyncDataException>()),
      );
    });

    test('an empty page that claims more is refused', () async {
      final server = serverAnswering(
        (_) => json({'rows': <Object>[], 'more': true}),
      );

      await expectLater(
        server.pull(workspace, after: 0),
        throwsA(isA<MalformedSyncDataException>()),
      );
    });

    test('ciphertext that is not one is refused', () async {
      final server = serverAnswering(
        (_) => json({
          'rows': [
            {'position': 1, 'record': record.hex, 'ciphertext': 'AAAA'},
          ],
          'more': false,
        }),
      );

      await expectLater(
        server.pull(workspace, after: 0),
        throwsA(isA<MalformedSyncDataException>()),
      );
    });

    test('a membership log with a gap is refused', () async {
      final identities = SodiumIdentityService(sodium);
      final founded = WorkspaceAdministration(
        identities: identities,
        encapsulation: SodiumKeyEncapsulation(sodium),
        envelopes: SodiumEnvelopeEncryptor(sodium),
      ).found(workspace, founder: device);
      addTearDown(founded.keyring.dispose);
      final server = serverAnswering(
        (_) => json({
          'records': [base64.encode(founded.ledger.records.first.toBytes())],
        }),
      );

      expect(await server.membership(workspace, from: 0), hasLength(1));
      await expectLater(
        server.membership(workspace, from: 1),
        throwsA(isA<MalformedSyncDataException>()),
      );
    });

    test('an answer that is not JSON is refused', () async {
      final server = serverAnswering((_) => http.Response('<html>', 200));

      await expectLater(
        server.heads(workspace),
        throwsA(isA<MalformedSyncDataException>()),
      );
    });
  });

  group('proof of work', () {
    test('founding proves the work the server asks for', () async {
      final identities = SodiumIdentityService(sodium);
      final founded = WorkspaceAdministration(
        identities: identities,
        encapsulation: SodiumKeyEncapsulation(sodium),
        envelopes: SodiumEnvelopeEncryptor(sodium),
      ).found(workspace, founder: device);
      addTearDown(founded.keyring.dispose);
      final server = serverAnswering(
        (request) => request.url.path == '/api/info'
            ? json({'server': 'test', 'pow': 12})
            : json({}, 201),
      );

      await server.createWorkspace(founded.ledger.records);

      final body = jsonDecode(sent.last.body) as Map;
      expect(body['records'], [
        base64.encode(founded.ledger.records.single.toBytes()),
      ]);
      expect(await server.serverId(), 'test');
      final pow = body['pow'] as Map;
      final day = pow['day'] as int;
      final message = Uint8List.fromList([
        ...ascii.encode('modusnote.pow.v1'),
        1,
        16,
        ...workspace.bytes,
        day >> 24 & 0xff,
        day >> 16 & 0xff,
        day >> 8 & 0xff,
        day & 0xff,
        ...base64.decode(pow['nonce'] as String),
      ]);
      final digest = blake2b256(message);
      expect(digest[0], 0);
      expect(digest[1] >> 4, 0);
      expect(sent.first.headers['Authorization'], isNull);
    });

    test('another first record under the id is a forked log', () async {
      final identities = SodiumIdentityService(sodium);
      final founded = WorkspaceAdministration(
        identities: identities,
        encapsulation: SodiumKeyEncapsulation(sodium),
        envelopes: SodiumEnvelopeEncryptor(sodium),
      ).found(workspace, founder: device);
      addTearDown(founded.keyring.dispose);
      final server = serverAnswering(
        (request) => request.url.path == '/api/info'
            ? json({'server': 'test', 'pow': 1})
            : json({'error': 'conflict'}, 409),
      );

      await expectLater(
        server.createWorkspace(founded.ledger.records),
        throwsA(isA<LedgerRollbackException>()),
      );
    });
  });

  group('codes', () {
    InviteChannel codes(
      http.Response Function(http.Request) answer, {
      bool owner = true,
    }) => ModusServer(
      origin: Uri.parse('https://modus.example'),
      blake2b: blake2b256,
      client: MockClient((request) async {
        sent.add(request);
        return answer(request);
      }),
    ).invites(owner ? signer : null);

    final offer = InviteOffer(
      lookup: 'K7MQ4X',
      salt: Salt.fromBytes(List.filled(Salt.length, 1)),
      sealedInvitation: EncryptedEnvelope(
        nonce: Nonce.fromBytes(List.filled(Nonce.length, 1)),
        ciphertext: List.filled(
          Invitation.length + EncryptedEnvelope.tagLength,
          2,
        ),
      ),
    );

    test('a lookup held by another offer is taken', () async {
      final channel = codes((_) => json({'error': 'conflict'}, 409));

      await expectLater(
        channel.postInvite(workspace, offer),
        throwsA(isA<LookupTakenException>()),
      );
      expect(sent.single.url.path, '/api/w/${workspace.hex}/codes/K7MQ4X');
    });

    test('no offer under a lookup is no offer', () async {
      final channel = codes(
        (_) => json({'error': 'not_found'}, 404),
        owner: false,
      );

      expect(await channel.invite('K7MQ4X'), isNull);
      expect(sent.single.headers['Authorization'], isNull);
    });

    test('an offer posted under another lookup is no offer', () async {
      final channel = codes(
        (_) => json({'offer': base64.encode(offer.toBytes())}),
        owner: false,
      );

      expect(await channel.invite('K7MQ4X'), offer);
      expect(await channel.invite('M3PQ8Z'), isNull);
    });

    test('answers that do not parse are skipped, not fatal', () async {
      final answer = InviteAnswer(
        lookup: 'K7MQ4X',
        sealedJoiner: EncryptedEnvelope(
          nonce: Nonce.fromBytes(List.filled(Nonce.length, 1)),
          ciphertext: List.filled(
            InviteAnswer.joinerLength + EncryptedEnvelope.tagLength,
            3,
          ),
        ),
      );
      final channel = codes(
        (_) => json({
          'answers': ['nonsense', base64.encode(answer.toBytes()), 'AAAA'],
        }),
      );

      expect(await channel.inviteAnswers('K7MQ4X'), [answer]);
    });

    test('a lookup outside the alphabet never reaches the server', () async {
      final channel = codes((_) => json({}), owner: false);

      await expectLater(
        channel.invite('../w/x'),
        throwsA(isA<MalformedSyncDataException>()),
      );
      expect(sent, isEmpty);
    });

    test('only an owner posts, reads answers and closes', () async {
      final channel = codes((_) => json({}), owner: false);

      expect(() => channel.postInvite(workspace, offer), throwsStateError);
      expect(() => channel.inviteAnswers('K7MQ4X'), throwsStateError);
    });
  });
}
