import 'dart:typed_data';

import 'package:collaboration_access_control/collaboration_access_control.dart';
import 'package:glados/glados.dart';
import 'package:identity_cryptography/identity_cryptography.dart';

import 'support.dart';

Signature signature(int seed) =>
    Signature.fromBytes(List.filled(Signature.length, seed));

SealedKey sealedKey(int seed) => SealedKey.parse(
  Uint8List.fromList([
    ...List.filled(SealedKey.encapsulationLength, seed),
    EncryptedEnvelope.currentVersion,
    ...List.filled(SealedKey.length - SealedKey.encapsulationLength - 1, seed),
  ]),
);

MembershipRecord record(MembershipChange change, {int sequence = 1}) =>
    MembershipRecord(
      workspace: workspaceId,
      sequence: sequence,
      author: memberOf(1),
      previous: sequence == 0 ? null : signature(9),
      change: change,
      signature: signature(8),
    );

KeyBundle bundle(List<GroupKeyGrant> grants) => KeyBundle(
  workspace: workspaceId,
  atSequence: 4,
  issuer: memberOf(1),
  grants: grants,
  signature: signature(7),
);

void main() {
  group('MembershipRecord', () {
    final samples = [
      record(WorkspaceFounded(identity(1)), sequence: 0),
      record(MemberInvited(identity(2), Role.editor)),
      record(MemberRevoked(memberOf(2)), sequence: 7),
      record(RoleChanged(memberOf(3), Role.viewer), sequence: 0xFFFFFFFF),
    ];

    test('round-trips every kind of change through the wire', () {
      for (final sample in samples) {
        expect(MembershipRecord.parse(sample.toBytes()), sample);
      }
    });

    test('the signed message binds every field', () {
      final base = record(MemberInvited(identity(2), Role.editor));
      final variants = [
        MembershipRecord.signable(
          workspace: WorkspaceId.parse('ffeeddccbbaa99887766554433221100'),
          sequence: 1,
          author: memberOf(1),
          previous: signature(9),
          change: base.change,
        ),
        MembershipRecord.signable(
          workspace: workspaceId,
          sequence: 2,
          author: memberOf(1),
          previous: signature(9),
          change: base.change,
        ),
        MembershipRecord.signable(
          workspace: workspaceId,
          sequence: 1,
          author: memberOf(4),
          previous: signature(9),
          change: base.change,
        ),
        MembershipRecord.signable(
          workspace: workspaceId,
          sequence: 1,
          author: memberOf(1),
          previous: signature(6),
          change: base.change,
        ),
        MembershipRecord.signable(
          workspace: workspaceId,
          sequence: 1,
          author: memberOf(1),
          previous: signature(9),
          change: MemberInvited(identity(2), Role.owner),
        ),
      ];

      for (final variant in variants) {
        expect(variant, isNot(base.signedMessage));
      }
    });

    test(
      'the signed message is labelled, so it never verifies as a bundle',
      () {
        final message = samples[1].signedMessage;

        expect(
          String.fromCharCodes(message.take(23)),
          'modusnote.membership.v1',
        );
      },
    );

    test('only the first record has no predecessor', () {
      expect(
        () => MembershipRecord(
          workspace: workspaceId,
          sequence: 3,
          author: memberOf(1),
          previous: null,
          change: MemberRevoked(memberOf(2)),
          signature: signature(1),
        ),
        throwsA(isA<InvalidMembershipChangeException>()),
      );
      expect(
        () => MembershipRecord(
          workspace: workspaceId,
          sequence: 0,
          author: memberOf(1),
          previous: signature(1),
          change: WorkspaceFounded(identity(1)),
          signature: signature(1),
        ),
        throwsA(isA<InvalidMembershipChangeException>()),
      );
    });

    group('adversary', () {
      test('every truncation is refused as malformed', () {
        for (final sample in samples) {
          final wire = sample.toBytes();
          for (var length = 0; length < wire.length; length++) {
            expect(
              () => MembershipRecord.parse(
                Uint8List.sublistView(wire, 0, length),
              ),
              throwsA(isA<MalformedWorkspaceDataException>()),
            );
          }
        }
      });

      test('trailing bytes are refused', () {
        final wire = samples[2].toBytes();

        expect(
          () => MembershipRecord.parse(Uint8List.fromList([...wire, 0])),
          throwsA(isA<MalformedWorkspaceDataException>()),
        );
      });

      test('a predecessor flag that contradicts the sequence is refused', () {
        final wire = samples[0].toBytes();
        const flag = 1 + 16 + 4 + 32;
        final tampered = Uint8List.fromList(wire)..[flag - 32 - 1] = 1;

        expect(
          () => MembershipRecord.parse(tampered),
          throwsA(isA<MalformedWorkspaceDataException>()),
        );
      });

      test('unknown versions, change kinds, roles and flags are refused', () {
        final wire = samples[1].toBytes();
        // version | workspace(16) | sequence(4) | author(32) | flag | ...
        const flag = 1 + 16 + 4 + 32;
        const kind = flag + 1 + Signature.length;
        const role = kind + 1 + PublicIdentity.length;
        for (final (position, value) in [
          (0, 2),
          (flag, 2),
          (kind, 9),
          (role, 0),
          (role, 4),
        ]) {
          final tampered = Uint8List.fromList(wire)..[position] = value;
          expect(
            () => MembershipRecord.parse(tampered),
            throwsA(isA<MalformedWorkspaceDataException>()),
            reason: 'byte $position = $value',
          );
        }
      });

      Glados(any.list(any.uint8))
          .test('random bytes never crash the parser', (bytes) {
            try {
              MembershipRecord.parse(Uint8List.fromList(bytes));
            } on MalformedWorkspaceDataException {
              // The only acceptable failure.
            }
          });
    });
  });

  group('KeyBundle', () {
    final grants = [
      GroupKeyGrant(
        recipient: memberOf(2),
        epoch: KeyEpoch.initial,
        sealedKey: sealedKey(3),
      ),
      GroupKeyGrant(
        recipient: memberOf(3),
        epoch: KeyEpoch(5),
        sealedKey: sealedKey(4),
      ),
    ];

    test('round-trips through the wire', () {
      expect(KeyBundle.parse(bundle(grants).toBytes()), bundle(grants));
      expect(KeyBundle.parse(bundle(const []).toBytes()), bundle(const []));
    });

    test('the grants are exposed read-only', () {
      expect(() => bundle(grants).grants.clear(), throwsUnsupportedError);
    });

    test('the signed message is labelled and binds the grants', () {
      final message = bundle(grants).signedMessage;

      expect(String.fromCharCodes(message.take(22)), 'modusnote.keybundle.v1');
      expect(message, isNot(bundle(grants.reversed.toList()).signedMessage));
    });

    test('each grant is bound to its workspace, epoch and recipient', () {
      final context = GroupKeyGrant.associatedData(
        workspaceId,
        KeyEpoch(5),
        memberOf(3),
      );

      expect(
        context,
        isNot(
          GroupKeyGrant.associatedData(workspaceId, KeyEpoch(4), memberOf(3)),
        ),
      );
      expect(
        context,
        isNot(
          GroupKeyGrant.associatedData(workspaceId, KeyEpoch(5), memberOf(2)),
        ),
      );
      expect(
        context,
        isNot(
          GroupKeyGrant.associatedData(
            WorkspaceId.parse('ffeeddccbbaa99887766554433221100'),
            KeyEpoch(5),
            memberOf(3),
          ),
        ),
      );
    });

    group('adversary', () {
      test('every truncation is refused as malformed', () {
        final wire = bundle(grants).toBytes();
        for (var length = 0; length < wire.length; length += 7) {
          expect(
            () => KeyBundle.parse(Uint8List.sublistView(wire, 0, length)),
            throwsA(isA<MalformedWorkspaceDataException>()),
          );
        }
      });

      test('a grant count larger than the payload is refused', () {
        final wire = bundle(grants).toBytes();
        // version | workspace(16) | atSequence(4) | issuer(32) | count(2)
        const count = 1 + 16 + 4 + 32;
        final tampered = Uint8List.fromList(wire)
          ..[count] = 0xFF
          ..[count + 1] = 0xFF;

        expect(
          () => KeyBundle.parse(tampered),
          throwsA(isA<MalformedWorkspaceDataException>()),
        );
      });

      Glados(any.list(any.uint8))
          .test('random bytes never crash the parser', (bytes) {
            try {
              KeyBundle.parse(Uint8List.fromList(bytes));
            } on MalformedWorkspaceDataException {
              // The only acceptable failure.
            }
          });
    });
  });
}
