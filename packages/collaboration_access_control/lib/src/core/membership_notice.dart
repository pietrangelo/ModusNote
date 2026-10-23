import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:meta/meta.dart';

import 'identifiers.dart';
import 'membership_change.dart';
import 'membership_record.dart';
import 'role.dart';
import 'workspace.dart';

/// What a verified membership record means for the people of a workspace:
/// a device came in, was removed, left, or got another role.
///
/// Notices only ever come from records the device verified itself, so the
/// server cannot invent or alter one (it can only delay records). Records
/// carry no time, so neither do notices: only their place in the log.
@immutable
sealed class MembershipNotice {
  const MembershipNotice({required this.sequence, required this.author});

  /// The notice for [record], read between the state [before] it and the
  /// state [after] it; null for a record that tells people nothing (the
  /// founding).
  static MembershipNotice? between(
    Workspace before,
    MembershipRecord record,
    Workspace after,
  ) {
    final sequence = record.sequence;
    final author = record.author;
    return switch (record.change) {
      WorkspaceFounded() => null,
      MemberInvited(:final identity, :final role) => MemberJoined(
        sequence: sequence,
        author: author,
        identity: identity,
        role: role,
      ),
      MemberRevoked(:final member) when member == author => MemberLeft(
        sequence: sequence,
        author: author,
        member: member,
      ),
      MemberRevoked(:final member) => MemberRemoved(
        sequence: sequence,
        author: author,
        member: member,
        epoch: after.epoch,
      ),
      RoleChanged(:final member, :final role) => MemberRoleChanged(
        sequence: sequence,
        author: author,
        member: member,
        from: before.member(member)!.role,
        to: role,
      ),
    };
  }

  /// Position of the record in the membership log.
  final int sequence;

  /// Who signed the record.
  final MemberId author;

  /// The device the record is about.
  MemberId get member;
}

/// An owner admitted a device: another device of theirs or another
/// person's, which the log cannot tell apart.
final class MemberJoined extends MembershipNotice {
  const MemberJoined({
    required super.sequence,
    required super.author,
    required this.identity,
    required this.role,
  });

  final PublicIdentity identity;
  final Role role;

  @override
  MemberId get member => MemberId.of(identity);

  @override
  bool operator ==(Object other) =>
      other is MemberJoined &&
      other.sequence == sequence &&
      other.author == author &&
      other.identity == identity &&
      other.role == role;

  @override
  int get hashCode => Object.hash(sequence, author, identity, role);
}

/// An owner removed another device: what is written from [epoch] on is
/// sealed under a key the removed device is never granted.
final class MemberRemoved extends MembershipNotice {
  const MemberRemoved({
    required super.sequence,
    required super.author,
    required this.member,
    required this.epoch,
  });

  @override
  final MemberId member;

  /// The GroupKey epoch right after the removal.
  final KeyEpoch epoch;

  @override
  bool operator ==(Object other) =>
      other is MemberRemoved &&
      other.sequence == sequence &&
      other.author == author &&
      other.member == member &&
      other.epoch == epoch;

  @override
  int get hashCode => Object.hash(sequence, author, member, epoch);
}

/// A device removed itself.
final class MemberLeft extends MembershipNotice {
  const MemberLeft({
    required super.sequence,
    required super.author,
    required this.member,
  });

  @override
  final MemberId member;

  @override
  bool operator ==(Object other) =>
      other is MemberLeft &&
      other.sequence == sequence &&
      other.author == author &&
      other.member == member;

  @override
  int get hashCode => Object.hash(sequence, author, member);
}

final class MemberRoleChanged extends MembershipNotice {
  const MemberRoleChanged({
    required super.sequence,
    required super.author,
    required this.member,
    required this.from,
    required this.to,
  });

  @override
  final MemberId member;
  final Role from;
  final Role to;

  @override
  bool operator ==(Object other) =>
      other is MemberRoleChanged &&
      other.sequence == sequence &&
      other.author == author &&
      other.member == member &&
      other.from == from &&
      other.to == to;

  @override
  int get hashCode => Object.hash(sequence, author, member, from, to);
}
