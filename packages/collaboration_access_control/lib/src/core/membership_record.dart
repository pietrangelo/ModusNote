import 'dart:typed_data';

import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:meta/meta.dart';

import 'collaboration_exception.dart';
import 'identifiers.dart';
import 'membership_change.dart';
import 'role.dart';
import 'wire.dart';

/// A [MembershipChange] signed by its author and chained to the record
/// before it, as stored (opaquely) by the sync server.
///
/// Wire: `version | workspace | sequence | author | hasPrevious [previous] |
/// kind | payload | signature`. The signature covers a purpose label plus
/// everything before it, so the server can neither forge, alter nor
/// reorder records; the chain to [previous] stops it from splicing records
/// of one history into another.
@immutable
final class MembershipRecord {
  MembershipRecord({
    required this.workspace,
    required this.sequence,
    required this.author,
    required this.previous,
    required this.change,
    required this.signature,
  }) {
    _checkShape(sequence, previous, InvalidMembershipChangeException.new);
  }

  factory MembershipRecord.parse(Uint8List wire) {
    final reader = WireReader(wire);
    if (reader.uint8() != _version) {
      throw const MalformedWorkspaceDataException('unknown record version');
    }
    final workspace = WorkspaceId.parse(_hex(reader.bytes(WorkspaceId.length)));
    final sequence = reader.uint32();
    final author = _member(reader);
    final previous = switch (reader.uint8()) {
      0 => null,
      1 => Signature.fromBytes(reader.bytes(Signature.length)),
      _ => throw const MalformedWorkspaceDataException('bad previous flag'),
    };
    _checkShape(sequence, previous, MalformedWorkspaceDataException.new);
    final change = switch (reader.uint8()) {
      _founded => WorkspaceFounded(_identity(reader)),
      _invited => MemberInvited(_identity(reader), _role(reader)),
      _revoked => MemberRevoked(_member(reader)),
      _roleChanged => RoleChanged(_member(reader), _role(reader)),
      _ => throw const MalformedWorkspaceDataException('unknown change kind'),
    };
    final signature = Signature.fromBytes(reader.bytes(Signature.length));
    reader.finish();
    return MembershipRecord(
      workspace: workspace,
      sequence: sequence,
      author: author,
      previous: previous,
      change: change,
      signature: signature,
    );
  }

  /// The exact bytes an author signs to produce a record.
  static Uint8List signable({
    required WorkspaceId workspace,
    required int sequence,
    required MemberId author,
    required Signature? previous,
    required MembershipChange change,
  }) {
    final writer = WireWriter()..label(_label);
    _writeBody(writer, workspace, sequence, author, previous, change);
    return writer.take();
  }

  static const _label = 'modusnote.membership.v1';
  static const _version = 1;
  static const _founded = 0;
  static const _invited = 1;
  static const _revoked = 2;
  static const _roleChanged = 3;

  final WorkspaceId workspace;
  final int sequence;
  final MemberId author;
  final Signature? previous;
  final MembershipChange change;
  final Signature signature;

  Uint8List get signedMessage => signable(
    workspace: workspace,
    sequence: sequence,
    author: author,
    previous: previous,
    change: change,
  );

  Uint8List toBytes() {
    final writer = WireWriter();
    _writeBody(writer, workspace, sequence, author, previous, change);
    writer.bytes(signature.bytes);
    return writer.take();
  }

  static void _writeBody(
    WireWriter writer,
    WorkspaceId workspace,
    int sequence,
    MemberId author,
    Signature? previous,
    MembershipChange change,
  ) {
    writer
      ..uint8(_version)
      ..bytes(workspace.bytes)
      ..uint32(sequence)
      ..bytes(author.signingKey.bytes);
    if (previous == null) {
      writer.uint8(0);
    } else {
      writer
        ..uint8(1)
        ..bytes(previous.bytes);
    }
    switch (change) {
      case WorkspaceFounded(:final founder):
        writer
          ..uint8(_founded)
          ..bytes(founder.toBytes());
      case MemberInvited(:final identity, :final role):
        writer
          ..uint8(_invited)
          ..bytes(identity.toBytes())
          ..uint8(role.wireCode);
      case MemberRevoked(:final member):
        writer
          ..uint8(_revoked)
          ..bytes(member.signingKey.bytes);
      case RoleChanged(:final member, :final role):
        writer
          ..uint8(_roleChanged)
          ..bytes(member.signingKey.bytes)
          ..uint8(role.wireCode);
    }
  }

  static void _checkShape(
    int sequence,
    Signature? previous,
    CollaborationException Function(String) failure,
  ) {
    if (sequence < 0 || sequence > 0xFFFFFFFF) {
      throw failure('sequence out of range');
    }
    if ((sequence == 0) != (previous == null)) {
      throw failure('only the first record has no predecessor');
    }
  }

  static MemberId _member(WireReader reader) => MemberId(
    PublicSigningKey.fromBytes(reader.bytes(PublicSigningKey.length)),
  );

  static PublicIdentity _identity(WireReader reader) =>
      PublicIdentity.parse(reader.bytes(PublicIdentity.length));

  static Role _role(WireReader reader) =>
      Role.fromWireCode(reader.uint8()) ??
      (throw const MalformedWorkspaceDataException('unknown role'));

  static String _hex(Uint8List bytes) =>
      bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

  @override
  bool operator ==(Object other) =>
      other is MembershipRecord &&
      other.workspace == workspace &&
      other.sequence == sequence &&
      other.author == author &&
      other.previous == previous &&
      other.change == change &&
      other.signature == signature;

  @override
  int get hashCode =>
      Object.hash(workspace, sequence, author, previous, change, signature);
}
