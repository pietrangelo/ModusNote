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

/// One device: its own disk, the account's server and link channel.
final class Device {
  Device(
    this.server,
    this.links,
    this.clock, {
    this.prf,
    this.invites,
    AccountId? account,
  }) : account = account ?? phoneAccount;

  /// The account of the person every device here belongs to, unless told.
  static final phoneAccount = AccountId.parse(
    '00000000-0000-4000-8000-00000000000a',
  );

  final PasskeyPrf? prf;
  final FakeInviteChannel? invites;
  final AccountId account;
  final FakeSyncServer server;
  final FakeLinkChannel links;
  final FakeClock clock;
  final vaults = FakeVaultStore();
  final records = <WorkspaceId, FakeLocalStore>{};

  VaultKeeper get keeper => VaultKeeper(
    vaults: vaults,
    records: (workspace) => records.putIfAbsent(workspace, FakeLocalStore.new),
    server: server,
    identities: SodiumIdentityService(sodium),
    keys: SodiumKeyDerivationService(sodium),
    subkeys: SodiumSubkeyDerivationService(sodium),
    envelopes: SodiumEnvelopeEncryptor(sodium),
    encapsulation: SodiumKeyEncapsulation(sodium),
    clock: clock,
    random: Random.secure(),
    kdf: KdfParameters.interactive,
    links: links,
    passkeys: prf,
    invites: invites,
    accounts: FakeMemberAccounts(account),
  );
}

Future<String?> read(UnlockedVault vault, RecordId id) async =>
    switch (await vault.engine.read(id)) {
      RevisionContents(:final bytes) => utf8.decode(bytes),
      _ => null,
    };

void main() {
  late FakeSyncServer server;
  late FakeLinkChannel links;
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
    FakeMemberAccounts.reset();
    server = FakeSyncServer();
    links = FakeLinkChannel();
    clock = FakeClock(DateTime.utc(2026, 10, 13, 12));
    phone = Device(server, links, clock);
    browser = Device(server, links, clock);
    founder = await phone.keeper.create(password('frase del telefono'));
    addTearDown(founder.lock);
    await founder.engine.write(note, RevisionContents(bytes('dal telefono')));
    await founder.engine.sync();
  });

  final code = LinkCode.tryParse('K7MQ4-XT9AB')!;

  Future<LinkOffering> offer([UnlockedVault? from, Device? on]) =>
      (on ?? phone).keeper.offerLink(from ?? founder, secret(code.toBytes()));

  Future<LinkRequest> join(Device device, {LinkCode? typed}) =>
      device.keeper.join(
        code: secret((typed ?? code).toBytes()),
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
      final third = await link(Device(server, links, clock));
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
    final laptop = Device(server, links, clock, prf: authenticator);
    final joined = await link(laptop);
    await laptop.keeper.enrollPasskey(joined);
    joined.lock();

    final reopened = await laptop.keeper.unlockWithPasskey();
    addTearDown(reopened.lock);

    expect(reopened.member, joined.member);
  });

  test('a linked device can link one more', () async {
    final joined = await link(browser);
    final tablet = Device(server, links, clock);

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

  test('the link is cleared from the server once used', () async {
    final offering = await offer();
    await link(browser);

    expect(links.closed, isNotEmpty);
    expect(offering.isClosed, isFalse);
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
      final tablet = Device(server, links, clock);
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

    test('an edit pushed after removal is refused by the others', () async {
      final joined = await link(browser);
      await joined.engine.sync();
      await founder.engine.revoke(joined.member);
      // Written before it learned of its removal, sent with the next sync.
      await joined.engine.write(note, RevisionContents(bytes('sovrascritto')));
      await expectLater(
        joined.engine.sync(),
        throwsA(isA<RemovedFromWorkspaceException>()),
      );

      final report = await founder.engine.sync();

      expect(report.rejected, 1);
      expect(await read(founder, note), 'dal telefono');
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
      final tablet = Device(server, links, clock);
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
    final inviteCode = InviteCode.tryParse('K7MQ4X-T9ABC-D2EFG')!;
    final friendAccount = AccountId.parse(
      '00000000-0000-4000-8000-0000000000b0',
    );
    late FakeInviteChannel invites;
    late Device owner;
    late Device friend;
    late UnlockedVault ownerVault;

    setUp(() async {
      invites = FakeInviteChannel();
      owner = Device(server, links, clock, invites: invites);
      // The founder's vault, reopened with an invite channel.
      founder.lock();
      owner.vaults
        ..header = phone.vaults.header
        ..membership.addAll(phone.vaults.membership)
        ..bundles.addAll(phone.vaults.bundles)
        ..settings.addAll(phone.vaults.settings);
      owner.records.addAll(phone.records);
      ownerVault = await owner.keeper.unlock(password('frase del telefono'));
      addTearDown(ownerVault.lock);
      // Registering the workspace let the founder's account in.
      FakeMemberAccounts.accounts[owner.account] = true;
      friend = Device(
        server,
        FakeLinkChannel(),
        clock,
        invites: invites,
        account: friendAccount,
      );
    });

    Future<InviteOffering> invite({Role role = Role.editor}) =>
        owner.keeper.offerInvite(
          ownerVault,
          secret(inviteCode.toBytes()),
          lookup: inviteCode.lookup,
          role: role,
        );

    Future<LinkRequest> accept({InviteCode? typed}) {
      final code = typed ?? inviteCode;
      return friend.keeper.acceptInvite(
        code: secret(code.toBytes()),
        lookup: code.lookup,
        account: friendAccount,
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

      expect(bea.workspace, ownerVault.workspace);
      expect(await read(bea, note), 'dal telefono');
      expect(invites.closed, [inviteCode.lookup]);
    });

    test(
      'the person gets the role chosen, and the account is let in',
      () async {
        final bea = await joined();

        final member = ownerVault.engine.ledger.workspace.member(bea.member);
        expect(member?.role, Role.editor);
        expect(FakeMemberAccounts.accounts[friendAccount], isFalse);
        expect(FakeMemberAccounts.writers, contains(friendAccount));
        expect(FakeMemberAccounts.members[bea.member], friendAccount);
      },
    );

    test('a reader\'s account is let in to read only', () async {
      await joined(role: Role.viewer);

      expect(FakeMemberAccounts.accounts[friendAccount], isFalse);
      expect(FakeMemberAccounts.writers, isNot(contains(friendAccount)));
    });

    test('an editor writes and the owner reads it', () async {
      final bea = await joined();
      await bea.engine.write(other, RevisionContents(bytes('da Bea')));
      await bea.engine.sync();

      await ownerVault.engine.sync();

      expect(await read(ownerVault, other), 'da Bea');
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

    test('an invited owner may manage the workspace', () async {
      await joined(role: Role.owner);

      expect(FakeMemberAccounts.accounts[friendAccount], isTrue);
    });

    test('removing the person also shuts their account out', () async {
      final bea = await joined();

      await ownerVault.engine.revoke(bea.member);

      expect(FakeMemberAccounts.accounts.containsKey(friendAccount), isFalse);
      expect(FakeMemberAccounts.accounts.containsKey(owner.account), isTrue);
    });

    test('an account shut out offline is shut out by the next sync', () async {
      final bea = await joined();
      final accounts = FakeMemberAccounts(owner.account)..online = false;
      final offline = VaultKeeper(
        vaults: owner.vaults,
        records: (workspace) =>
            owner.records.putIfAbsent(workspace, FakeLocalStore.new),
        server: server,
        identities: SodiumIdentityService(sodium),
        keys: SodiumKeyDerivationService(sodium),
        subkeys: SodiumSubkeyDerivationService(sodium),
        envelopes: SodiumEnvelopeEncryptor(sodium),
        encapsulation: SodiumKeyEncapsulation(sodium),
        clock: clock,
        random: Random.secure(),
        kdf: KdfParameters.interactive,
        accounts: accounts,
      );
      ownerVault.lock();
      final reopened = await offline.unlock(password('frase del telefono'));
      addTearDown(reopened.lock);

      await expectLater(
        reopened.engine.revoke(bea.member),
        throwsA(isA<ServerUnavailableException>()),
      );
      expect(FakeMemberAccounts.accounts.containsKey(friendAccount), isTrue);
      accounts.online = true;
      await reopened.engine.sync();

      expect(FakeMemberAccounts.accounts.containsKey(friendAccount), isFalse);
    });

    test('removing one of one\'s own devices keeps one\'s account', () async {
      final laptop = Device(server, links, clock);
      final offering = await owner.keeper.offerLink(
        ownerVault,
        secret(code.toBytes()),
      );
      final request = await join(laptop);
      expect(await offering.poll(), isNotNull);
      final linked = (await request.poll())!;
      addTearDown(linked.lock);

      await ownerVault.engine.revoke(linked.member);

      expect(FakeMemberAccounts.accounts.containsKey(owner.account), isTrue);
    });

    group('adversary', () {
      test('a wrong code opens nothing and posts nothing', () async {
        final offering = await invite();
        addTearDown(offering.cancel);
        final wrong = InviteCode.tryParse('K7MQ4X-T9ABC-D2EFH')!;

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
              InviteAnswer.joiner(intruder.publicIdentity, friendAccount),
              key: guess,
              associatedData: InviteAnswer.associatedData(inviteCode.lookup),
            ),
          ),
        );

        expect(await offering.poll(), isNull);
        expect(FakeMemberAccounts.accounts.containsKey(friendAccount), isFalse);
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
        join(browser, typed: LinkCode.tryParse('K7MQ4-XT9AC')),
        throwsA(isA<LinkCodeRejectedException>()),
      );
      expect(links.posted, isEmpty);
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
      links.posted.add(
        LinkAnswer(
          id: offering.id,
          sealedIdentity: EncryptedEnvelope(
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
      links.posted.add(
        LinkAnswer(
          id: offering.id,
          sealedIdentity: EncryptedEnvelope(
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
        final stranger = Device(FakeSyncServer(), links, clock);
        final theirs = await stranger.keeper.create(password('altra frase'));
        addTearDown(theirs.lock);
        final swapped = await stranger.keeper.offerLink(
          theirs,
          secret(LinkCode.tryParse('ZZZZZ-ZZZZZ')!.toBytes()),
        );
        addTearDown(swapped.cancel);

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
      final stranger = Device(hostile, FakeLinkChannel(), clock);
      (await stranger.keeper.create(password('altra frase'))).lock();
      final theirs = await stranger.keeper.unlock(password('altra frase'));
      await theirs.engine.sync();
      theirs.lock();
      final request = await Device(hostile, links, clock).keeper.join(
        code: secret(code.toBytes()),
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

    test('the server sees the link id and ciphertext only', () async {
      final offering = await offer();
      final request = await join(browser);
      addTearDown(request.cancel);
      addTearDown(offering.cancel);

      final posted = [
        links.offers.single.toBytes(),
        links.posted.single.toBytes(),
      ];
      final workspace = founder.workspace.bytes;
      final founderKey = founder.member.signingKey.bytes;
      for (final wire in posted) {
        expect(_contains(wire, workspace), isFalse);
        expect(_contains(wire, founderKey), isFalse);
        expect(_contains(wire, code.toBytes()), isFalse);
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
