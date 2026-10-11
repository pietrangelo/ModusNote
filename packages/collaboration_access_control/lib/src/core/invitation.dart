import 'dart:typed_data';

import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:meta/meta.dart';

import 'collaboration_exception.dart';
import 'identifiers.dart';

/// What an invitee receives out of band (QR code or link): the workspace
/// and the founder's signing key.
///
/// Pinning the founder is what makes the membership log verifiable at all:
/// every later record chains back to a record signed by this key, so a
/// server cannot hand the invitee a history it made up.
@immutable
final class Invitation {
  const Invitation({required this.workspace, required this.founder});

  factory Invitation.parse(Uint8List wire) {
    if (wire.length != length || wire[0] != _version) {
      throw const MalformedWorkspaceDataException('malformed invitation');
    }
    final workspace = Uint8List.sublistView(wire, 1, 1 + WorkspaceId.length);
    return Invitation(
      workspace: WorkspaceId.parse(
        workspace.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
      ),
      founder: MemberId(
        PublicSigningKey.fromBytes(
          Uint8List.sublistView(wire, 1 + WorkspaceId.length),
        ),
      ),
    );
  }

  static const _version = 1;
  static const length = 1 + WorkspaceId.length + PublicSigningKey.length;

  final WorkspaceId workspace;
  final MemberId founder;

  Uint8List toBytes() => Uint8List.fromList([
    _version,
    ...workspace.bytes,
    ...founder.signingKey.bytes,
  ]);

  @override
  bool operator ==(Object other) =>
      other is Invitation &&
      other.workspace == workspace &&
      other.founder == founder;

  @override
  int get hashCode => Object.hash(workspace, founder);
}
