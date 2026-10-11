import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:meta/meta.dart';

import 'collaboration_exception.dart';
import 'identifiers.dart';
import 'membership_change.dart';
import 'role.dart';

@immutable
final class WorkspaceMember {
  const WorkspaceMember(this.identity, this.role);

  final PublicIdentity identity;
  final Role role;

  MemberId get id => MemberId.of(identity);

  WorkspaceMember withRole(Role role) => WorkspaceMember(identity, role);

  @override
  bool operator ==(Object other) =>
      other is WorkspaceMember &&
      other.identity == identity &&
      other.role == role;

  @override
  int get hashCode => Object.hash(identity, role);
}

/// Aggregate root: who belongs to a shared space, with which role, and which
/// GroupKey epoch is current.
///
/// Every state is the result of applying [MembershipChange]s in order, so a
/// client can rebuild it from the signed log alone, without trusting the
/// server's idea of the membership.
@immutable
final class Workspace {
  Workspace._(
    this.id,
    Map<MemberId, WorkspaceMember> members,
    this.epoch,
    this.sequence,
  ) : members = Map.unmodifiable(members);

  factory Workspace.found(WorkspaceId id, {required PublicIdentity founder}) =>
      Workspace._(
        id,
        {MemberId.of(founder): WorkspaceMember(founder, Role.owner)},
        KeyEpoch.initial,
        0,
      );

  final WorkspaceId id;
  final Map<MemberId, WorkspaceMember> members;
  final KeyEpoch epoch;

  /// Position of the last applied change in the membership log.
  final int sequence;

  WorkspaceMember? member(MemberId id) => members[id];

  bool isMember(MemberId id) => members.containsKey(id);

  bool isOwner(MemberId id) => members[id]?.role == Role.owner;

  Workspace apply(MembershipChange change, {required MemberId author}) =>
      switch (change) {
        WorkspaceFounded() => throw const InvalidMembershipChangeException(
          'a workspace is founded only once',
        ),
        MemberInvited(:final identity, :final role) => _invite(
          identity,
          role,
          author,
        ),
        MemberRevoked(:final member) => _revoke(member, author),
        RoleChanged(:final member, :final role) => _changeRole(
          member,
          role,
          author,
        ),
      };

  Workspace _invite(PublicIdentity identity, Role role, MemberId author) {
    _requireOwner(author);
    final id = MemberId.of(identity);
    if (isMember(id)) throw const AlreadyMemberException();
    return _next({...members, id: WorkspaceMember(identity, role)}, epoch);
  }

  Workspace _revoke(MemberId target, MemberId author) {
    if (author != target) _requireOwner(author);
    if (!isMember(target)) throw const NotAMemberException();
    final remaining = {...members}..remove(target);
    _requireAnOwner(remaining);
    return _next(remaining, epoch.next);
  }

  Workspace _changeRole(MemberId target, Role role, MemberId author) {
    _requireOwner(author);
    final current = members[target];
    if (current == null) throw const NotAMemberException();
    final updated = {...members, target: current.withRole(role)};
    _requireAnOwner(updated);
    return _next(updated, epoch);
  }

  Workspace _next(Map<MemberId, WorkspaceMember> members, KeyEpoch epoch) =>
      Workspace._(id, members, epoch, sequence + 1);

  void _requireOwner(MemberId author) {
    if (!isOwner(author)) throw const NotAuthorizedException();
  }

  static void _requireAnOwner(Map<MemberId, WorkspaceMember> members) {
    if (!members.values.any((member) => member.role == Role.owner)) {
      throw const LastOwnerException();
    }
  }
}
