import 'dart:typed_data';

import 'package:collaboration_access_control/collaboration_access_control.dart';
import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:identity_cryptography_adapters/identity_cryptography_adapters.dart';
import 'package:test/test.dart';

import 'crypto_support.dart';
import 'support.dart' show workspaceId;

/// What the zero-knowledge server holds for one workspace: opaque bytes.
final class Server {
  final log = <Uint8List>[];
  final bundles = <Uint8List>[];

  void publish(MembershipUpdate update) {
    log.add(update.record.toBytes());
    if (update.bundle case final bundle?) bundles.add(bundle.toBytes());
  }

  List<MembershipRecord> get records =>
      log.map(MembershipRecord.parse).toList();

  List<KeyBundle> get keyBundles => bundles.map(KeyBundle.parse).toList();
}

SymmetricKey freshKey() => SodiumEnvelopeEncryptor(sodium).generateKey();

Matcher tampered(String message) => isA<TamperedWorkspaceDataException>()
    .having((e) => e.message, 'message', message);

void main() {
  late Server server;
  late Device alice;
  late Device bob;
  late Device carol;
  late Invitation invitation;

  setUpAll(initServices);

  setUp(() {
    server = Server();
    alice = Device('alice');
    bob = Device('bob');
    carol = Device('carol');

    final founded = administration.found(workspaceId, founder: alice.identity);
    alice
      ..ledger = founded.ledger
      ..keyring = founded.keyring;
    server.publish(founded);
    invitation = founded.invitation;
  });

  tearDown(() {
    for (final device in [alice, bob, carol]) {
      device.dispose();
    }
  });

  void invite(Device device, Role role) {
    final update = administration.invite(
      alice.ledger,
      alice.keyring,
      owner: alice.identity,
      invitee: device.publicIdentity,
      role: role,
    );
    alice.ledger = update.ledger;
    server.publish(update);
    device
      ..join(invitation, server.records)
      ..sync(server.records, server.keyBundles);
  }

  Uint8List read(Device device, WorkspaceCiphertext ciphertext, String id) =>
      contents.open(ciphertext, keyring: device.keyring, recordId: id);

  WorkspaceCiphertext write(Device device, String text, String id) =>
      contents.seal(
        utf8Bytes(text),
        workspace: device.ledger.workspace,
        author: device.id,
        keyring: device.keyring,
        recordId: id,
      );

  group('founding', () {
    test('the founder holds the epoch-0 GroupKey and can write', () {
      expect(alice.ledger.workspace.epoch, KeyEpoch.initial);
      expect(alice.keyring.epochs, [KeyEpoch.initial]);

      final note = write(alice, 'Bozza del ritornello', 'n1');

      expect(read(alice, note, 'n1'), utf8Bytes('Bozza del ritornello'));
    });

    test('the server only ever stores ciphertext and public keys', () {
      final note = write(alice, 'Bozza del ritornello', 'n1');
      final stored = [...server.log, ...server.bundles, note.toBytes()];

      for (final bytes in stored) {
        expect(String.fromCharCodes(bytes), isNot(contains('ritornello')));
      }
    });

    test('the invitation is what the invitee pins: workspace and founder', () {
      final parsed = Invitation.parse(invitation.toBytes());

      expect(parsed.workspace, workspaceId);
      expect(parsed.founder, alice.id);
    });
  });

  group('inviting', () {
    test('the invitee verifies the log and receives the GroupKey', () {
      invite(bob, Role.editor);

      expect(bob.ledger.workspace.member(bob.id)?.role, Role.editor);
      expect(bob.keyring.epochs, [KeyEpoch.initial]);
    });

    test('members read each other\'s notes', () {
      invite(bob, Role.editor);
      final note = write(alice, 'Sogno del faro', 'n1');

      expect(read(bob, note, 'n1'), utf8Bytes('Sogno del faro'));
      expect(
        read(alice, write(bob, 'Risposta', 'n2'), 'n2'),
        utf8Bytes('Risposta'),
      );
    });

    test('a new member also receives the earlier epochs, to read history', () {
      invite(bob, Role.editor);
      final old = write(alice, 'Prima della rotazione', 'n1');
      final revoked = administration.revoke(
        alice.ledger,
        alice.keyring,
        owner: alice.identity,
        member: bob.id,
      );
      alice.ledger = revoked.ledger;
      server.publish(revoked);

      invite(carol, Role.viewer);

      expect(carol.keyring.epochs, [KeyEpoch.initial, KeyEpoch(1)]);
      expect(read(carol, old, 'n1'), utf8Bytes('Prima della rotazione'));
    });

    test('a viewer may read but the cipher refuses to write for them', () {
      invite(carol, Role.viewer);

      expect(
        () => write(carol, 'x', 'n1'),
        throwsA(isA<NotAuthorizedException>()),
      );
    });
  });

  group('granting again', () {
    test('a member whose keys never arrived receives every epoch', () {
      invite(carol, Role.editor);
      final revoked = administration.revoke(
        alice.ledger,
        alice.keyring,
        owner: alice.identity,
        member: carol.id,
      );
      alice.ledger = revoked.ledger;
      server.publish(revoked);
      // Bob's record went out; the bundle with his keys did not.
      final update = administration.invite(
        alice.ledger,
        alice.keyring,
        owner: alice.identity,
        invitee: bob.publicIdentity,
        role: Role.owner,
      );
      alice.ledger = update.ledger;
      server.log.add(update.record.toBytes());
      bob.join(invitation, server.records);

      final again = administration.grantAll(
        alice.ledger,
        alice.keyring,
        issuer: alice.identity,
        recipient: bob.id,
      );
      bob.sync(server.records, [again]);

      expect(bob.keyring.epochs, [KeyEpoch.initial, KeyEpoch(1)]);
    });

    test('someone outside the workspace is granted nothing', () {
      expect(
        () => administration.grantAll(
          alice.ledger,
          alice.keyring,
          issuer: alice.identity,
          recipient: bob.id,
        ),
        throwsA(isA<NotAMemberException>()),
      );
    });
  });

  group('revoking', () {
    test('rotates the GroupKey and grants it only to who remains', () {
      invite(bob, Role.editor);
      invite(carol, Role.editor);

      final update = administration.revoke(
        alice.ledger,
        alice.keyring,
        owner: alice.identity,
        member: bob.id,
      );
      alice.ledger = update.ledger;
      server.publish(update);
      carol.sync(server.records, server.keyBundles);

      expect(alice.ledger.workspace.epoch, KeyEpoch(1));
      expect(alice.keyring.epochs, contains(KeyEpoch(1)));
      expect(carol.keyring.epochs, contains(KeyEpoch(1)));
      expect(
        update.bundle!.grants.map((grant) => grant.recipient),
        unorderedEquals([alice.id, carol.id]),
      );
    });

    test('a member who leaves cannot rotate for the others; an owner does', () {
      invite(bob, Role.editor);
      final left = administration.leave(bob.ledger, member: bob.identity);
      server.publish(left);
      alice.sync(server.records, const []);

      expect(left.bundle, isNull);
      expect(alice.ledger.workspace.epoch, KeyEpoch(1));
      expect(
        () => write(alice, 'x', 'n1'),
        throwsA(isA<MissingGroupKeyException>()),
        reason: 'nothing is written under the old key after a departure',
      );

      final rotated = administration.rotate(
        alice.ledger,
        alice.keyring,
        owner: alice.identity,
      );
      server.bundles.add(rotated.toBytes());

      expect(read(alice, write(alice, 'ok', 'n1'), 'n1'), utf8Bytes('ok'));
    });

    test('rotating twice for the same epoch is refused', () {
      expect(
        () => administration.rotate(
          alice.ledger,
          alice.keyring,
          owner: alice.identity,
        ),
        throwsA(isA<InvalidMembershipChangeException>()),
      );
    });
  });

  group('changing roles', () {
    test('is recorded in the signed log without rotating', () {
      invite(bob, Role.viewer);
      final update = administration.changeRole(
        alice.ledger,
        owner: alice.identity,
        member: bob.id,
        role: Role.editor,
      );
      server.publish(update);
      bob.sync(server.records, const []);

      expect(bob.ledger.workspace.member(bob.id)?.role, Role.editor);
      expect(bob.ledger.workspace.epoch, KeyEpoch.initial);
    });
  });

  group('adversary', () {
    test('a removed member cannot read revisions written after removal', () {
      invite(bob, Role.editor);
      invite(carol, Role.editor);
      final before = write(carol, 'Strofa v1', 'n1');
      expect(read(bob, before, 'n1'), utf8Bytes('Strofa v1'));

      final update = administration.revoke(
        alice.ledger,
        alice.keyring,
        owner: alice.identity,
        member: bob.id,
      );
      alice.ledger = update.ledger;
      server.publish(update);
      carol.sync(server.records, server.keyBundles);
      final after = write(carol, 'Strofa v2', 'n1');

      expect(after.epoch, KeyEpoch(1));
      // Bob kept every key he ever had and fetches everything the server has.
      bob.ledger = ledgers.extend(
        bob.ledger,
        server.records.skip(bob.ledger.records.length).toList(),
      );
      for (final bundle in server.keyBundles) {
        try {
          administration.accept(
            bundle,
            ledger: bob.ledger,
            me: bob.identity,
            keyring: bob.keyring,
          );
        } on CollaborationException {
          // A bundle that no longer names Bob: exactly what should happen.
        }
      }
      expect(bob.keyring.epochs, isNot(contains(KeyEpoch(1))));
      expect(
        () => read(bob, after, 'n1'),
        throwsA(isA<MissingGroupKeyException>()),
      );
    });

    test('a removed member cannot open the grants addressed to others', () {
      invite(bob, Role.editor);
      invite(carol, Role.editor);
      final update = administration.revoke(
        alice.ledger,
        alice.keyring,
        owner: alice.identity,
        member: bob.id,
      );

      // Bob relabels Carol's grant as his own: the recipient is bound into
      // the sealed key, and the key was sealed to Carol's KEM key anyway.
      final carolsGrant = update.bundle!.grants.firstWhere(
        (grant) => grant.recipient == carol.id,
      );
      final forged = KeyBundle(
        workspace: workspaceId,
        atSequence: update.bundle!.atSequence,
        issuer: alice.id,
        grants: [
          GroupKeyGrant(
            recipient: bob.id,
            epoch: carolsGrant.epoch,
            sealedKey: carolsGrant.sealedKey,
          ),
        ],
        signature: update.bundle!.signature,
      );

      expect(
        () => administration.accept(
          forged,
          ledger: update.ledger,
          me: bob.identity,
          keyring: bob.keyring,
        ),
        throwsA(tampered('bad bundle signature')),
      );
    });

    test('the server cannot inject a member without an owner signature', () {
      invite(bob, Role.editor);
      final mallory = identities.generateIdentity();
      addTearDown(mallory.dispose);
      final records = server.records;
      final last = records.last;

      // The server signs with its own key and claims Alice wrote it.
      final injected = MembershipRecord(
        workspace: workspaceId,
        sequence: last.sequence + 1,
        author: alice.id,
        previous: last.signature,
        change: MemberInvited(mallory.publicIdentity, Role.owner),
        signature: identities.sign(
          MembershipRecord.signable(
            workspace: workspaceId,
            sequence: last.sequence + 1,
            author: alice.id,
            previous: last.signature,
            change: MemberInvited(mallory.publicIdentity, Role.owner),
          ),
          signer: mallory,
        ),
      );

      expect(
        () => ledgers.extend(bob.ledger, [injected]),
        throwsA(tampered('bad record signature')),
      );
      expect(
        () => ledgers.verify([...records, injected], invitation: invitation),
        throwsA(isA<TamperedWorkspaceDataException>()),
      );
    });

    test('a validly signed change by a non-owner is still refused', () {
      invite(bob, Role.editor);
      final mallory = identities.generateIdentity();
      addTearDown(mallory.dispose);
      final last = server.records.last;
      final change = MemberInvited(mallory.publicIdentity, Role.owner);

      final bySelf = MembershipRecord(
        workspace: workspaceId,
        sequence: last.sequence + 1,
        author: bob.id,
        previous: last.signature,
        change: change,
        signature: identities.sign(
          MembershipRecord.signable(
            workspace: workspaceId,
            sequence: last.sequence + 1,
            author: bob.id,
            previous: last.signature,
            change: change,
          ),
          signer: bob.identity,
        ),
      );

      expect(
        () => ledgers.extend(alice.ledger, [bySelf]),
        throwsA(tampered('record breaks the membership rules')),
      );
    });

    test(
      'the server cannot reorder, drop from the middle or splice records',
      () {
        invite(bob, Role.editor);
        invite(carol, Role.viewer);
        final records = server.records;

        for (final tampered in [
          [records[0], records[2], records[1]],
          [records[0], records[2]],
          [records[1], records[2]],
          <MembershipRecord>[],
        ]) {
          expect(
            () => ledgers.verify(tampered, invitation: invitation),
            throwsA(isA<TamperedWorkspaceDataException>()),
          );
        }
      },
    );

    test(
      'a log founded by someone else is refused, even if self-consistent',
      () {
        final mallory = Device('mallory');
        addTearDown(mallory.dispose);
        final fake = administration.found(
          workspaceId,
          founder: mallory.identity,
        );

        expect(
          () => ledgers.verify([fake.record], invitation: invitation),
          throwsA(tampered('log not founded as invited')),
        );
        fake.keyring.dispose();
      },
    );

    test('a record from another workspace is refused', () {
      final other = administration.found(
        WorkspaceId.parse('ffeeddccbbaa99887766554433221100'),
        founder: alice.identity,
      );
      addTearDown(other.keyring.dispose);
      final invite = administration.invite(
        other.ledger,
        other.keyring,
        owner: alice.identity,
        invitee: bob.publicIdentity,
        role: Role.editor,
      );

      expect(
        () => ledgers.extend(alice.ledger, [invite.record]),
        throwsA(tampered('broken membership chain')),
      );
    });

    test('the server cannot hand out a GroupKey of its own', () {
      invite(bob, Role.editor);
      final server = identities.generateIdentity();
      addTearDown(server.dispose);

      // A bundle sealed correctly to Bob, but signed by the server.
      final genuine = administration.grant(
        alice.ledger,
        alice.keyring,
        issuer: alice.identity,
        epoch: KeyEpoch.initial,
        recipients: [bob.id],
      );
      final forged = KeyBundle(
        workspace: genuine.workspace,
        atSequence: genuine.atSequence,
        issuer: alice.id,
        grants: genuine.grants,
        signature: identities.sign(genuine.signedMessage, signer: server),
      );

      expect(
        () => administration.accept(
          forged,
          ledger: bob.ledger,
          me: bob.identity,
          keyring: bob.keyring,
        ),
        throwsA(tampered('bad bundle signature')),
      );
    });

    test(
      'an editor\'s validly signed bundle is refused: only owners grant',
      () {
        invite(bob, Role.editor);
        invite(carol, Role.editor);
        bob.sync(server.records, const []);

        final byEditor = administration.grant(
          bob.ledger,
          bob.keyring,
          issuer: bob.identity,
          epoch: KeyEpoch.initial,
          recipients: [carol.id],
        );

        expect(
          () => administration.accept(
            byEditor,
            ledger: carol.ledger,
            me: carol.identity,
            keyring: carol.keyring,
          ),
          throwsA(tampered('issuer is not an owner')),
        );
      },
    );

    test(
      'a revoked owner cannot grant a key for an epoch after their removal',
      () {
        invite(bob, Role.owner);
        invite(carol, Role.editor);
        bob.sync(server.records, const []);
        final bobsOldLedger = bob.ledger;
        final update = administration.revoke(
          alice.ledger,
          alice.keyring,
          owner: alice.identity,
          member: bob.id,
        );
        server.publish(update);
        carol.sync(server.records, const []);

        // Bob claims, from a state where he was still an owner, the key for
        // the epoch that began only after his removal.
        final stale = bob.keyring;
        final bobsKey = administration.grant(
          bobsOldLedger,
          stale,
          issuer: bob.identity,
          epoch: KeyEpoch.initial,
          recipients: [carol.id],
        );
        final forFutureEpoch = KeyBundle(
          workspace: bobsKey.workspace,
          atSequence: bobsKey.atSequence,
          issuer: bob.id,
          grants: [
            for (final grant in bobsKey.grants)
              GroupKeyGrant(
                recipient: grant.recipient,
                epoch: KeyEpoch(1),
                sealedKey: grant.sealedKey,
              ),
          ],
          signature: identities.sign(
            KeyBundle.signable(
              workspace: bobsKey.workspace,
              atSequence: bobsKey.atSequence,
              issuer: bob.id,
              grants: [
                for (final grant in bobsKey.grants)
                  GroupKeyGrant(
                    recipient: grant.recipient,
                    epoch: KeyEpoch(1),
                    sealedKey: grant.sealedKey,
                  ),
              ],
            ),
            signer: bob.identity,
          ),
        );

        expect(
          () => administration.accept(
            forFutureEpoch,
            ledger: carol.ledger,
            me: carol.identity,
            keyring: carol.keyring,
          ),
          throwsA(tampered('grant beyond authority')),
        );
      },
    );

    test('a ciphertext moved to another record or epoch fails to open', () {
      final note = write(alice, 'Diario', 'n1');

      expect(
        () => read(alice, note, 'n2'),
        throwsA(isA<AuthenticationTagMismatchException>()),
      );
      final relabelled = WorkspaceCiphertext.parse(
        Uint8List.fromList(note.toBytes())..[3] = 1,
      );
      expect(
        () => read(alice, relabelled, 'n1'),
        throwsA(isA<MissingGroupKeyException>()),
      );
    });

    test('flipping any bit of a stored bundle makes it unusable', () {
      invite(bob, Role.editor);
      final wire = server.bundles.last;
      final positions = {for (var i = 0; i < wire.length; i += 53) i};

      for (final position in positions) {
        final tampered = Uint8List.fromList(wire)..[position] ^= 0x01;
        expect(
          () => administration.accept(
            KeyBundle.parse(tampered),
            ledger: bob.ledger,
            me: bob.identity,
            keyring: bob.keyring,
          ),
          throwsA(
            anyOf(isA<CollaborationException>(), isA<CryptographyException>()),
          ),
          reason: 'byte $position',
        );
      }
    });

    test('a second grant for an epoch cannot swap the key already held', () {
      final note = write(alice, 'Prima', 'n1');
      alice.keyring.add(KeyEpoch.initial, freshKey());

      expect(read(alice, note, 'n1'), utf8Bytes('Prima'));
    });

    test('a disposed keyring holds no keys', () {
      final keyring = alice.keyring..dispose();

      expect(keyring.epochs, isEmpty);
      expect(
        () => write(alice, 'x', 'n1'),
        throwsA(isA<MissingGroupKeyException>()),
      );
    });
  });

  group('checking a bundle without opening it, as the server does', () {
    KeyBundle signedBy(
      Device issuer,
      KeyBundle genuine,
      List<GroupKeyGrant> grants,
    ) => KeyBundle(
      workspace: genuine.workspace,
      atSequence: genuine.atSequence,
      issuer: issuer.id,
      grants: grants,
      signature: identities.sign(
        KeyBundle.signable(
          workspace: genuine.workspace,
          atSequence: genuine.atSequence,
          issuer: issuer.id,
          grants: grants,
        ),
        signer: issuer.identity,
      ),
    );

    test('a genuine bundle passes', () {
      invite(bob, Role.editor);

      expect(
        () =>
            administration.verify(server.keyBundles.last, ledger: alice.ledger),
        returnsNormally,
      );
    });

    test('a grant to someone who was not a member there is refused', () {
      invite(bob, Role.editor);
      final genuine = server.keyBundles.last;
      final toCarol = signedBy(alice, genuine, [
        GroupKeyGrant(
          recipient: carol.id,
          epoch: KeyEpoch.initial,
          sealedKey: genuine.grants.single.sealedKey,
        ),
      ]);

      expect(
        () => administration.verify(toCarol, ledger: alice.ledger),
        throwsA(tampered('grant beyond authority')),
      );
    });

    test('a grant for an epoch that did not exist there is refused', () {
      invite(bob, Role.editor);
      final genuine = server.keyBundles.last;
      final ahead = signedBy(alice, genuine, [
        GroupKeyGrant(
          recipient: bob.id,
          epoch: KeyEpoch(1),
          sealedKey: genuine.grants.single.sealedKey,
        ),
      ]);

      expect(
        () => administration.verify(ahead, ledger: alice.ledger),
        throwsA(tampered('grant beyond authority')),
      );
    });

    test('an editor\'s bundle and a forged signature are refused', () {
      invite(bob, Role.editor);
      final genuine = server.keyBundles.last;

      expect(
        () => administration.verify(
          signedBy(bob, genuine, genuine.grants),
          ledger: alice.ledger,
        ),
        throwsA(tampered('issuer is not an owner')),
      );
      final wire = genuine.toBytes()..[genuine.toBytes().length - 1] ^= 1;
      expect(
        () =>
            administration.verify(KeyBundle.parse(wire), ledger: alice.ledger),
        throwsA(tampered('bad bundle signature')),
      );
    });

    test('a bundle naming a record the log does not have is refused', () {
      final genuine = server.keyBundles.last;
      final beyond = KeyBundle(
        workspace: genuine.workspace,
        atSequence: 5,
        issuer: alice.id,
        grants: genuine.grants,
        signature: genuine.signature,
      );

      expect(
        () => administration.verify(beyond, ledger: alice.ledger),
        throwsA(tampered('unknown log position')),
      );
    });
  });
}
