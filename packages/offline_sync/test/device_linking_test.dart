import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:collaboration_access_control/collaboration_access_control.dart';
import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:identity_cryptography_adapters/identity_cryptography_adapters.dart';
import 'package:offline_sync/offline_sync.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:test/test.dart';

import 'fakes.dart';
import 'vault_passkey_test.dart' as passkey_test show FakePasskeyPrf, sodium;

late SodiumSumo sodium;

PasswordSecret secret(List<int> utf8Bytes) =>
    SodiumPasswordSecret.fromUtf8Bytes(sodium, Uint8List.fromList(utf8Bytes));

PasswordSecret password(String text) => secret(utf8.encode(text));

Uint8List bytes(String text) => Uint8List.fromList(utf8.encode(text));

/// One device: its own disk, and the server it reaches.
final class Device {
  Device(this.server, this.invites, this.clock, {this.prf});

  final PasskeyPrf? prf;
  final FakeInviteChannel invites;
  final FakeSyncServer server;
  final FakeClock clock;
  final vaults = FakeVaultStore();
  final records = <WorkspaceId, FakeLocalStore>{};
  late final gateway = FakeGateway(server, invites);

  VaultKeeper get keeper => VaultKeeper(
    vaults: vaults,
    records: (workspace) => records.putIfAbsent(workspace, FakeLocalStore.new),
    identities: SodiumIdentityService(sodium),
    hasher: SodiumContentHasher(sodium),
    keys: SodiumKeyDerivationService(sodium),
    subkeys: SodiumSubkeyDerivationService(sodium),
    envelopes: SodiumEnvelopeEncryptor(sodium),
    encapsulation: SodiumKeyEncapsulation(sodium),
    clock: clock,
    random: Random.secure(),
    kdf: KdfParameters.interactive,
    passkeys: prf,
    gateway: gateway,
  );
}

Future<String?> read(UnlockedVault vault, RecordId id) async =>
    switch (await vault.engine.read(id)) {
      RevisionContents(:final bytes) => utf8.decode(bytes),
      _ => null,
    };

void main() {
  late FakeSyncServer server;
  late FakeInviteChannel invites;
  late FakeClock clock;
  late Device phone;
  late Device browser;
  late UnlockedVault founder;
  final note = RecordId.parse('0123456789abcdef0123456789abcdef');
  final other = RecordId.parse('fedcba9876543210fedcba9876543210');

  setUpAll(() async {
    sodium = await SodiumSumoInit.init();
    passkey_test.sodium = sodium;
  });

  setUp(() async {
    server = FakeSyncServer();
    invites = FakeInviteChannel();
    clock = FakeClock(DateTime.utc(2026, 10, 13, 12));
    phone = Device(server, invites, clock);
    browser = Device(server, invites, clock);
    founder = await phone.keeper.create(password('frase del telefono'));
    addTearDown(founder.lock);
    await founder.engine.write(note, RevisionContents(bytes('dal telefono')));
    await founder.engine.sync();
  });

  final code = InviteCode.tryParse('K7MQ4X-T9ABC-D2EFG')!;

  /// Brings in another device of the owner's, as the owner.
  Future<InviteOffering> offer([UnlockedVault? from, Device? on]) =>
      (on ?? phone).keeper.offerInvite(
        from ?? founder,
        secret(code.toBytes()),
        lookup: code.lookup,
        role: Role.owner,
      );

  Future<LinkRequest> join(Device device, {InviteCode? typed}) =>
      device.keeper.acceptInvite(
        code: secret((typed ?? code).toBytes()),
        lookup: (typed ?? code).lookup,
        passphrase: password('frase del browser'),
      );

  /// Both sides of a link, the way the two screens drive it.
  Future<UnlockedVault> link(Device device, {UnlockedVault? from}) async {
    final offering = await offer(from);
    final request = await join(device);
    expect(await offering.poll(), isNotNull);
    final vault = await request.poll();
    addTearDown(() => vault?.lock());
    return vault!;
  }

  test('a device that types the code joins and reads the notes', () async {
    final joined = await link(browser);

    await joined.engine.sync();

    expect(joined.workspace, founder.workspace);
    expect(joined.member, isNot(founder.member));
    expect(await read(joined, note), 'dal telefono');
  });

  test('both devices write and read each other\'s notes', () async {
    final joined = await link(browser);
    await joined.engine.write(other, RevisionContents(bytes('dal browser')));
    await joined.engine.sync();

    await founder.engine.sync();

    expect(await read(founder, other), 'dal browser');
  });

  test('the new device is an owner, admitted by a signed record', () async {
    final joined = await link(browser);

    final workspace = founder.engine.ledger.workspace;
    expect(workspace.member(joined.member)?.role, Role.owner);
    expect(server.membershipLog, hasLength(2));
    expect(server.membershipLog.last.author, founder.member);
  });

  test('the joining device waits until it is admitted', () async {
    final offering = await offer();
    final request = await join(browser);
    addTearDown(request.cancel);

    expect(await request.poll(), isNull);
    expect(browser.vaults.header, isNull);

    expect(await offering.poll(), isNotNull);
    final vault = await request.poll();
    addTearDown(() => vault?.lock());
    expect(vault, isNotNull);
  });

  test('adversary: a bundle naming a record the server does not have does not '
      'hold back joining', () async {
    final offering = await offer();
    final request = await join(browser);
    addTearDown(request.cancel);
    server.bundles.add(forgedBundle(founder.workspace, founder.member));

    expect(await offering.poll(), isNotNull);
    final vault = await request.poll();
    addTearDown(() => vault?.lock());

    expect(vault, isNotNull);
  });

  test('the founder waits until the device answers', () async {
    final offering = await offer();
    addTearDown(offering.cancel);

    expect(await offering.poll(), isNull);
    expect(server.membershipLog, hasLength(1));
  });

  test('the joined vault reopens offline with its own passphrase', () async {
    final joined = await link(browser);
    await joined.engine.sync();
    joined.lock();
    server.online = false;

    final reopened = await browser.keeper.unlock(password('frase del browser'));
    addTearDown(reopened.lock);
    await reopened.engine.write(other, RevisionContents(bytes('in treno')));

    expect(reopened.member, joined.member);
    expect(await read(reopened, note), 'dal telefono');
    expect(
      () => browser.keeper.unlock(password('frase del telefono')),
      throwsA(isA<WrongPassphraseException>()),
    );
  });

  test(
    'the founder remembers the new member after reopening offline',
    () async {
      final joined = await link(browser);
      founder.lock();
      server.online = false;

      final reopened = await phone.keeper.unlock(
        password('frase del telefono'),
      );
      addTearDown(reopened.lock);

      expect(reopened.engine.ledger.workspace.isMember(joined.member), isTrue);
    },
  );

  test(
    'members learned after joining are kept for reopening offline',
    () async {
      final joined = await link(browser);
      final third = await link(Device(server, invites, clock));
      await joined.engine.sync();
      joined.lock();
      third.lock();
      server.online = false;

      final reopened = await browser.keeper.unlock(
        password('frase del browser'),
      );
      addTearDown(reopened.lock);

      expect(reopened.engine.ledger.records, hasLength(3));
    },
  );

  test('a joined device unlocks with a passkey of its own', () async {
    final authenticator = passkey_test.FakePasskeyPrf();
    final laptop = Device(server, invites, clock, prf: authenticator);
    final joined = await link(laptop);
    await laptop.keeper.enrollPasskey(joined);
    joined.lock();

    final reopened = await laptop.keeper.unlockWithPasskey();
    addTearDown(reopened.lock);

    expect(reopened.member, joined.member);
  });

  test('a linked device can link one more', () async {
    final joined = await link(browser);
    final tablet = Device(server, invites, clock);

    final offering = await offer(joined, browser);
    final request = await join(tablet);
    expect(await offering.poll(), isNotNull);
    final third = await request.poll();
    addTearDown(() => third?.lock());
    await third!.engine.sync();

    expect(await read(third, note), 'dal telefono');
    expect(server.membershipLog.last.author, joined.member);
  });

  test('an admission cut short completes on the next poll', () async {
    final offering = await offer();
    final request = await join(browser);
    addTearDown(request.cancel);
    server.dropNextBundle = true;

    await expectLater(
      offering.poll(),
      throwsA(isA<ServerUnavailableException>()),
    );
    expect(await request.poll(), isNull);
    expect(await offering.poll(), isNotNull);
    final vault = await request.poll();
    addTearDown(() => vault?.lock());

    expect(vault, isNotNull);
    expect(server.membershipLog, hasLength(2));
  });

  test('the code is cleared from the server once used', () async {
    await link(browser);

    expect(invites.closed, [code.lookup]);
  });

  test('a device that already has a vault cannot join', () async {
    await offer();

    await expectLater(join(phone), throwsA(isA<VaultAlreadyExistsException>()));
  });

  group('revocation', () {
    final later = RecordId.parse('00112233445566778899aabbccddeeff');

    test('a removed device leaves the log and the epoch moves on', () async {
      final joined = await link(browser);

      await founder.engine.revoke(joined.member);

      final workspace = founder.engine.ledger.workspace;
      expect(workspace.isMember(joined.member), isFalse);
      expect(workspace.epoch, KeyEpoch(1));
      expect(server.membershipLog, hasLength(3));
      expect(server.membershipLog.last.change, MemberRevoked(joined.member));
      expect(server.bundles.last.grants.map((grant) => grant.recipient), [
        founder.member,
      ]);
    });

    test('notes written afterwards reach only those who remain', () async {
      final joined = await link(browser);
      final tablet = Device(server, invites, clock);
      final removed = await link(tablet);
      await joined.engine.sync();
      await removed.engine.sync();

      await founder.engine.revoke(removed.member);
      await founder.engine.write(later, RevisionContents(bytes('segreto')));
      await founder.engine.sync();

      await joined.engine.sync();
      expect(await read(joined, later), 'segreto');
      await expectLater(
        removed.engine.sync(),
        throwsA(isA<RemovedFromWorkspaceException>()),
      );
      expect(removed.engine.removed, isTrue);
      expect(server.rows.last.ciphertext.epoch, KeyEpoch(1));
      expect(
        () => removed.engine.contentKeyFor(KeyEpoch(1)),
        throwsA(isA<MissingGroupKeyException>()),
      );
      expect(await read(removed, later), isNull);
      expect(await read(removed, note), 'dal telefono');
    });

    test('a removed device can no longer write', () async {
      final joined = await link(browser);
      await founder.engine.revoke(joined.member);
      await expectLater(
        joined.engine.sync(),
        throwsA(isA<RemovedFromWorkspaceException>()),
      );

      await expectLater(
        joined.engine.write(other, RevisionContents(bytes('ancora io'))),
        throwsA(isA<NotAuthorizedException>()),
      );
      await expectLater(
        joined.engine.sync(),
        throwsA(isA<RemovedFromWorkspaceException>()),
      );
    });

    test('an edit written before it learned of its removal never reaches '
        'the others', () async {
      final joined = await link(browser);
      await joined.engine.sync();
      await founder.engine.revoke(joined.member);
      final held = server.rows.length;
      await joined.engine.write(note, RevisionContents(bytes('sovrascritto')));

      // The server refuses the push; the device learns why from the log.
      await expectLater(
        joined.engine.sync(),
        throwsA(isA<RemovedFromWorkspaceException>()),
      );

      expect(server.rows, hasLength(held));
      await founder.engine.sync();
      expect(await read(founder, note), 'dal telefono');
    });

    test(
      'the server lets a removed device read the log, nothing else',
      () async {
        final joined = await link(browser);
        await founder.engine.revoke(joined.member);
        final reached = browser.gateway.server(joined.signer);

        await expectLater(
          reached.heads(joined.workspace),
          throwsA(isA<NotAdmittedException>()),
        );
        expect(await reached.membership(joined.workspace, from: 2), [
          isA<MembershipRecord>(),
        ]);
      },
    );

    test('a device the server shuts out, for no reason the log shows, '
        'is told so', () async {
      final joined = await link(browser);
      // The server forgets the device's admission, on its own word.
      server.membershipLog.removeLast();

      await expectLater(
        joined.engine.sync(),
        throwsA(isA<NotAdmittedException>()),
      );
      expect(joined.engine.removed, isFalse);
    });

    test('an owner deletes the workspace from the server, '
        'and every device keeps its notes', () async {
      final joined = await link(browser);
      await joined.engine.sync();

      await founder.engine.deleteFromServer();

      expect(server.deleted, isTrue);
      expect(await read(founder, note), 'dal telefono');
      expect(await read(joined, note), 'dal telefono');
    });

    test('only an owner deletes the workspace from the server', () async {
      final viewer = await (() async {
        final offering = await phone.keeper.offerInvite(
          founder,
          secret(code.toBytes()),
          lookup: code.lookup,
          role: Role.viewer,
        );
        final request = await join(browser);
        expect(await offering.poll(), isNotNull);
        final vault = (await request.poll())!;
        addTearDown(vault.lock);
        return vault;
      })();

      await expectLater(
        viewer.engine.deleteFromServer(),
        throwsA(isA<NotAuthorizedException>()),
      );
      expect(server.deleted, isFalse);
    });

    test('this device cannot remove itself', () async {
      await link(browser);

      expect(
        () => founder.engine.revoke(founder.member),
        throwsA(isA<InvalidMembershipChangeException>()),
      );
    });

    test('offline, nothing changes', () async {
      final joined = await link(browser);
      server.online = false;

      await expectLater(
        founder.engine.revoke(joined.member),
        throwsA(isA<ServerUnavailableException>()),
      );

      expect(founder.engine.ledger.workspace.isMember(joined.member), isTrue);
      expect(phone.vaults.membership, hasLength(2));
    });

    test('a key bundle that did not go out is sent by the next sync, '
        'even after locking', () async {
      final joined = await link(browser);
      await joined.engine.sync();
      final tablet = Device(server, invites, clock);
      final removed = await link(tablet);
      server.dropNextBundle = true;

      await expectLater(
        founder.engine.revoke(removed.member),
        throwsA(isA<ServerUnavailableException>()),
      );
      expect(founder.engine.ledger.workspace.isMember(removed.member), isFalse);
      founder.lock();
      final reopened = await phone.keeper.unlock(
        password('frase del telefono'),
      );
      addTearDown(reopened.lock);
      await reopened.engine.write(later, RevisionContents(bytes('dopo')));
      await reopened.engine.sync();

      await joined.engine.sync();
      expect(await read(joined, later), 'dopo');
      expect(
        server.bundles.last.grants.map((grant) => grant.recipient),
        unorderedEquals([founder.member, joined.member]),
      );
    });

    test('the new key survives reopening offline', () async {
      final joined = await link(browser);
      await founder.engine.revoke(joined.member);
      founder.lock();
      server.online = false;

      final reopened = await phone.keeper.unlock(
        password('frase del telefono'),
      );
      addTearDown(reopened.lock);
      await reopened.engine.write(later, RevisionContents(bytes('offline')));

      expect(reopened.engine.currentEpoch, KeyEpoch(1));
      expect(await read(reopened, later), 'offline');
    });

    test('a linked device can remove the one that linked it', () async {
      final joined = await link(browser);

      await joined.engine.revoke(founder.member);

      await expectLater(
        founder.engine.sync(),
        throwsA(isA<RemovedFromWorkspaceException>()),
      );
      expect(joined.engine.removed, isFalse);
    });
  });

  group('invites', () {
    final inviteCode = InviteCode.tryParse('M3PQ8Z-T9ABC-D2EFG')!;
    late Device friend;

    setUp(() => friend = Device(server, invites, clock));

    Future<InviteOffering> invite({Role role = Role.editor}) =>
        phone.keeper.offerInvite(
          founder,
          secret(inviteCode.toBytes()),
          lookup: inviteCode.lookup,
          role: role,
        );

    Future<LinkRequest> accept({InviteCode? typed}) {
      final code = typed ?? inviteCode;
      return friend.keeper.acceptInvite(
        code: secret(code.toBytes()),
        lookup: code.lookup,
        passphrase: password('frase di Bea'),
      );
    }

    Future<UnlockedVault> joined({Role role = Role.editor}) async {
      final offering = await invite(role: role);
      final request = await accept();
      expect(await offering.poll(), isNotNull);
      final vault = await request.poll();
      addTearDown(() => vault?.lock());
      return vault!;
    }

    test('an invited person joins with the code and reads the notes', () async {
      final bea = await joined();
      await bea.engine.sync();

      expect(bea.workspace, founder.workspace);
      expect(await read(bea, note), 'dal telefono');
      expect(invites.closed, [inviteCode.lookup]);
    });

    test('the person gets the role chosen', () async {
      final bea = await joined();

      final member = founder.engine.ledger.workspace.member(bea.member);
      expect(member?.role, Role.editor);
    });

    test('an editor writes and the owner reads it', () async {
      final bea = await joined();
      await bea.engine.write(other, RevisionContents(bytes('da Bea')));
      await bea.engine.sync();

      await founder.engine.sync();

      expect(await read(founder, other), 'da Bea');
    });

    test('a reader reads but cannot write', () async {
      final bea = await joined(role: Role.viewer);
      await bea.engine.sync();

      expect(await read(bea, note), 'dal telefono');
      await expectLater(
        bea.engine.write(other, RevisionContents(bytes('da Bea'))),
        throwsA(isA<NotAuthorizedException>()),
      );
    });

    test('an invited owner may bring in devices in turn', () async {
      final bea = await joined(role: Role.owner);
      final third = Device(server, invites, clock);

      final offering = await offer(bea, friend);
      final request = await join(third);
      expect(await offering.poll(), isNotNull);
      final vault = await request.poll();
      addTearDown(() => vault?.lock());

      expect(vault, isNotNull);
      expect(server.membershipLog.last.author, bea.member);
    });

    test('removing the person shuts their device out', () async {
      final bea = await joined();

      await founder.engine.revoke(bea.member);

      await expectLater(
        bea.engine.sync(),
        throwsA(isA<RemovedFromWorkspaceException>()),
      );
    });

    test('a lookup held by an open offer is refused', () async {
      final offering = await invite();
      addTearDown(offering.cancel);

      await expectLater(invite(), throwsA(isA<LookupTakenException>()));
    });

    group('adversary', () {
      test('a wrong code opens nothing and posts nothing', () async {
        final offering = await invite();
        addTearDown(offering.cancel);
        final wrong = InviteCode.tryParse('M3PQ8Z-T9ABC-D2EFH')!;

        await expectLater(
          accept(typed: wrong),
          throwsA(isA<LinkCodeRejectedException>()),
        );
        expect(invites.posted, isEmpty);
        expect(friend.vaults.header, isNull);
      });

      test('an answer sealed without the code admits no one', () async {
        final offering = await invite();
        addTearDown(offering.cancel);
        final intruder = SodiumIdentityService(sodium).generateIdentity();
        addTearDown(intruder.dispose);
        final envelopes = SodiumEnvelopeEncryptor(sodium);
        final guess = envelopes.generateKey();
        addTearDown(guess.dispose);
        invites.posted.add(
          InviteAnswer(
            lookup: inviteCode.lookup,
            sealedJoiner: envelopes.seal(
              InviteAnswer.joiner(intruder.publicIdentity),
              key: guess,
              associatedData: InviteAnswer.associatedData(inviteCode.lookup),
            ),
          ),
        );

        expect(await offering.poll(), isNull);
        expect(server.membershipLog, hasLength(1));
      });

      test(
        'the server learns the lookup, never the rest of the code',
        () async {
          final offering = await invite();
          addTearDown(offering.cancel);
          await accept().then((request) => addTearDown(request.cancel));

          final secretPart = String.fromCharCodes(
            inviteCode.toBytes().sublist(InviteCode.lookupLength),
          );
          for (final wire in [
            ...invites.offers.map((offer) => offer.toBytes()),
            ...invites.posted.map((answer) => answer.toBytes()),
          ]) {
            expect(String.fromCharCodes(wire), isNot(contains(secretPart)));
          }
        },
      );

      test('an expired invitation admits no one', () async {
        final offering = await invite();
        await accept().then((request) => addTearDown(request.cancel));
        clock.advance(VaultKeeper.linkLifetime);

        await expectLater(
          offering.poll(),
          throwsA(isA<LinkExpiredException>()),
        );
        expect(server.membershipLog, hasLength(1));
      });
    });
  });

  group('adversary', () {
    test('a mistyped code opens nothing and posts nothing', () async {
      final offering = await offer();
      addTearDown(offering.cancel);

      await expectLater(
        join(browser, typed: InviteCode.tryParse('K7MQ4X-T9ABC-D2EFH')),
        throwsA(isA<LinkCodeRejectedException>()),
      );
      expect(invites.posted, isEmpty);
    });

    test('with no offer the code is simply wrong', () async {
      await expectLater(
        join(browser),
        throwsA(isA<LinkCodeRejectedException>()),
      );
    });

    test('an answer sealed without the code admits no one', () async {
      final offering = await offer();
      addTearDown(offering.cancel);
      invites.posted.add(
        InviteAnswer(
          lookup: code.lookup,
          sealedJoiner: EncryptedEnvelope(
            nonce: Nonce.fromBytes(List.filled(Nonce.length, 1)),
            ciphertext: List.filled(
              PublicIdentity.length + EncryptedEnvelope.tagLength,
              2,
            ),
          ),
        ),
      );

      expect(await offering.poll(), isNull);
      expect(server.membershipLog, hasLength(1));
    });

    test('a forged answer does not block the genuine one', () async {
      final offering = await offer();
      invites.posted.add(
        InviteAnswer(
          lookup: code.lookup,
          sealedJoiner: EncryptedEnvelope(
            nonce: Nonce.fromBytes(List.filled(Nonce.length, 1)),
            ciphertext: List.filled(
              PublicIdentity.length + EncryptedEnvelope.tagLength,
              2,
            ),
          ),
        ),
      );
      final request = await join(browser);

      expect(await offering.poll(), isNotNull);
      final vault = await request.poll();
      addTearDown(() => vault?.lock());
      expect(vault, isNotNull);
    });

    test(
      'an offer swapped by the server does not open with the code',
      () async {
        final offering = await offer();
        addTearDown(offering.cancel);
        // The server re-posts the offer under a code it chose.
        final stranger = Device(FakeSyncServer(), FakeInviteChannel(), clock);
        final theirs = await stranger.keeper.create(password('altra frase'));
        addTearDown(theirs.lock);
        final swapped = await stranger.keeper.offerInvite(
          theirs,
          secret(InviteCode.tryParse('K7MQ4X-ZZZZZ-ZZZZZ')!.toBytes()),
          lookup: code.lookup,
          role: Role.owner,
        );
        addTearDown(swapped.cancel);
        invites.offers.add(stranger.invites.offers.single);

        await expectLater(
          join(browser),
          throwsA(isA<LinkCodeRejectedException>()),
        );
      },
    );

    test('a log not founded by the offer\'s founder is refused', () async {
      final offering = await offer();
      addTearDown(offering.cancel);
      // The joining device asks a server that holds someone else's log.
      final hostile = FakeSyncServer();
      final stranger = Device(hostile, FakeInviteChannel(), clock);
      (await stranger.keeper.create(password('altra frase'))).lock();
      final theirs = await stranger.keeper.unlock(password('altra frase'));
      await theirs.engine.sync();
      theirs.lock();
      final joining = Device(hostile, invites, clock);
      // It answers whoever asks.
      joining.gateway.checks = false;
      final request = await joining.keeper.acceptInvite(
        code: secret(code.toBytes()),
        lookup: code.lookup,
        passphrase: password('frase del browser'),
      );
      addTearDown(request.cancel);

      await expectLater(
        request.poll(),
        throwsA(isA<TamperedWorkspaceDataException>()),
      );
    });

    test('a code is good for ten minutes on both devices', () async {
      final offering = await offer();
      final request = await join(browser);
      clock.advance(VaultKeeper.linkLifetime);

      await expectLater(offering.poll(), throwsA(isA<LinkExpiredException>()));
      await expectLater(request.poll(), throwsA(isA<LinkExpiredException>()));
      expect(offering.isClosed, isTrue);
      expect(request.isClosed, isTrue);
      expect(server.membershipLog, hasLength(1));
    });

    test('a cancelled request keeps nothing', () async {
      final offering = await offer();
      final request = await join(browser);
      await offering.poll();

      request.cancel();

      await expectLater(request.poll(), throwsA(isA<LinkExpiredException>()));
      expect(browser.vaults.header, isNull);
    });

    test('a locked vault admits no one', () async {
      final offering = await offer();
      await join(browser);
      founder.lock();

      await expectLater(offering.poll(), throwsA(isA<VaultLockedException>()));
      expect(server.membershipLog, hasLength(1));
    });

    test('the server sees the lookup and ciphertext only', () async {
      final offering = await offer();
      final request = await join(browser);
      addTearDown(request.cancel);
      addTearDown(offering.cancel);

      final posted = [
        invites.offers.single.toBytes(),
        invites.posted.single.toBytes(),
      ];
      final workspace = founder.workspace.bytes;
      final founderKey = founder.member.signingKey.bytes;
      for (final wire in posted) {
        expect(_contains(wire, workspace), isFalse);
        expect(_contains(wire, founderKey), isFalse);
        expect(
          _contains(wire, code.toBytes().sublist(InviteCode.lookupLength)),
          isFalse,
        );
      }
    });
  });
}

bool _contains(List<int> haystack, List<int> needle) {
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    var match = true;
    for (var j = 0; j < needle.length && match; j++) {
      match = haystack[i + j] == needle[j];
    }
    if (match) return true;
  }
  return false;
}
