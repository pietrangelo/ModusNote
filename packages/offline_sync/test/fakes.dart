import 'package:collaboration_access_control/collaboration_access_control.dart';
import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:offline_sync/offline_sync.dart';

/// The zero-knowledge server: append-only logs of opaque rows, membership
/// records and key bundles. It can be switched off to simulate no network.
final class FakeSyncServer implements SyncServer {
  var online = true;
  final rows = <SealedRow>[];
  final membershipLog = <MembershipRecord>[];
  final bundles = <KeyBundle>[];

  /// How many membership records it admits to having (for rollback tests).
  int? withholdMembershipAfter;

  final createdWorkspaces = <WorkspaceId>[];

  /// What clients asked of it, in order: `workspace`, `membership <n>`,
  /// `push <rows>`.
  final calls = <String>[];

  /// Fails the next call to [appendMembership] as if the network dropped.
  var dropNextAppend = false;

  /// Fails the next call to [appendKeyBundle] as if the network dropped.
  var dropNextBundle = false;

  void _check() {
    if (!online) throw const ServerUnavailableException();
  }

  @override
  Future<void> push(WorkspaceId workspace, List<SealedRow> rows) async {
    _check();
    calls.add('push ${rows.length}');
    this.rows.addAll(rows);
  }

  @override
  Future<void> createWorkspace(WorkspaceId workspace) async {
    _check();
    calls.add('workspace');
    if (!createdWorkspaces.contains(workspace)) {
      createdWorkspaces.add(workspace);
    }
  }

  @override
  Future<void> appendMembership(MembershipRecord record) async {
    _check();
    if (dropNextAppend) {
      dropNextAppend = false;
      throw const ServerUnavailableException();
    }
    calls.add('membership ${record.sequence}');
    // The real table's primary key: a sequence is written once.
    if (record.sequence != membershipLog.length) {
      throw StateError('membership sequence ${record.sequence} taken');
    }
    membershipLog.add(record);
  }

  @override
  Future<List<PulledRow>> pull(
    WorkspaceId workspace, {
    required int after,
  }) async {
    _check();
    return [
      for (var i = after; i < rows.length; i++)
        PulledRow(cursor: i + 1, row: rows[i]),
    ];
  }

  @override
  Future<List<MembershipRecord>> membership(
    WorkspaceId workspace, {
    required int from,
  }) async {
    _check();
    final visible = withholdMembershipAfter == null
        ? membershipLog
        : membershipLog.take(withholdMembershipAfter!).toList();
    return from >= visible.length ? const [] : visible.sublist(from);
  }

  @override
  Future<List<(int, KeyBundle)>> keyBundles(
    WorkspaceId workspace, {
    required int after,
  }) async {
    _check();
    return [for (var i = after; i < bundles.length; i++) (i + 1, bundles[i])];
  }

  @override
  Future<void> appendKeyBundle(KeyBundle bundle) async {
    _check();
    if (dropNextBundle) {
      dropNextBundle = false;
      throw const ServerUnavailableException();
    }
    calls.add('bundle');
    bundles.add(bundle);
  }
}

/// Where two devices of one account meet: whatever they post, it relays.
final class FakeLinkChannel implements DeviceLinkChannel {
  var online = true;
  final offers = <LinkOffer>[];
  final posted = <LinkAnswer>[];
  final closed = <LinkId>[];

  void _check() {
    if (!online) throw const ServerUnavailableException();
  }

  @override
  Future<void> postOffer(LinkOffer offer) async {
    _check();
    offers.add(offer);
  }

  @override
  Future<LinkOffer?> latestOffer() async {
    _check();
    return offers.lastOrNull;
  }

  @override
  Future<void> postAnswer(LinkAnswer answer) async {
    _check();
    posted.add(answer);
  }

  @override
  Future<List<LinkAnswer>> answers(LinkId link) async {
    _check();
    return [...posted.where((answer) => answer.id == link)];
  }

  @override
  Future<void> close(LinkId link) async {
    _check();
    closed.add(link);
  }
}

/// The local database: it is handed only sealed records and rows.
final class FakeLocalStore implements LocalRecordStore {
  final records = <RecordId, EncryptedEnvelope>{};
  var outbox = Outbox.empty;
  final cursors = <SyncStream, int>{};

  @override
  Future<EncryptedEnvelope?> load(RecordId id) async => records[id];

  @override
  Future<List<RecordId>> recordIds() async => [...records.keys];

  @override
  Future<void> save(RecordId id, EncryptedEnvelope sealed) async =>
      records[id] = sealed;

  @override
  Future<Outbox> loadOutbox() async => outbox;

  @override
  Future<void> saveOutbox(Outbox outbox) async => this.outbox = outbox;

  @override
  Future<int> loadCursor(SyncStream stream) async => cursors[stream] ?? 0;

  @override
  Future<void> saveCursor(SyncStream stream, int cursor) async =>
      cursors[stream] = cursor;
}

final class FakeClock implements Clock {
  FakeClock(this.current);

  DateTime current;

  @override
  DateTime now() => current;

  void advance([Duration by = const Duration(minutes: 1)]) =>
      current = current.add(by);
}

/// Where the vault header and its signed log live on the device.
final class FakeVaultStore implements VaultStore {
  VaultHeader? header;
  PasskeySlot? passkey;
  final settings = <String, EncryptedEnvelope>{};
  final membership = <MembershipRecord>[];
  final bundles = <KeyBundle>[];

  @override
  Future<VaultHeader?> loadHeader() async => header;

  @override
  Future<void> create(
    VaultHeader header, {
    required List<MembershipRecord> membership,
    required List<KeyBundle> bundles,
  }) async {
    this.header = header;
    this.membership.addAll(membership);
    this.bundles.addAll(bundles);
  }

  @override
  Future<List<MembershipRecord>> loadMembership() async => [...membership];

  @override
  Future<List<KeyBundle>> loadKeyBundles() async => [...bundles];

  @override
  Future<void> appendMembership(List<MembershipRecord> records) async {
    for (final record in records) {
      if (record.sequence == membership.length) membership.add(record);
    }
  }

  @override
  Future<void> appendKeyBundles(List<KeyBundle> bundles) async =>
      this.bundles.addAll(bundles);

  @override
  Future<PasskeySlot?> loadPasskey() async => passkey;

  @override
  Future<void> savePasskey(PasskeySlot slot) async {
    if (header == null) throw const NoVaultException();
    passkey = slot;
  }

  @override
  Future<void> removePasskey() async => passkey = null;

  @override
  Future<EncryptedEnvelope?> loadSetting(String name) async => settings[name];

  @override
  Future<void> saveSetting(String name, EncryptedEnvelope? sealed) async {
    if (sealed == null) {
      settings.remove(name);
    } else {
      settings[name] = sealed;
    }
  }
}
