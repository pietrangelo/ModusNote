import 'dart:typed_data';

import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:meta/meta.dart';

import 'collaboration_exception.dart';
import 'identifiers.dart';
import 'wire.dart';

/// One GroupKey of one epoch, sealed to one member.
@immutable
final class GroupKeyGrant {
  const GroupKeyGrant({
    required this.recipient,
    required this.epoch,
    required this.sealedKey,
  });

  /// Bound into the sealed key, so a grant cannot be passed off as one for
  /// another workspace, epoch or member.
  static AssociatedData associatedData(
    WorkspaceId workspace,
    KeyEpoch epoch,
    MemberId recipient,
  ) => AssociatedData.forContext(
    'modusnote.groupkey.v1',
    '${workspace.hex}:${epoch.value}:${recipient.hex}',
  );

  final MemberId recipient;
  final KeyEpoch epoch;
  final SealedKey sealedKey;

  @override
  bool operator ==(Object other) =>
      other is GroupKeyGrant &&
      other.recipient == recipient &&
      other.epoch == epoch &&
      other.sealedKey == sealedKey;

  @override
  int get hashCode => Object.hash(recipient, epoch, sealedKey);
}

/// GroupKey grants issued together by an owner and signed by them.
///
/// Sealing is anonymous, so without the signature a malicious server could
/// seal a key of its own choosing to every member and read whatever they
/// wrote under it. [atSequence] names the membership state the issuer acted
/// in, which is where their authority is checked.
///
/// Wire: `version | workspace | atSequence | issuer | count | grants |
/// signature`, each grant `epoch | recipient | sealedKey`.
@immutable
final class KeyBundle {
  KeyBundle({
    required this.workspace,
    required this.atSequence,
    required this.issuer,
    required List<GroupKeyGrant> grants,
    required this.signature,
  }) : grants = List.unmodifiable(grants) {
    if (grants.length > maxGrants) {
      throw const InvalidWorkspaceValueException('too many grants');
    }
  }

  factory KeyBundle.parse(Uint8List wire) {
    final reader = WireReader(wire);
    if (reader.uint8() != _version) {
      throw const MalformedWorkspaceDataException('unknown bundle version');
    }
    final workspace = WorkspaceId.parse(_hex(reader.bytes(WorkspaceId.length)));
    final atSequence = reader.uint32();
    final issuer = _member(reader);
    final count = reader.uint16();
    if (count > maxGrants ||
        count * _grantLength + Signature.length != reader.remaining) {
      throw const MalformedWorkspaceDataException('grant count mismatch');
    }
    final grants = [
      for (var i = 0; i < count; i++)
        GroupKeyGrant(
          epoch: KeyEpoch(reader.uint32()),
          recipient: _member(reader),
          sealedKey: _sealedKey(reader.bytes(SealedKey.length)),
        ),
    ];
    final signature = Signature.fromBytes(reader.bytes(Signature.length));
    reader.finish();
    return KeyBundle(
      workspace: workspace,
      atSequence: atSequence,
      issuer: issuer,
      grants: grants,
      signature: signature,
    );
  }

  /// The exact bytes an issuer signs.
  static Uint8List signable({
    required WorkspaceId workspace,
    required int atSequence,
    required MemberId issuer,
    required List<GroupKeyGrant> grants,
  }) {
    final writer = WireWriter()..label(_label);
    _writeBody(writer, workspace, atSequence, issuer, grants);
    return writer.take();
  }

  static const maxGrants = 4096;
  static const _label = 'modusnote.keybundle.v1';
  static const _version = 1;
  static const _grantLength = 4 + PublicSigningKey.length + SealedKey.length;

  final WorkspaceId workspace;
  final int atSequence;
  final MemberId issuer;
  final List<GroupKeyGrant> grants;
  final Signature signature;

  Uint8List get signedMessage => signable(
    workspace: workspace,
    atSequence: atSequence,
    issuer: issuer,
    grants: grants,
  );

  Uint8List toBytes() {
    final writer = WireWriter();
    _writeBody(writer, workspace, atSequence, issuer, grants);
    writer.bytes(signature.bytes);
    return writer.take();
  }

  static void _writeBody(
    WireWriter writer,
    WorkspaceId workspace,
    int atSequence,
    MemberId issuer,
    List<GroupKeyGrant> grants,
  ) {
    writer
      ..uint8(_version)
      ..bytes(workspace.bytes)
      ..uint32(atSequence)
      ..bytes(issuer.signingKey.bytes)
      ..uint16(grants.length);
    for (final grant in grants) {
      writer
        ..uint32(grant.epoch.value)
        ..bytes(grant.recipient.signingKey.bytes)
        ..bytes(grant.sealedKey.toBytes());
    }
  }

  static MemberId _member(WireReader reader) => MemberId(
    PublicSigningKey.fromBytes(reader.bytes(PublicSigningKey.length)),
  );

  static SealedKey _sealedKey(Uint8List bytes) {
    try {
      return SealedKey.parse(bytes);
    } on CryptographyException {
      throw const MalformedWorkspaceDataException('malformed sealed key');
    }
  }

  static String _hex(Uint8List bytes) =>
      bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

  @override
  bool operator ==(Object other) =>
      other is KeyBundle &&
      other.workspace == workspace &&
      other.atSequence == atSequence &&
      other.issuer == issuer &&
      other.signature == signature &&
      _sameGrants(other.grants, grants);

  @override
  int get hashCode => Object.hash(
    workspace,
    atSequence,
    issuer,
    signature,
    Object.hashAll(grants),
  );

  static bool _sameGrants(List<GroupKeyGrant> a, List<GroupKeyGrant> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
