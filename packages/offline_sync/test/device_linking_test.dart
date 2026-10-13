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
  Device(this.server, this.links, this.clock, {this.prf});

  final PasskeyPrf? prf;
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
