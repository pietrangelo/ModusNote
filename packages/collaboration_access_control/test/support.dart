import 'dart:typed_data';

import 'package:collaboration_access_control/collaboration_access_control.dart';
import 'package:identity_cryptography/identity_cryptography.dart';

/// A recognisable fake identity: the domain only compares public keys, so
/// no real key material is needed below the application ring.
PublicIdentity identity(int seed) => PublicIdentity(
  signingKey: PublicSigningKey.fromBytes(
    Uint8List(PublicSigningKey.length)..fillRange(0, 32, seed),
  ),
  encryptionKey: PublicEncryptionKey.fromBytes(
    Uint8List(PublicEncryptionKey.length)
      ..fillRange(0, PublicEncryptionKey.length, seed),
  ),
);

MemberId memberOf(int seed) => MemberId.of(identity(seed));

final workspaceId = WorkspaceId.parse('00112233445566778899aabbccddeeff');
