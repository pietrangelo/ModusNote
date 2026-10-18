import 'dart:async';
import 'dart:io';

import 'package:blob_storage_media/blob_storage_media.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modusnote/sync/sync_controller.dart';
import 'package:modusnote/vault/vault_note_store.dart';
import 'package:offline_sync/offline_sync.dart';
import 'package:offline_sync_adapters/offline_sync_adapters.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';
import 'package:sqlite3/sqlite3.dart';

import '../vault/support.dart';
import '../vault/vault_note_store_test.dart' show first, quickNote, second;
import 'cloud_support.dart';

/// One device: its vault, its notes and its sync, on [database].
final class Device {
  Device._(this.vault, this.store, this.sync);

  static Future<Device> open(
    Database database,
    SyncServer server,
    SyncAccount account, {
    bool create = false,
  }) async {
    final keeper = keeperOn(database, server: server);
    final vault = create
        ? await keeper.create(passphrase('frase lunga'))
        : await keeper.unlock(passphrase('frase lunga'));
    final store = await VaultNoteStore.open(
      vault.engine,
      catalog: SeedSchemas.catalog,
    );
    final sync = SyncController(
      engine: vault.engine,
      account: account,
      onPulled: store.reload,
      debounce: const Duration(milliseconds: 20),
      interval: const Duration(hours: 1),
    );
    store.onWrite = sync.changed;
    return Device._(vault, store, sync);
  }

  final UnlockedVault vault;
  final VaultNoteStore store;
  final SyncController sync;

  void close() {
    sync.dispose();
    vault.lock();
  }
}

Future<SyncAccount> signedIn(FakeAuthServer auth) async {
  final account = auth.account();
  account.attach(null, persist: (_) async {});
  await account.signIn('pietro@example.com', goodCode);
  return account;
}

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 60));

void main() {
  setUpAll(loadSodium);
  late FakeAuthServer auth;

  setUp(() => auth = FakeAuthServer());

  Future<(Device, MemorySyncServer)> device({bool signIn = true}) async {
    final account = signIn ? await signedIn(auth) : auth.account();
    final server = MemorySyncServer(account.accessToken);
    final database = memoryDatabase();
    addTearDown(database.close);
    final opened = await Device.open(database, server, account, create: true);
    addTearDown(opened.close);
    return (opened, server);
  }

  test('without an account nothing reaches the server', () async {
    final (phone, server) = await device(signIn: false);

    phone.sync.start();
    await phone.store.save(quickNote(first, 'Ritornello', DateTime.utc(2026)));
    await settle();

    expect(phone.sync.state, SyncState.signedOut);
    expect(server.workspaces, isEmpty);
    expect(server.rows, isEmpty);
  });

  test('a signed-in vault publishes itself as soon as it opens', () async {
    final (phone, server) = await device();

    phone.sync.start();
    await settle();

    expect(phone.sync.state, SyncState.synced);
    expect(phone.sync.lastSynced, isNotNull);
    expect(server.workspaces, [phone.vault.engine.ledger.workspace.id]);
    expect(server.membershipLog, phone.vault.engine.ledger.records);
  });

  test('edits made close together go out in one sync', () async {
    final (phone, server) = await device();
    phone.sync.start();
    await settle();
    var syncs = 0;
    phone.sync.addListener(() {
      if (phone.sync.state == SyncState.syncing) syncs++;
    });

    await phone.store.save(quickNote(first, 'Strofa', DateTime.utc(2026)));
    await phone.store.save(quickNote(second, 'Ponte', DateTime.utc(2026)));
    await settle();

    expect(syncs, 1);
    expect(server.rows, hasLength(2));
  });

  test('edits made offline go out once the server is back', () async {
    final (phone, server) = await device();
    server.online = false;
    phone.sync.start();
    await phone.store.save(quickNote(first, 'In treno', DateTime.utc(2026)));
    await settle();
    expect(phone.sync.state, SyncState.offline);

    server.online = true;
    await phone.sync.syncNow();

    expect(phone.sync.state, SyncState.synced);
    expect(server.rows, hasLength(1));
  });

  test('notes pulled from the server appear in the library', () async {
    final directory = Directory.systemTemp.createTempSync('modusnote-sync');
    addTearDown(() => directory.deleteSync(recursive: true));
    final account = await signedIn(auth);
    final server = MemorySyncServer(account.accessToken);
    // The same vault on two databases: a backup restored on a new phone.
    final phoneDb = sqlite3.open('${directory.path}/phone.sqlite');
    addTearDown(phoneDb.close);
    final phone = await Device.open(phoneDb, server, account, create: true);
    addTearDown(phone.close);
    File('${directory.path}/phone.sqlite')
        .copySync('${directory.path}/tablet.sqlite');
    final tabletDb = sqlite3.open('${directory.path}/tablet.sqlite');
    addTearDown(tabletDb.close);
    final tablet = await Device.open(tabletDb, server, account);
    addTearDown(tablet.close);

    await phone.store.save(
      quickNote(first, 'Dal telefono', DateTime.utc(2026)),
    );
    await phone.sync.syncNow();
    var redrawn = false;
    tablet.store.addListener(() => redrawn = true);
    await tablet.sync.syncNow();

    expect(redrawn, isTrue);
    expect(
      tablet.store.entries.single.valueOf(FieldKey('content')),
      const TextValue('Dal telefono'),
    );
  });

  test('signing in starts a sync, signing out stops it', () async {
    final account = auth.account();
    account.attach(null, persist: (_) async {});
    final server = MemorySyncServer(account.accessToken);
    final database = memoryDatabase();
    addTearDown(database.close);
    final phone = await Device.open(database, server, account, create: true);
    addTearDown(phone.close);
    phone.sync.start();
    await settle();
    expect(phone.sync.state, SyncState.signedOut);

    await phone.sync.signIn('pietro@example.com', goodCode);
    await settle();
    expect(phone.sync.state, SyncState.synced);
    expect(phone.sync.email, 'pietro@example.com');

    await phone.sync.signOut();
    await settle();
    expect(phone.sync.state, SyncState.signedOut);
    expect(phone.sync.lastSynced, isNull);
    expect(auth.requests, contains('/auth/v1/logout'));
  });

  test('a request during a sync makes it go round once more', () async {
    final (phone, server) = await device();
    final first = phone.sync.syncNow();
    final again = phone.sync.syncNow();
    await phone.store.save(quickNote(second, 'Coda', DateTime.utc(2026)));
    final third = phone.sync.syncNow();

    await Future.wait([first, again, third]);

    expect(identical(first, again), isTrue);
    expect(server.rows, hasLength(1));
  });

  test('the periodic sync slows down while nothing changes', () async {
    final (phone, server) = await device();
    await phone.sync.syncNow();
    final quiet = SyncController(
      engine: phone.vault.engine,
      account: await signedIn(auth),
      onPulled: phone.store.reload,
      interval: const Duration(milliseconds: 30),
    );
    addTearDown(quiet.dispose);
    final before = server.headsAsked;

    quiet.start();
    await Future<void>.delayed(const Duration(milliseconds: 375));

    // 12 ticks: once a tick would be 13 questions.
    expect(server.headsAsked - before, inInclusiveRange(3, 6));
    expect(quiet.state, SyncState.synced);
  });

  group('recordings', () {
    Future<(SyncController, MemorySyncServer)> withUploads(
      Future<void> Function() afterSync,
    ) async {
      final account = await signedIn(auth);
      final server = MemorySyncServer(account.accessToken);
      final database = memoryDatabase();
      addTearDown(database.close);
      final vault = await keeperOn(
        database,
        server: server,
      ).create(passphrase('frase lunga'));
      addTearDown(vault.lock);
      final sync = SyncController(
        engine: vault.engine,
        account: account,
        onPulled: () async {},
        afterSync: afterSync,
      );
      addTearDown(sync.dispose);
      return (sync, server);
    }

    test('go up after the notes reached the server', () async {
      late bool workspaceKnown;
      late MemorySyncServer shared;
      final (sync, server) = await withUploads(() async {
        workspaceKnown = shared.workspaces.isNotEmpty;
      });
      shared = server;

      await sync.syncNow();

      expect(workspaceKnown, isTrue);
      expect(sync.state, SyncState.synced);
    });

    test(
      'an unreachable blob storage leaves the sync offline, to retry',
      () async {
        final (sync, _) = await withUploads(
          () => Future.error(const RemoteBlobUnavailableException()),
        );

        await sync.syncNow();

        expect(sync.state, SyncState.offline);
      },
    );

    test('a blob storage that refuses the account is reported', () async {
      final (sync, _) = await withUploads(
        () => Future.error(const RemoteBlobRejectedException(403)),
      );

      await sync.syncNow();

      expect(sync.state, SyncState.failed);
      expect(sync.problem, SyncProblem.refused);
    });

    test('a blob over the size limit is reported as no space', () async {
      final (sync, _) = await withUploads(
        () => Future.error(const RemoteBlobRejectedException(413)),
      );

      await sync.syncNow();

      expect(sync.state, SyncState.failed);
      expect(sync.problem, SyncProblem.full);
    });
  });

  group('adversary', () {
    test('a server that refuses the account is reported, not retried '
        'as offline', () async {
      final (phone, server) = await device();
      server.refuseWith = 401;

      await phone.sync.syncNow();

      expect(phone.sync.state, SyncState.failed);
      expect(phone.sync.problem, SyncProblem.refused);
    });

    test('a workspace over its quota is reported as no space', () async {
      final (phone, server) = await device();
      server.refuseWith = 413;

      await phone.sync.syncNow();

      expect(phone.sync.state, SyncState.failed);
      expect(phone.sync.problem, SyncProblem.full);
    });

    test('a server holding another log under this workspace is untrusted '
        'and nothing of it is applied', () async {
      final (phone, server) = await device();
      final (stranger, _) = await device();
      server.membershipLog.addAll(stranger.vault.engine.ledger.records);

      await phone.sync.syncNow();

      expect(phone.sync.state, SyncState.failed);
      expect(phone.sync.problem, SyncProblem.untrusted);
      expect(server.rows, isEmpty);
    });

    test('a vault locked under a running sync stays quiet', () async {
      final gate = Completer<void>();
      final slow = MemorySyncServer(() async {
        await gate.future;
        return issuedToken;
      });
      final database = memoryDatabase();
      addTearDown(database.close);
      final account = await signedIn(auth);
      final locked = await Device.open(database, slow, account, create: true);
      var notified = 0;
      locked.sync.addListener(() => notified++);

      final running = locked.sync.syncNow();
      final before = notified;
      locked.close();
      gate.complete();
      await running;

      expect(notified, before);
      expect(slow.rows, isEmpty);
    });
  });

  test('the server sees the workspace id and ciphertext only', () async {
    final (phone, server) = await device();
    await phone.store.save(
      quickNote(first, 'Testo segreto della nota', DateTime.utc(2026)),
    );

    await phone.sync.syncNow();

    final row = server.rows.single;
    expect(row.record.hex, first);
    expect(
      String.fromCharCodes(row.ciphertext.toBytes()),
      isNot(contains('segreto')),
    );
  });

  test('a row from another workspace is dropped, not shown', () async {
    final (phone, server) = await device();
    phone.sync.start();
    await settle();
    server.rows.add(await _foreignRow());

    await phone.sync.syncNow();

    expect(phone.sync.state, SyncState.synced);
    expect(phone.store.entries, isEmpty);
  });
}

/// A row sealed in someone else's workspace.
Future<SealedRow> _foreignRow() async {
  final database = memoryDatabase();
  final server = MemorySyncServer(() async => issuedToken);
  final vault = await keeperOn(
    database,
    server: server,
  ).create(passphrase('frase lunga'));
  final store = await VaultNoteStore.open(
    vault.engine,
    catalog: SeedSchemas.catalog,
  );
  await store.save(quickNote(first, 'Altrui', DateTime.utc(2026)));
  await vault.engine.sync();
  vault.lock();
  database.close();
  return server.rows.single;
}
