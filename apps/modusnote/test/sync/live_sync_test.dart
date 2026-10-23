import 'package:flutter_test/flutter_test.dart';
import 'package:modusnote/sync/live_link.dart';
import 'package:modusnote/sync/sync_controller.dart';
import 'package:modusnote/vault/vault_note_store.dart';
import 'package:offline_sync/offline_sync.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import '../vault/support.dart';
import '../vault/vault_note_store_test.dart' show first, quickNote;
import 'cloud_support.dart';
import 'live_link_test.dart' show FakeLiveChannel, wait;

const timings = LiveTimings(
  throttle: Duration(milliseconds: 40),
  settled: Duration(milliseconds: 100),
  firstRetry: Duration(milliseconds: 5),
  firstRetryLimit: Duration(milliseconds: 10),
  longestRetry: Duration(milliseconds: 40),
);

void main() {
  setUpAll(loadSodium);

  late MemorySyncServer server;
  late FakeLiveChannel channel;
  late UnlockedVault vault;
  late VaultNoteStore store;

  setUp(() async {
    server = MemorySyncServer();
    channel = FakeLiveChannel();
    final database = memoryDatabase();
    addTearDown(database.close);
    vault = await keeperOn(
      database,
      gateway: server,
    ).create(passphrase('frase lunga'));
    addTearDown(vault.lock);
    store = await VaultNoteStore.open(
      vault.engine,
      catalog: SeedSchemas.catalog,
    );
  });

  SyncController controller({
    bool enabled = true,
    Duration interval = const Duration(hours: 1),
    Duration livePolling = const Duration(hours: 1),
  }) {
    final sync = SyncController(
      engine: vault.engine,
      onPulled: store.reload,
      enabled: enabled,
      interval: interval,
      live: channel.connect,
      liveTimings: timings,
      livePolling: livePolling,
    );
    addTearDown(sync.dispose);
    return sync;
  }

  test('opens after the first sync of the unlock reached the server', () async {
    server.online = false;
    final sync = controller()..start();
    await wait(20);
    expect(channel.connections, isEmpty, reason: 'nothing synced yet');

    server.online = true;
    await sync.syncNow();
    await sync.syncNow();

    expect(channel.connections, hasLength(1));
  });

  test('never opens while the sync is off', () async {
    final sync = controller(enabled: false)..start();
    await wait(20);
    await sync.syncNow();

    expect(channel.connections, isEmpty);
  });

  test('a change on the server syncs at once', () async {
    final sync = controller()..start();
    await wait(20);
    channel.open();
    await wait(5);
    final before = server.headsAsked;

    channel.changed();
    await wait(20);

    expect(server.headsAsked, before + 1);
    expect(sync.state, SyncState.synced);
  });

  test('while the channel is open the periodic check runs seldom, and as '
      'before once it closes', () async {
    final sync = controller(interval: const Duration(milliseconds: 10))
      ..start();
    await wait(20);
    channel.open();
    await wait(5);
    expect(sync.liveOpen, isTrue);
    final before = server.headsAsked;

    await wait(120);
    expect(server.headsAsked, before, reason: 'the channel says it instead');

    sync.pause();
    expect(sync.liveOpen, isFalse);
    await wait(120);
    expect(server.headsAsked, greaterThan(before));
  });

  test('a device the server no longer admits closes the channel', () async {
    final sync = controller()..start();
    await wait(20);
    channel.open();
    await wait(5);
    server.membershipLog.clear();

    await channel.close(LiveClosed.removed);
    await wait(60);

    expect(sync.problem, SyncProblem.notAdmitted);
    expect(channel.connections, hasLength(1));
  });

  test('a later sync that is not admitted closes an open channel', () async {
    final sync = controller()..start();
    await wait(20);
    channel.open();
    await wait(5);
    server.membershipLog.clear();

    await sync.syncNow();

    expect(sync.problem, SyncProblem.notAdmitted);
    expect(channel.cancelled, 1);
    expect(sync.liveOpen, isFalse);
  });

  test('deleting the vault from the server closes the channel', () async {
    final sync = controller()..start();
    await wait(20);
    channel.open();
    await wait(5);

    await sync.deleteFromServer();

    expect(channel.cancelled, 1);
    await wait(60);
    expect(channel.connections, hasLength(1));
  });

  test('the background closes the channel and the return opens it', () async {
    final sync = controller()..start();
    await wait(20);
    channel.open();

    sync.pause();
    sync.resume();

    expect(channel.cancelled, 1);
    expect(channel.connections, hasLength(2));
  });

  test('disposing closes the channel before the keys go', () async {
    final sync = SyncController(
      engine: vault.engine,
      onPulled: store.reload,
      enabled: true,
      live: channel.connect,
      liveTimings: timings,
    )..start();
    await store.save(quickNote(first, 'Prima', DateTime.utc(2026)));
    await wait(20);
    channel.open();

    sync.dispose();

    expect(channel.cancelled, 1);
  });
}
