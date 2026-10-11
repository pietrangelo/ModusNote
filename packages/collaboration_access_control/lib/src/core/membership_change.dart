import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:meta/meta.dart';

import 'identifiers.dart';
import 'role.dart';

/// One step in a workspace's membership history.
@immutable
sealed class MembershipChange {
  const MembershipChange();
}

final class WorkspaceFounded extends MembershipChange {
  const WorkspaceFounded(this.founder);

  final PublicIdentity founder;

  @override
  bool operator ==(Object other) =>
      other is WorkspaceFounded && other.founder == founder;

  @override
  int get hashCode => founder.hashCode;
}

/// The invitee's [PublicIdentity] reaches the owner out of band (QR code or
/// invite link); signing this change is what vouches for that key.
final class MemberInvited extends MembershipChange {
  const MemberInvited(this.identity, this.role);

  final PublicIdentity identity;
  final Role role;

  @override
  bool operator ==(Object other) =>
      other is MemberInvited &&
      other.identity == identity &&
      other.role == role;

  @override
  int get hashCode => Object.hash(identity, role);
}

final class MemberRevoked extends MembershipChange {
  const MemberRevoked(this.member);

  final MemberId member;

  @override
  bool operator ==(Object other) =>
      other is MemberRevoked && other.member == member;

  @override
  int get hashCode => member.hashCode;
}

final class RoleChanged extends MembershipChange {
  const RoleChanged(this.member, this.role);

  final MemberId member;
  final Role role;

  @override
  bool operator ==(Object other) =>
      other is RoleChanged && other.member == member && other.role == role;

  @override
  int get hashCode => Object.hash(member, role);
}
