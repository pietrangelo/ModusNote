import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:offline_sync/offline_sync.dart';
import 'package:offline_sync_adapters/offline_sync_adapters.dart';
import 'package:test/test.dart';

final project = Uri.parse('https://example.supabase.co');
final now = DateTime.utc(2026, 10, 13, 10);

Map<String, Object?> sessionJson({
  String access = 'access-1',
  String refresh = 'refresh-1',
  int expiresIn = 3600,
}) => {
  'access_token': access,
  'token_type': 'bearer',
  'expires_in': expiresIn,
  'refresh_token': refresh,
  'user': {'id': '11111111-1111-4111-8111-111111111111', 'email': 'a@b.it'},
};

void main() {
  late List<http.Request> requests;
  late FutureOr<http.Response> Function(http.Request) respond;
  var clock = now;

  SupabaseAuth auth() => SupabaseAuth(
    projectUrl: project,
    anonKey: 'public-anon-key',
    clock: () => clock,
    client: MockClient((request) async {
      requests.add(request);
      return respond(request);
    }),
  );

  setUp(() {
    requests = [];
    clock = now;
    respond = (_) => http.Response(jsonEncode(sessionJson()), 200);
  });

  group('SupabaseAuth', () {
    test('sends a one-time code to the email, creating the account', () async {
      respond = (_) => http.Response('{}', 200);

      await auth().sendCode('a@b.it');

      final request = requests.single;
      expect(request.method, 'POST');
      expect(request.url.toString(), 'https://example.supabase.co/auth/v1/otp');
      expect(request.headers['apikey'], 'public-anon-key');
      expect(jsonDecode(request.body), {
        'email': 'a@b.it',
        'create_user': true,
      });
    });

    test('the code from the email becomes a session', () async {
      final session = await auth().verifyCode('a@b.it', '123456');

      expect(jsonDecode(requests.single.body), {
        'type': 'email',
        'email': 'a@b.it',
        'token': '123456',
      });
      expect(requests.single.url.path, '/auth/v1/verify');
      expect(session.accessToken, 'access-1');
      expect(session.refreshToken, 'refresh-1');
      expect(session.userId, '11111111-1111-4111-8111-111111111111');
      expect(session.email, 'a@b.it');
      expect(session.expiresAt, now.add(const Duration(hours: 1)));
    });

    group('the sign-in link from the email, pasted whole', () {
      // SHA-224 in hex, as GoTrue puts it in the email's link.
      const hash = '2f1b0c8e5d4a39768f2e1d0c9b8a79685f4e3d2c1b0a998877665544';
      String link({
        String host = 'example.supabase.co',
        String path = '/auth/v1/verify',
        String token = hash,
        String type = 'magiclink',
      }) =>
          'https://$host$path?token=$token&type=$type'
          '&redirect_to=http://localhost:3000';

      test('signs in with its token hash, never opening it', () async {
        final session = await auth().verifyCode('pietro@example.com', link());

        expect(
          requests.single.url.toString(),
          'https://example.supabase.co/auth/v1/verify',
        );
        expect(jsonDecode(requests.single.body), {
          'type': 'magiclink',
          'token_hash': hash,
        });
        expect(session.accessToken, 'access-1');
      });

      test('a new account\'s confirmation link signs in too', () async {
        await auth().verifyCode(
          'pietro@example.com',
          '  ${link(type: 'signup')}\n',
        );

        expect(jsonDecode(requests.single.body), {
          'type': 'signup',
          'token_hash': hash,
        });
      });

      group('adversary', () {
        for (final (name, text) in [
          ('another host', link(host: 'evil.example')),
          ('a look-alike host', link(host: 'example.supabase.co.evil.example')),
          ('another path', link(path: '/auth/v1/token')),
          ('a recovery link', link(type: 'recovery')),
          ('an invite', link(type: 'invite')),
          ('a token that is not a hash', link(token: 'x' * 56)),
          ('a short token', link(token: hash.substring(1))),
          ('plain http', link().replaceFirst('https:', 'http:')),
          (
            'credentials in the link',
            link().replaceFirst('https://', 'https://user:pw@'),
          ),
        ]) {
          test('$name is refused before any request', () async {
            await expectLater(
              auth().verifyCode('pietro@example.com', text),
              throwsA(isA<SupabaseAuthRejectedException>()),
            );
            expect(requests, isEmpty);
          });
        }
      });
    });

    test('a session is refreshed with its refresh token', () async {
      respond = (_) => http.Response(
        jsonEncode(sessionJson(access: 'access-2', refresh: 'refresh-2')),
        200,
      );
      final old = SupabaseSession(
        accessToken: 'access-1',
        refreshToken: 'refresh-1',
        expiresAt: now,
        userId: '11111111-1111-4111-8111-111111111111',
        email: 'a@b.it',
      );

      final renewed = await auth().refresh(old);

      expect(
        requests.single.url.toString(),
        'https://example.supabase.co/auth/v1/token?grant_type=refresh_token',
      );
      expect(jsonDecode(requests.single.body), {'refresh_token': 'refresh-1'});
      expect(renewed.accessToken, 'access-2');
      expect(renewed.refreshToken, 'refresh-2');
    });

    test('a wrong or expired code is a refusal, not being offline', () async {
      respond = (_) => http.Response('{"error_code":"otp_expired"}', 403);

      await expectLater(
        auth().verifyCode('a@b.it', '000000'),
        throwsA(
          isA<SupabaseAuthRejectedException>().having(
            (e) => e.status,
            'status',
            403,
          ),
        ),
      );
    });

    test('network errors and 5xx mean offline', () async {
      for (final failure in <FutureOr<http.Response> Function(http.Request)>[
        (_) => throw http.ClientException('no route'),
        (_) => http.Response('', 503),
      ]) {
        respond = failure;
        await expectLater(
          auth().sendCode('a@b.it'),
          throwsA(isA<ServerUnavailableException>()),
        );
      }
    });

    test('a session survives its byte form', () async {
      final session = await auth().verifyCode('a@b.it', '123456');

      expect(SupabaseSession.fromBytes(session.toBytes()), session);
    });

    group('adversary', () {
      test('tokens never appear in toString or exceptions', () async {
        final session = await auth().verifyCode('a@b.it', '123456');
        respond = (_) => http.Response('access-1 refresh-1', 401);

        expect(session.toString(), isNot(contains('access-1')));
        expect(session.toString(), isNot(contains('refresh-1')));
        await expectLater(
          auth().refresh(session),
          throwsA(
            predicate(
              (Object e) =>
                  !e.toString().contains('refresh-1') &&
                  !e.toString().contains('access-1'),
            ),
          ),
        );
      });

      test('a malformed session response is refused', () async {
        for (final body in [
          'not json',
          '[]',
          '{"access_token":"a"}',
          jsonEncode({...sessionJson(), 'expires_in': -5}),
          jsonEncode({
            ...sessionJson(),
            'user': {'id': 7},
          }),
        ]) {
          respond = (_) => http.Response(body, 200);
          await expectLater(
            auth().verifyCode('a@b.it', '123456'),
            throwsA(isA<MalformedSyncDataException>()),
            reason: body,
          );
        }
      });

      test('stored session bytes that do not parse read as no session', () {
        expect(SupabaseSession.fromBytes(utf8.encode('{"x":1}')), isNull);
        expect(SupabaseSession.fromBytes([0xff, 0xfe]), isNull);
      });
    });
  });

  group('SyncAccount', () {
    late List<SupabaseSession?> persisted;

    SyncAccount account() =>
        SyncAccount(auth(), clock: () => clock)
          ..attach(null, persist: (session) async => persisted.add(session));

    setUp(() => persisted = []);

    test('without a session the server is simply unreachable', () async {
      final signedOut = account();

      expect(signedOut.signedIn, isFalse);
      await expectLater(
        signedOut.accessToken(),
        throwsA(isA<ServerUnavailableException>()),
      );
      expect(requests, isEmpty);
    });

    test('signing in stores the session in the vault', () async {
      final signedIn = account();

      await signedIn.signIn('a@b.it', '123456');

      expect(signedIn.signedIn, isTrue);
      expect(signedIn.email, 'a@b.it');
      expect(await signedIn.accessToken(), 'access-1');
      expect(persisted.single!.refreshToken, 'refresh-1');
    });

    test('a token about to expire is refreshed once and stored', () async {
      final signedIn = account();
      await signedIn.signIn('a@b.it', '123456');
      requests.clear();
      clock = now.add(const Duration(minutes: 59, seconds: 30));
      respond = (_) => http.Response(
        jsonEncode(sessionJson(access: 'access-2', refresh: 'refresh-2')),
        200,
      );

      final tokens = await Future.wait([
        signedIn.accessToken(),
        signedIn.accessToken(),
      ]);

      expect(tokens, ['access-2', 'access-2']);
      expect(requests, hasLength(1), reason: 'one refresh for both callers');
      expect(persisted.last!.refreshToken, 'refresh-2');
    });

    test('a refused refresh signs the account out', () async {
      final signedIn = account();
      await signedIn.signIn('a@b.it', '123456');
      clock = now.add(const Duration(hours: 2));
      respond = (_) => http.Response('{"error":"invalid_grant"}', 400);

      await expectLater(
        signedIn.accessToken(),
        throwsA(isA<ServerUnavailableException>()),
      );
      expect(signedIn.signedIn, isFalse);
      expect(persisted.last, isNull);
    });

    test('an offline refresh keeps the session for later', () async {
      final signedIn = account();
      await signedIn.signIn('a@b.it', '123456');
      clock = now.add(const Duration(hours: 2));
      respond = (_) => throw http.ClientException('offline');

      await expectLater(
        signedIn.accessToken(),
        throwsA(isA<ServerUnavailableException>()),
      );
      expect(signedIn.signedIn, isTrue);
    });

    test('signing out forgets the session everywhere', () async {
      final signedIn = account();
      await signedIn.signIn('a@b.it', '123456');
      respond = (_) => http.Response('', 204);

      await signedIn.signOut();

      expect(signedIn.signedIn, isFalse);
      expect(persisted.last, isNull);
      expect(requests.last.url.path, '/auth/v1/logout');
    });

    test('deleting the account asks the server, then forgets it', () async {
      final signedIn = account();
      await signedIn.signIn('someone@example.com', '123456');
      respond = (_) => http.Response('{"deleted":true}', 200);

      await signedIn.deleteAccount();

      final request = requests.last;
      expect(request.method, 'POST');
      expect(request.url.toString(), '$project/functions/v1/delete-account');
      expect(request.headers['Authorization'], 'Bearer access-1');
      expect(request.headers['apikey'], 'public-anon-key');
      expect(jsonDecode(request.body), {'confirm': 'delete-account'});
      expect(signedIn.signedIn, isFalse);
      expect(persisted.last, isNull);
    });

    test('a deletion that fails keeps the account signed in', () async {
      final signedIn = account();
      await signedIn.signIn('someone@example.com', '123456');

      respond = (_) => http.Response('{"error":"storage unavailable"}', 503);
      await expectLater(
        signedIn.deleteAccount(),
        throwsA(isA<ServerUnavailableException>()),
      );
      respond = (_) => http.Response('{"error":"session refused"}', 401);
      await expectLater(
        signedIn.deleteAccount(),
        throwsA(
          isA<SupabaseAuthRejectedException>().having(
            (e) => e.status,
            'status',
            401,
          ),
        ),
      );
      expect(signedIn.signedIn, isTrue);
      expect(persisted.last, isNotNull);
    });

    test('without a session there is nothing to delete', () async {
      await expectLater(
        account().deleteAccount(),
        throwsA(isA<ServerUnavailableException>()),
      );
      expect(requests, isEmpty);
    });

    test('detaching on lock drops the session from memory', () async {
      final signedIn = account();
      await signedIn.signIn('a@b.it', '123456');

      signedIn.detach();

      expect(signedIn.signedIn, isFalse);
      await expectLater(
        signedIn.accessToken(),
        throwsA(isA<ServerUnavailableException>()),
      );
    });
  });
}
