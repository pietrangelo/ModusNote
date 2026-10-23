import 'dart:typed_data';

import 'package:collaboration_access_control/collaboration_access_control.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:identity_cryptography_adapters/identity_cryptography_adapters.dart';
import 'package:modusnote/sync/sync_controller.dart';
import 'package:offline_sync/offline_sync.dart';
import 'package:sqlite3/sqlite3.dart';

import '../sync/cloud_support.dart';
import '../vault/support.dart';

PasswordSecret secret(String text) => SodiumPasswordSecret.fromUtf8Bytes(
  sodium,
  Uint8List.fromList(text.codeUnits),
);

/// One device of a [Fleet]: its database, its open vault and its sync.
final class Member {
  Member(this.database, this.vault, this.sync);

  final Database database;
  final UnlockedVault vault;
  final SyncController sync;

  MemberId get id => vault.member;
}

/// Devices of one vault on one server in memory, admitted with invitation
/// codes as the app does, outside the UI; everything closes on tear-down.
final class Fleet {
  Fleet._(this.server, this.phone);

  final MemorySyncServer server;

  /// The founder.
  final Member phone;
  var _codes = 0;

  static Future<Fleet> found() async {
    final server = MemorySyncServer();
    final database = memoryDatabase();
    addTearDown(database.close);
    final vault = await keeperOn(
      database,
      gateway: server,
    ).create(secret('frase del telefono'));
    addTearDown(vault.lock);
    await vault.engine.sync();
    return Fleet._(server, Member(database, vault, _controller(vault)));
  }

  static SyncController _controller(UnlockedVault vault) {
    final sync = SyncController(
      engine: vault.engine,
      enabled: true,
      onPulled: () async {},
      interval: const Duration(hours: 1),
    );
    addTearDown(sync.dispose);
    return sync;
  }

  /// [owner] invites a new device with [role], and it joins.
  Future<Member> admit(Member owner, {Role role = Role.owner}) async {
    await keeperOn(
      owner.database,
      gateway: server,
    ).confirm(owner.vault, secret(_phrase(owner)));
    final code = InviteCode.tryParse('K7MQ4${_codes++}-T9ABC-D2EFG')!;
    final offering = await keeperOn(owner.database, gateway: server)
        .offerInvite(
          owner.vault,
          secret(String.fromCharCodes(code.toBytes())),
          lookup: code.lookup,
          role: role,
        );
    final database = memoryDatabase();
    addTearDown(database.close);
    final request = await keeperOn(database, gateway: server).acceptInvite(
      code: secret(String.fromCharCodes(code.toBytes())),
      lookup: code.lookup,
      passphrase: secret('frase del nuovo'),
    );
    await offering.poll();
    final vault = (await request.poll())!;
    addTearDown(vault.lock);
    _phrases[vault.member] = 'frase del nuovo';
    return Member(database, vault, _controller(vault));
  }

  final _phrases = <MemberId, String>{};

  String _phrase(Member member) => _phrases[member.id] ?? 'frase del telefono';
}

/// What `notices.json` held, as the app fetched it.
final class FakeNoticeSource implements ServiceNoticeSource {
  FakeNoticeSource(this.envelopes);

  List<Uint8List> envelopes;
  var fetches = 0;

  @override
  Future<List<Uint8List>> fetch() async {
    fetches++;
    return envelopes;
  }
}

final class FixedClock implements Clock {
  FixedClock(this.current);

  DateTime current;

  @override
  DateTime now() => current;
}

/// The operator in a test: a key the board pins, and the notices it signs,
/// all valid at [now].
final class TestOperator {
  TestOperator() : _identities = SodiumIdentityService(sodium) {
    _key = _identities.generateIdentity();
    addTearDown(_key.dispose);
  }

  static final now = DateTime.utc(2026, 10, 23, 12);

  final IdentityService _identities;
  late final IdentityKeyPair _key;

  Uint8List signed(
    int serial, {
    ServiceNoticeLevel level = ServiceNoticeLevel.info,
    Map<String, String> texts = const {'it': 'Manutenzione domenica.'},
  }) {
    final notice = ServiceNotice(
      serial: serial,
      issued: now.subtract(const Duration(days: 1)),
      expires: now.add(const Duration(days: 7)),
      level: level,
      texts: texts,
    );
    return SignedServiceNotice(
      notice: notice,
      signature: _identities.sign(notice.signable, signer: _key),
    ).toBytes();
  }

  ServiceNoticeBoard board(FakeNoticeSource source) => ServiceNoticeBoard(
    source: source,
    identities: _identities,
    keys: [
      OperatorKey(
        _key.publicIdentity.signingKey,
        notAfter: now.add(const Duration(days: 365)),
      ),
    ],
    clock: FixedClock(now),
  );
}
