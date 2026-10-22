import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:collaboration_access_control/collaboration_access_control.dart';
import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:identity_cryptography_adapters/identity_cryptography_adapters.dart';
import 'package:offline_sync/offline_sync.dart';
import 'package:offline_sync_adapters/offline_sync_adapters.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

final class _OfflineServer implements SyncServer {
  @override
  Future<String> serverId() => throw const ServerUnavailableException();

  @override
  Future<void> createWorkspace(List<MembershipRecord> start) =>
      throw const ServerUnavailableException();

  @override
  Future<void> deleteWorkspace(WorkspaceId workspace) =>
      throw const ServerUnavailableException();

  @override
  Future<void> appendMembership(MembershipRecord record) =>
      throw const ServerUnavailableException();

  @override
  Future<void> push(WorkspaceId workspace, List<SealedRow> rows) =>
      throw const ServerUnavailableException();

  @override
  Future<List<PulledRow>> pull(WorkspaceId workspace, {required int after}) =>
      throw const ServerUnavailableException();

  @override
  Future<SyncHeads?> heads(WorkspaceId workspace) =>
      throw const ServerUnavailableException();

  @override
  Future<List<MembershipRecord>> membership(
    WorkspaceId workspace, {
    required int from,
  }) => throw const ServerUnavailableException();

  @override
  Future<List<(int, KeyBundle)>> keyBundles(
    WorkspaceId workspace, {
    required int after,
  }) => throw const ServerUnavailableException();

  @override
  Future<void> appendKeyBundle(KeyBundle bundle) =>
      throw const ServerUnavailableException();
}

final class _Clock implements Clock {
  @override
  DateTime now() => DateTime.utc(2026, 10, 11, 9);
}

void main() {
  late SodiumSumo sodium;
  late Directory directory;
  final note = RecordId.parse('0123456789abcdef0123456789abcdef');
  final workspace = WorkspaceId.parse('00112233445566778899aabbccddeeff');

  setUpAll(() async => sodium = await SodiumSumoInit.init());
  setUp(() => directory = Directory.systemTemp.createTempSync('modusnote-db'));
  tearDown(() => directory.deleteSync(recursive: true));

  test(
    'an offline edit survives a restart and never reaches disk in clear',
    () async {
      final identities = SodiumIdentityService(sodium);
      final envelopes = SodiumEnvelopeEncryptor(sodium);
      final administration = WorkspaceAdministration(
        identities: identities,
        encapsulation: SodiumKeyEncapsulation(sodium),
        envelopes: envelopes,
      );
      final me = identities.generateIdentity();
      final localKey = envelopes.generateKey();
      final founded = administration.found(workspace, founder: me);
      addTearDown(() {
        me.dispose();
        localKey.dispose();
        founded.keyring.dispose();
      });
      final path = '${directory.path}/vault.db';

      SyncEngine engineOn(Database database) => SyncEngine(
        server: _OfflineServer(),
        store: SqliteLocalRecordStore(database, workspace: workspace),
        identities: identities,
        administration: administration,
        contents: WorkspaceContentCipher(envelopes),
        envelopes: envelopes,
        localKey: localKey,
        clock: _Clock(),
        me: me,
        ledger: founded.ledger,
        keyring: founded.keyring,
      );

      final first = sqlite3.open(path);
      final engine = engineOn(first);
      await engine.write(note, RevisionContents(utf8.encode('Testo segreto')));
      await engine.write(
        note,
        RevisionContents(utf8.encode('Testo segreto 2')),
      );
      expect((await engine.sync()).offline, isTrue);
      first.close();

      final onDisk = [
        for (final file in directory.listSync().whereType<File>())
          ...file.readAsBytesSync(),
      ];
      expect(latin1.decode(onDisk), isNot(contains('segreto')));

      final second = sqlite3.open(path);
      addTearDown(second.close);
      final restarted = engineOn(second);
      final body = await restarted.read(note);

      expect(utf8.decode((body! as RevisionContents).bytes), 'Testo segreto 2');
      expect(
        (await SqliteLocalRecordStore(
          second,
          workspace: workspace,
        ).loadOutbox()).pending,
        hasLength(1),
      );
    },
  );

  test(
    'a vault created on SQLite reopens after a restart, all sealed',
    () async {
      final path = '${directory.path}/vault.db';

      VaultKeeper keeperOn(Database database) => VaultKeeper(
        vaults: SqliteVaultStore(database),
        records: (workspace) =>
            SqliteLocalRecordStore(database, workspace: workspace),
        identities: SodiumIdentityService(sodium),
        hasher: SodiumContentHasher(sodium),
        keys: SodiumKeyDerivationService(sodium),
        subkeys: SodiumSubkeyDerivationService(sodium),
        envelopes: SodiumEnvelopeEncryptor(sodium),
        encapsulation: SodiumKeyEncapsulation(sodium),
        clock: _Clock(),
        random: Random.secure(),
        kdf: KdfParameters.interactive,
      );
      PasswordSecret passphrase() => SodiumPasswordSecret.fromUtf8Bytes(
        sodium,
        Uint8List.fromList(utf8.encode('passphrase del vault')),
      );

      final first = sqlite3.open(path);
      final created = await keeperOn(first).create(passphrase());
      await created.engine.write(
        note,
        RevisionContents(utf8.encode('Testo segreto')),
      );
      created.lock();
      first.close();

      final onDisk = latin1.decode([
        for (final file in directory.listSync().whereType<File>())
          ...file.readAsBytesSync(),
      ]);
      expect(onDisk, isNot(contains('segreto')));
      expect(onDisk, isNot(contains('passphrase')));

      final second = sqlite3.open(path);
      addTearDown(second.close);
      final unlocked = await keeperOn(second).unlock(passphrase());
      addTearDown(unlocked.lock);

      expect(unlocked.member, created.member);
      expect(
        (await unlocked.engine.records()).map(
          (id, body) => MapEntry(id, utf8.decode(body.bytes)),
        ),
        {note: 'Testo segreto'},
      );
    },
  );
}
