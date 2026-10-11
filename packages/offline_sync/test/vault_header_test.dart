import 'dart:typed_data';

import 'package:collaboration_access_control/collaboration_access_control.dart';
import 'package:glados/glados.dart';
import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:offline_sync/offline_sync.dart';

VaultHeader header({
  KdfParameters kdf = KdfParameters.moderate,
  int fill = 1,
}) => VaultHeader(
  salt: Salt.fromBytes(List.filled(Salt.length, fill)),
  kdf: kdf,
  workspace: WorkspaceId.parse('00112233445566778899aabbccddeeff'),
  founder: MemberId(
    PublicSigningKey.fromBytes(List.filled(PublicSigningKey.length, 7)),
  ),
  localKeyId: SubkeyId.fromBytes(List.filled(SubkeyId.length, 9)),
  sealedIdentity: EncryptedEnvelope(
    nonce: Nonce.fromBytes(List.filled(Nonce.length, 3)),
    ciphertext: List.filled(64 + 16, 4),
  ),
);

void main() {
  test('round-trips through its wire form', () {
    final wire = header().toBytes();

    expect(VaultHeader.parse(wire), header());
  });

  test('the identity is bound to every other field of the header', () {
    final base = header().identitySlot;

    expect(header(fill: 2).identitySlot, isNot(base));
    expect(header(kdf: KdfParameters.interactive).identitySlot, isNot(base));
    expect(
      header().identitySlot,
      base,
      reason: 'the sealed identity itself is not part of its own slot',
    );
  });

  group('adversary', () {
    test('every truncation and trailing byte is refused as malformed', () {
      final wire = header().toBytes();
      for (var length = 0; length < wire.length; length++) {
        expect(
          () => VaultHeader.parse(Uint8List.sublistView(wire, 0, length)),
          throwsA(isA<MalformedSyncDataException>()),
          reason: '$length bytes',
        );
      }
      expect(
        () => VaultHeader.parse(Uint8List.fromList([...wire, 0])),
        throwsA(isA<MalformedSyncDataException>()),
      );
    });

    test('an unknown version is refused', () {
      final wire = header().toBytes()..[0] = 2;

      expect(
        () => VaultHeader.parse(wire),
        throwsA(isA<MalformedSyncDataException>()),
      );
    });

    test('Argon2id costs below the floor or above the ceiling are refused', () {
      // A tampered header must neither weaken the KDF nor make unlocking
      // hang: version(1) | salt(16) | opsLimit(4) | memLimit(4) | ...
      for (final (ops, mem) in [(1, 64 << 20), (2, 1 << 20), (99, 64 << 20)]) {
        final wire = header().toBytes();
        ByteData.sublistView(wire)
          ..setUint32(17, ops)
          ..setUint32(21, mem);
        expect(
          () => VaultHeader.parse(wire),
          throwsA(isA<MalformedSyncDataException>()),
          reason: 'ops $ops, mem $mem',
        );
      }
    });

    Glados(any.list(any.uint8)).test('random bytes never crash the parser', (
      bytes,
    ) {
      try {
        VaultHeader.parse(Uint8List.fromList(bytes));
      } on MalformedSyncDataException {
        // The only acceptable failure.
      }
    });
  });
}
