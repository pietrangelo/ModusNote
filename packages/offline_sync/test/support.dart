import 'dart:typed_data';

import 'package:collaboration_access_control/collaboration_access_control.dart';
import 'package:identity_cryptography/identity_cryptography.dart';

MemberId memberOf(int seed) => MemberId(
  PublicSigningKey.fromBytes(
    Uint8List(PublicSigningKey.length)..fillRange(0, 32, seed),
  ),
);

Signature signatureOf(int seed) =>
    Signature.fromBytes(List.filled(Signature.length, seed));

final workspaceId = WorkspaceId.parse('00112233445566778899aabbccddeeff');
