// Runs against a real PostgREST and PostgreSQL started by
// `supabase/tests/e2e.sh`; skipped when run on its own.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:collaboration_access_control/collaboration_access_control.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:identity_cryptography_adapters/identity_cryptography_adapters.dart';
import 'package:offline_sync/offline_sync.dart';
import 'package:offline_sync_adapters/offline_sync_adapters.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

final postgrest = Platform.environment['MODUSNOTE_POSTGREST_URL'];
final jwtSecret = Platform.environment['MODUSNOTE_JWT_SECRET'];

const alice = '11111111-1111-4111-8111-111111111111';
const bob = '22222222-2222-4222-8222-222222222222';

final _random = Random.secure();

String _hex(int bytes) => [
  for (var i = 0; i < bytes; i++)
    _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
].join();

String _base64Url(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

/// A Supabase-style access token: HS256, the account in `sub`, the
/// `authenticated` role PostgREST switches to.
String accessTokenFor(String account) {
  final header = _base64Url(utf8.encode('{"alg":"HS256","typ":"JWT"}'));
  final expiry = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
  final payload = _base64Url(
    utf8.encode(
      jsonEncode({'sub': account, 'role': 'authenticated', 'exp': expiry}),
    ),
  );
  final signature = Hmac(
    sha256,
    utf8.encode(jwtSecret!),
  ).convert(utf8.encode('$header.$payload'));
  return '$header.$payload.${_base64Url(signature.bytes)}';
}

/// PostgREST serves at its root; Supabase puts it under `/rest/v1/`.
final class _SupabasePaths extends http.BaseClient {
  final _inner = http.Client();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    final base = Uri.parse(postgrest!);
    final forwarded =
        http.Request(
            request.method,
            request.url.replace(
              scheme: base.scheme,
              host: base.host,
              port: base.port,
              path: request.url.path.replaceFirst('/rest/v1', ''),
            ),
          )
          ..headers.addAll(request.headers)
          ..bodyBytes = (request as http.Request).bodyBytes;
    return _inner.send(forwarded);
  }
}

SupabaseSyncServer serverFor(String account, {int pageSize = 500}) =>
    SupabaseSyncServer(
      projectUrl: Uri.parse('https://project.supabase.co'),
      anonKey: 'anon',
      accessToken: () async => accessTokenFor(account),
      client: _SupabasePaths(),
      pageSize: pageSize,
    );

PublicIdentity identity(int seed) => PublicIdentity(
  signingKey: PublicSigningKey.fromBytes(
    List.filled(PublicSigningKey.length, seed),
  ),
  encryptionKey: PublicEncryptionKey.fromBytes(
    List.filled(PublicEncryptionKey.length, seed),
  ),
);

Signature signature(int seed) =>
    Signature.fromBytes(List.filled(Signature.length, seed));

// Signatures are fake: the server never verifies them, the clients do.
List<MembershipRecord> membershipOf(WorkspaceId workspace) => [
  MembershipRecord(
    workspace: workspace,
    sequence: 0,
    author: MemberId.of(identity(1)),
    previous: null,
    change: WorkspaceFounded(identity(1)),
    signature: signature(1),
  ),
  MembershipRecord(
    workspace: workspace,
    sequence: 1,
    author: MemberId.of(identity(1)),
    previous: signature(1),
    change: MemberInvited(identity(2), Role.editor),
    signature: signature(2),
  ),
];

KeyBundle bundleOf(WorkspaceId workspace) => KeyBundle(
  workspace: workspace,
  atSequence: 1,
  issuer: MemberId.of(identity(1)),
  grants: [
    GroupKeyGrant(
      recipient: MemberId.of(identity(2)),
      epoch: KeyEpoch.initial,
      sealedKey: SealedKey.parse(
        Uint8List.fromList([
          ...List.filled(SealedKey.encapsulationLength, 3),
          EncryptedEnvelope.currentVersion,
          ...List.filled(
            SealedKey.length - SealedKey.encapsulationLength - 1,
            3,
          ),
        ]),
      ),
    ),
  ],
  signature: signature(3),
);

SealedRow sealedRow(int marker) => SealedRow(
  record: RecordId.parse(_hex(16)),
  ciphertext: WorkspaceCiphertext(
    epoch: KeyEpoch(marker),
    envelope: EncryptedEnvelope(
      nonce: Nonce.fromBytes(List.filled(Nonce.length, marker)),
      ciphertext: List.filled(EncryptedEnvelope.tagLength + marker, marker),
    ),
  ),
);

void expectSameRows(List<PulledRow> pulled, List<SealedRow> pushed) {
  expect(pulled.map((p) => p.row.record), pushed.map((r) => r.record));
  expect(
    pulled.map((p) => p.row.ciphertext.envelope.toBytes()),
    pushed.map((r) => r.ciphertext.envelope.toBytes()),
  );
  expect(
    pulled.map((p) => p.row.ciphertext.epoch),
    pushed.map((r) => r.ciphertext.epoch),
  );
}

Future<WorkspaceId> foundWorkspace() async {
  final workspace = WorkspaceId.parse(_hex(16));
  await serverFor(alice).createWorkspace(workspace);
  return workspace;
}

void main() {
  final skip = postgrest == null || jwtSecret == null
      ? 'needs supabase/tests/e2e.sh'
      : null;

  group('SupabaseSyncServer against PostgREST', skip: skip, () {
    test('rows, bundles and membership round-trip byte for byte', () async {
      final workspace = await foundWorkspace();
      final server = serverFor(alice, pageSize: 2);
      final rows = [for (var i = 1; i <= 5; i++) sealedRow(i)];
      final records = membershipOf(workspace);

      for (final record in records) {
        await server.appendMembership(record);
      }
      await server.appendKeyBundle(bundleOf(workspace));
      await server.push(workspace, rows.sublist(0, 3));
      await server.push(workspace, rows.sublist(3));

      final pulled = await server.pull(workspace, after: 0);
      expect(pulled.map((p) => p.cursor), [1, 2, 3, 4, 5]);
      expectSameRows(pulled, rows);
      expectSameRows(await server.pull(workspace, after: 3), rows.sublist(3));
      expect(await server.membership(workspace, from: 0), records);
      expect(await server.membership(workspace, from: 1), records.sublist(1));
      expect(await server.keyBundles(workspace, after: 0), [
        (1, bundleOf(workspace)),
      ]);
    });

    test('registering a workspace again is harmless', () async {
      final workspace = await foundWorkspace();

      await serverFor(alice).createWorkspace(workspace);
      await serverFor(alice).appendMembership(membershipOf(workspace)[0]);

      expect(
        await serverFor(alice).membership(workspace, from: 0),
        hasLength(1),
      );
    });

    test('a new vault publishes itself and syncs its notes', () async {
      final sodium = await SodiumSumoInit.init();
      final database = sqlite3.openInMemory();
      addTearDown(database.close);
      final keeper = VaultKeeper(
        vaults: SqliteVaultStore(database),
        records: (workspace) =>
            SqliteLocalRecordStore(database, workspace: workspace),
        server: serverFor(alice),
        identities: SodiumIdentityService(sodium),
        keys: SodiumKeyDerivationService(sodium),
        subkeys: SodiumSubkeyDerivationService(sodium),
        envelopes: SodiumEnvelopeEncryptor(sodium),
        encapsulation: SodiumKeyEncapsulation(sodium),
        clock: _Clock(),
        random: Random.secure(),
        kdf: KdfParameters.interactive,
      );
      final vault = await keeper.create(
        SodiumPasswordSecret.fromUtf8Bytes(
          sodium,
          Uint8List.fromList(utf8.encode('correct horse')),
        ),
      );
      addTearDown(vault.lock);
      final note = RecordId.parse(_hex(16));
      await vault.engine.write(
        note,
        RevisionContents(Uint8List.fromList(utf8.encode('sul server'))),
      );

      final first = await vault.engine.sync();
      final second = await vault.engine.sync();

      expect(first.offline, isFalse);
      expect(first.pushed, 1);
      expect(second.pushed, 0);
      final server = serverFor(alice);
      expect(
        await server.membership(vault.workspace, from: 0),
        vault.engine.ledger.records,
      );
      final rows = await server.pull(vault.workspace, after: 0);
      expect(rows.single.row.record, note);
      expect(
        latin1.decode(rows.single.row.ciphertext.envelope.toBytes()),
        isNot(contains('sul server')),
      );
    });

    group('linking devices of one account', () {
      late SodiumSumo sodium;
      // A fresh account per test: offers are per account.
      late String account;

      setUpAll(() async => sodium = await SodiumSumoInit.init());
      setUp(
        () => account =
            '${_hex(4)}-${_hex(2)}-4${_hex(2).substring(1)}-'
            '8${_hex(2).substring(1)}-${_hex(6)}',
      );

      PasswordSecret secret(List<int> utf8Bytes) =>
          SodiumPasswordSecret.fromUtf8Bytes(
            sodium,
            Uint8List.fromList(utf8Bytes),
          );

      VaultKeeper keeperFor(String user) {
        final database = sqlite3.openInMemory();
        addTearDown(database.close);
        final server = serverFor(user);
        return VaultKeeper(
          vaults: SqliteVaultStore(database),
          records: (workspace) =>
              SqliteLocalRecordStore(database, workspace: workspace),
          server: server,
          identities: SodiumIdentityService(sodium),
          keys: SodiumKeyDerivationService(sodium),
          subkeys: SodiumSubkeyDerivationService(sodium),
          envelopes: SodiumEnvelopeEncryptor(sodium),
          encapsulation: SodiumKeyEncapsulation(sodium),
          clock: _Clock(),
          random: Random.secure(),
          kdf: KdfParameters.interactive,
          links: server,
        );
      }

      final code = LinkCode.tryParse('K7MQ4-XT9AB')!;

      test(
        'a second device joins through the server and reads the notes',
        () async {
          final phone = keeperFor(account);
          final founder = await phone.create(secret(utf8.encode('frase uno')));
          addTearDown(founder.lock);
          final note = RecordId.parse(_hex(16));
          await founder.engine.write(
            note,
            RevisionContents(Uint8List.fromList(utf8.encode('condivisa'))),
          );
          await founder.engine.sync();

          final offering = await phone.offerLink(
            founder,
            secret(code.toBytes()),
          );
          final browser = keeperFor(account);
          final request = await browser.join(
            code: secret(code.toBytes()),
            passphrase: secret(utf8.encode('frase due')),
          );
          expect(await offering.poll(), isNotNull);
          final joined = await request.poll();
          addTearDown(() => joined?.lock());
          await joined!.engine.sync();

          expect(switch (await joined.engine.read(note)) {
            RevisionContents(:final bytes) => utf8.decode(bytes),
            _ => null,
          }, 'condivisa');
          expect(await serverFor(account).latestOffer(), isNull);
        },
      );

      test('another account never sees the offer', () async {
        final phone = keeperFor(account);
        final founder = await phone.create(secret(utf8.encode('frase uno')));
        addTearDown(founder.lock);
        final offering = await phone.offerLink(founder, secret(code.toBytes()));
        addTearDown(offering.cancel);

        await expectLater(
          keeperFor(bob).join(
            code: secret(code.toBytes()),
            passphrase: secret(utf8.encode('frase due')),
          ),
          throwsA(isA<LinkCodeRejectedException>()),
        );
      });
    });

    test('an account added by a manager reads and appends', () async {
      final workspace = await foundWorkspace();
      await serverFor(alice).push(workspace, [sealedRow(1)]);

      await serverFor(alice).addAccount(workspace, bob);
      await serverFor(bob).push(workspace, [sealedRow(2)]);

      expect(
        (await serverFor(alice).pull(workspace, after: 0)).map((p) => p.cursor),
        [1, 2],
      );
    });

    group('adversary', () {
      test('an outsider reads nothing and cannot append', () async {
        final workspace = await foundWorkspace();
        await serverFor(alice).push(workspace, [sealedRow(1)]);
        await serverFor(alice).appendMembership(membershipOf(workspace)[0]);

        final outsider = serverFor(bob);
        expect(await outsider.pull(workspace, after: 0), isEmpty);
        expect(await outsider.membership(workspace, from: 0), isEmpty);
        await expectLater(
          outsider.push(workspace, [sealedRow(2)]),
          throwsA(isA<SyncServerRejectedException>()),
        );
        await expectLater(
          outsider.addAccount(workspace, bob),
          throwsA(isA<SyncServerRejectedException>()),
        );
      });

      test('a member who is not a manager cannot add accounts', () async {
        final workspace = await foundWorkspace();
        await serverFor(alice).addAccount(workspace, bob);

        await expectLater(
          serverFor(bob).addAccount(workspace, _uuid()),
          throwsA(isA<SyncServerRejectedException>()),
        );
      });

      test('a workspace registered by another account stays theirs', () async {
        final workspace = await foundWorkspace();

        await serverFor(bob).createWorkspace(workspace);

        await expectLater(
          serverFor(bob).appendMembership(membershipOf(workspace)[0]),
          throwsA(isA<SyncServerRejectedException>()),
        );
        expect(await serverFor(bob).pull(workspace, after: 0), isEmpty);
      });

      test('a membership sequence cannot be written twice', () async {
        final workspace = await foundWorkspace();
        final founded = membershipOf(workspace)[0];
        await serverFor(alice).appendMembership(founded);

        await expectLater(
          serverFor(alice).appendMembership(founded),
          throwsA(isA<SyncServerRejectedException>()),
        );
      });

      test('a token signed with another secret is refused', () async {
        final workspace = await foundWorkspace();
        final forged = SupabaseSyncServer(
          projectUrl: Uri.parse('https://project.supabase.co'),
          anonKey: 'anon',
          accessToken: () async {
            final [header, payload, _] = accessTokenFor(alice).split('.');
            return '$header.$payload.${_base64Url(List.filled(32, 0))}';
          },
          client: _SupabasePaths(),
        );

        await expectLater(
          forged.pull(workspace, after: 0),
          throwsA(isA<SyncServerRejectedException>()),
        );
      });
    });
  });
}

String _uuid() {
  final h = _hex(16);
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-4${h.substring(13, 16)}-'
      '8${h.substring(17, 20)}-${h.substring(20)}';
}

final class _Clock implements Clock {
  @override
  DateTime now() => DateTime.now().toUtc();
}
