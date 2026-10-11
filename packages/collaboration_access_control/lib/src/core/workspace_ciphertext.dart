import 'dart:typed_data';

import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:meta/meta.dart';

import 'collaboration_exception.dart';
import 'identifiers.dart';

/// A record payload sealed under one epoch's GroupKey: `epoch | envelope`.
///
/// The epoch is in clear so a reader knows which key to use; it is also
/// bound into the associated data, so relabelling it gains nothing.
@immutable
final class WorkspaceCiphertext {
  const WorkspaceCiphertext({required this.epoch, required this.envelope});

  factory WorkspaceCiphertext.parse(Uint8List wire) {
    if (wire.length < 4) {
      throw const MalformedWorkspaceDataException('ciphertext too short');
    }
    try {
      return WorkspaceCiphertext(
        epoch: KeyEpoch(ByteData.sublistView(wire, 0, 4).getUint32(0)),
        envelope: EncryptedEnvelope.parse(Uint8List.sublistView(wire, 4)),
      );
    } on CryptographyException {
      throw const MalformedWorkspaceDataException('malformed envelope');
    }
  }

  static AssociatedData associatedData(
    WorkspaceId workspace,
    KeyEpoch epoch,
    String recordId,
  ) => AssociatedData.forContext(
    'modusnote.content.v1',
    '${workspace.hex}:${epoch.value}:$recordId',
  );

  final KeyEpoch epoch;
  final EncryptedEnvelope envelope;

  Uint8List toBytes() => Uint8List.fromList([
    ...(Uint8List(4)..buffer.asByteData().setUint32(0, epoch.value)),
    ...envelope.toBytes(),
  ]);

  @override
  bool operator ==(Object other) =>
      other is WorkspaceCiphertext &&
      other.epoch == epoch &&
      other.envelope == envelope;

  @override
  int get hashCode => Object.hash(epoch, envelope);
}
