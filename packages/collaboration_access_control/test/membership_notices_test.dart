import 'dart:typed_data';

import 'package:collaboration_access_control/collaboration_access_control.dart';
import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:test/test.dart';

import 'crypto_support.dart';
import 'support.dart' show workspaceId;

void main() {
  setUpAll(initServices);

  group('fingerprints', () {
    test(
      'a member shows the start of its key, upper-cased, in four groups',
      () {
        final key = PublicSigningKey.fromBytes(
          Uint8List.fromList([for (var i = 0; i < 32; i++) i * 7 + 160]),
        );

        // a0 a7 ae b5 bc c3 ca d1 …
        expect(MemberId(key).fingerprint, 'A0A7 AEB5 BCC3 CAD1');
      },
    );

    test('a ledger shows how many records it has and the start of the last '
        'signature, grouped the same way', () {
      final alice = identities.generateIdentity();
      final bob = identities.generateIdentity();
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);
      final founded = ledgers.found(workspaceId, founder: alice);
      final ledger = ledgers
          .append(
            founded,
            MemberInvited(bob.publicIdentity, Role.editor),
            author: alice,
          )
          .ledger;
      final hex = ledger.records.last.signature.bytes
          .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
          .join()
          .toUpperCase();

      expect(ledger.fingerprint.records, 2);
      expect(
        ledger.fingerprint.signature,
        '${hex.substring(0, 4)} ${hex.substring(4, 8)} '
        '${hex.substring(8, 12)} ${hex.substring(12, 16)}',
      );
      expect(ledger.fingerprint, isNot(founded.fingerprint));
      expect(
        ledger.fingerprint,
        LedgerFingerprint(records: 2, signature: ledger.fingerprint.signature),
      );
    });
  });

  group('notices from the ledger', () {
    late IdentityKeyPair alice;
    late IdentityKeyPair bob;
    late IdentityKeyPair carol;
    late VerifiedLedger ledger;

    MemberId id(IdentityKeyPair device) => MemberId.of(device.publicIdentity);

    void append(MembershipChange change, IdentityKeyPair author) {
      ledger = ledgers.append(ledger, change, author: author).ledger;
    }

    setUp(() {
      alice = identities.generateIdentity();
      bob = identities.generateIdentity();
      carol = identities.generateIdentity();
      ledger = ledgers.found(workspaceId, founder: alice);
    });

    tearDown(() {
      for (final device in [alice, bob, carol]) {
        device.dispose();
      }
    });

    test('founding the workspace is no notice', () {
      expect(MembershipNotices.of(ledger), isEmpty);
      expect(MembershipNotices.of(ledger, from: 0), isEmpty);
    });

    test('a device that joins, with its identity and role', () {
      append(MemberInvited(bob.publicIdentity, Role.viewer), alice);

      final notices = MembershipNotices.of(ledger);

      expect(notices, [
        isA<MemberJoined>()
            .having((n) => n.sequence, 'sequence', 1)
            .having((n) => n.author, 'author', id(alice))
            .having((n) => n.identity, 'identity', bob.publicIdentity)
            .having((n) => n.member, 'member', id(bob))
            .having((n) => n.role, 'role', Role.viewer),
      ]);
    });

    test('a device an owner removed, with the epoch that follows', () {
      append(MemberInvited(bob.publicIdentity, Role.editor), alice);
      append(MemberRevoked(id(bob)), alice);

      expect(MembershipNotices.of(ledger, from: 2), [
        isA<MemberRemoved>()
            .having((n) => n.sequence, 'sequence', 2)
            .having((n) => n.author, 'author', id(alice))
            .having((n) => n.member, 'member', id(bob))
            .having((n) => n.epoch, 'epoch', KeyEpoch(1)),
      ]);
    });

    test('a device that left on its own is not a removal', () {
      append(MemberInvited(bob.publicIdentity, Role.editor), alice);
      append(MemberRevoked(id(bob)), bob);

      expect(MembershipNotices.of(ledger, from: 2), [
        isA<MemberLeft>()
            .having((n) => n.sequence, 'sequence', 2)
            .having((n) => n.author, 'author', id(bob))
            .having((n) => n.member, 'member', id(bob)),
      ]);
    });

    test('a role that changed, from what to what', () {
      append(MemberInvited(bob.publicIdentity, Role.viewer), alice);
      append(RoleChanged(id(bob), Role.owner), alice);
      append(RoleChanged(id(alice), Role.editor), bob);

      expect(MembershipNotices.of(ledger, from: 2), [
        isA<MemberRoleChanged>()
            .having((n) => n.sequence, 'sequence', 2)
            .having((n) => n.author, 'author', id(alice))
            .having((n) => n.member, 'member', id(bob))
            .having((n) => n.from, 'from', Role.viewer)
            .having((n) => n.to, 'to', Role.owner),
        isA<MemberRoleChanged>()
            .having((n) => n.sequence, 'sequence', 3)
            .having((n) => n.author, 'author', id(bob))
            .having((n) => n.member, 'member', id(alice))
            .having((n) => n.from, 'from', Role.owner)
            .having((n) => n.to, 'to', Role.editor),
      ]);
    });

    test('every record from the given one on, oldest first', () {
      append(MemberInvited(bob.publicIdentity, Role.editor), alice);
      append(MemberInvited(carol.publicIdentity, Role.viewer), alice);
      append(MemberRevoked(id(bob)), alice);

      expect(MembershipNotices.of(ledger).map((n) => n.sequence), [1, 2, 3]);
      expect(MembershipNotices.of(ledger, from: 2).map((n) => n.runtimeType), [
        MemberJoined,
        MemberRemoved,
      ]);
      expect(MembershipNotices.of(ledger, from: 4), isEmpty);
    });

    test('a mark out of range is clamped to the ledger', () {
      append(MemberInvited(bob.publicIdentity, Role.editor), alice);

      expect(MembershipNotices.of(ledger, from: -5), hasLength(1));
      expect(MembershipNotices.of(ledger, from: 0), hasLength(1));
      expect(MembershipNotices.of(ledger, from: 99), isEmpty);
    });

    test('notices are values', () {
      append(MemberInvited(bob.publicIdentity, Role.editor), alice);

      expect(MembershipNotices.of(ledger), MembershipNotices.of(ledger));
      expect(
        MembershipNotices.of(ledger).single.hashCode,
        MembershipNotices.of(ledger).single.hashCode,
      );
    });
  });
}
