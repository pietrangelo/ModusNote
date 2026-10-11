import 'package:collaboration_access_control/collaboration_access_control.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  final alice = memberOf(1);
  final bob = memberOf(2);
  final carol = memberOf(3);

  Workspace founded() => Workspace.found(workspaceId, founder: identity(1));

  Workspace withBobAndCarol() => founded()
      .apply(MemberInvited(identity(2), Role.editor), author: alice)
      .apply(MemberInvited(identity(3), Role.viewer), author: alice);

  group('founding', () {
    test('the founder is the only member, an owner, at epoch 0', () {
      final workspace = founded();

      expect(workspace.id, workspaceId);
      expect(workspace.members.keys, [alice]);
      expect(workspace.member(alice)?.role, Role.owner);
      expect(workspace.epoch, KeyEpoch.initial);
      expect(workspace.sequence, 0);
    });

    test('a workspace cannot be founded twice', () {
      expect(
        () => founded().apply(WorkspaceFounded(identity(2)), author: alice),
        throwsA(isA<InvalidMembershipChangeException>()),
      );
    });
  });

  group('inviting', () {
    test('an owner adds a member with a role; the epoch stays', () {
      final workspace = founded().apply(
        MemberInvited(identity(2), Role.editor),
        author: alice,
      );

      expect(workspace.member(bob)?.role, Role.editor);
      expect(workspace.member(bob)?.identity, identity(2));
      expect(workspace.epoch, KeyEpoch.initial);
      expect(workspace.sequence, 1);
    });

    test('is immutable: the previous state is untouched', () {
      final before = founded();
      before.apply(MemberInvited(identity(2), Role.editor), author: alice);

      expect(before.members, hasLength(1));
      expect(() => before.members.clear(), throwsUnsupportedError);
    });

    test('only owners invite', () {
      expect(
        () => withBobAndCarol().apply(
          MemberInvited(identity(4), Role.viewer),
          author: bob,
        ),
        throwsA(isA<NotAuthorizedException>()),
      );
    });

    test('a non-member cannot invite', () {
      expect(
        () => founded().apply(
          MemberInvited(identity(4), Role.viewer),
          author: carol,
        ),
        throwsA(isA<NotAuthorizedException>()),
      );
    });

    test('an existing member cannot be invited again', () {
      expect(
        () => withBobAndCarol().apply(
          MemberInvited(identity(2), Role.owner),
          author: alice,
        ),
        throwsA(isA<AlreadyMemberException>()),
      );
    });
  });

  group('revoking', () {
    test('removes the member and moves to the next key epoch', () {
      final workspace = withBobAndCarol().apply(
        MemberRevoked(bob),
        author: alice,
      );

      expect(workspace.isMember(bob), isFalse);
      expect(workspace.epoch, KeyEpoch.initial.next);
    });

    test('any member may leave on their own, which also rotates', () {
      final workspace = withBobAndCarol().apply(
        MemberRevoked(carol),
        author: carol,
      );

      expect(workspace.isMember(carol), isFalse);
      expect(workspace.epoch, KeyEpoch.initial.next);
    });

    test('a non-owner cannot remove someone else', () {
      expect(
        () => withBobAndCarol().apply(MemberRevoked(carol), author: bob),
        throwsA(isA<NotAuthorizedException>()),
      );
    });

    test('the last owner cannot be removed, not even by themselves', () {
      expect(
        () => withBobAndCarol().apply(MemberRevoked(alice), author: alice),
        throwsA(isA<LastOwnerException>()),
      );
    });

    test('a non-member cannot be revoked', () {
      expect(
        () => founded().apply(MemberRevoked(bob), author: alice),
        throwsA(isA<NotAMemberException>()),
      );
    });

    test('a revoked member can be invited back later', () {
      final workspace = withBobAndCarol()
          .apply(MemberRevoked(bob), author: alice)
          .apply(MemberInvited(identity(2), Role.viewer), author: alice);

      expect(workspace.member(bob)?.role, Role.viewer);
    });
  });

  group('changing roles', () {
    test('an owner promotes and demotes without rotating', () {
      final workspace = withBobAndCarol()
          .apply(RoleChanged(bob, Role.owner), author: alice)
          .apply(RoleChanged(alice, Role.viewer), author: bob);

      expect(workspace.member(bob)?.role, Role.owner);
      expect(workspace.member(alice)?.role, Role.viewer);
      expect(workspace.epoch, KeyEpoch.initial);
    });

    test('only owners change roles', () {
      expect(
        () =>
            withBobAndCarol().apply(RoleChanged(bob, Role.owner), author: bob),
        throwsA(isA<NotAuthorizedException>()),
      );
    });

    test('the last owner cannot be demoted', () {
      expect(
        () => withBobAndCarol().apply(
          RoleChanged(alice, Role.editor),
          author: alice,
        ),
        throwsA(isA<LastOwnerException>()),
      );
    });

    test('a non-member has no role to change', () {
      expect(
        () => founded().apply(RoleChanged(bob, Role.viewer), author: alice),
        throwsA(isA<NotAMemberException>()),
      );
    });
  });

  group('roles', () {
    test('only owners manage members; viewers cannot write content', () {
      expect(Role.owner.managesMembers, isTrue);
      expect(Role.editor.managesMembers, isFalse);
      expect(Role.viewer.managesMembers, isFalse);
      expect(Role.editor.writesContent, isTrue);
      expect(Role.viewer.writesContent, isFalse);
    });
  });

  group('value objects', () {
    test('WorkspaceId is 16 bytes in lower-case hex', () {
      expect(workspaceId.hex, '00112233445566778899aabbccddeeff');
      for (final bad in [
        '',
        '0011',
        'G0112233445566778899aabbccddeeff',
        '00112233445566778899AABBCCDDEEFF',
      ]) {
        expect(
          () => WorkspaceId.parse(bad),
          throwsA(isA<InvalidWorkspaceValueException>()),
          reason: bad,
        );
      }
    });

    test('KeyEpoch counts up from 0 and refuses negatives', () {
      expect(KeyEpoch.initial.value, 0);
      expect(KeyEpoch.initial.next.value, 1);
      expect(
        () => KeyEpoch(-1),
        throwsA(isA<InvalidWorkspaceValueException>()),
      );
    });

    test('MemberId is the signing key, so the server cannot remap it', () {
      expect(memberOf(2).signingKey, identity(2).signingKey);
      expect(memberOf(2), MemberId.of(identity(2)));
    });
  });
}
