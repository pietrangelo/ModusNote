import 'dart:typed_data';

import 'package:collaboration_access_control/collaboration_access_control.dart';
import 'package:glados/glados.dart';
import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:offline_sync/offline_sync.dart';

MemberId memberOf(int fill) => MemberId(
  PublicSigningKey.fromBytes(List.filled(PublicSigningKey.length, fill)),
);

VaultHeader header({
  KdfParameters kdf = KdfParameters.moderate,
  int fill = 1,
  MemberId? member,
}) => VaultHeader(
  salt: Salt.fromBytes(List.filled(Salt.length, fill)),
  kdf: kdf,
  workspace: WorkspaceId.parse('00112233445566778899aabbccddeeff'),
  founder: MemberId(
    PublicSigningKey.fromBytes(List.filled(PublicSigningKey.length, 7)),
  ),
  member: member,
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

  group('linked device', () {
    test('a founder\'s header names the founder as its member', () {
      expect(header().member, header().founder);
    });

    test('a device that joined keeps its own member and round-trips', () {
      final linked = header(member: memberOf(8));

      expect(VaultHeader.parse(linked.toBytes()), linked);
      expect(VaultHeader.parse(linked.toBytes()).member, memberOf(8));
    });

    test('a founder\'s header keeps the bytes it always had', () {
      // Vaults created before linking existed must still open.
      final wire = header().toBytes();

      expect(wire[0], 1);
      expect(header(member: memberOf(7)).toBytes(), wire);
    });

    test('the member is bound into the identity\'s slot', () {
      expect(
        header(member: memberOf(8)).identitySlot,
        isNot(header(member: memberOf(9)).identitySlot),
      );
    });
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
      final wire = header().toBytes()..[0] = 3;

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

    test('a member header that names the founder twice is refused', () {
      final linked = header(member: memberOf(8)).toBytes();
      // version | salt(16) | ops(4) | mem(4) | workspace(16) | founder(32) |
      // member(32): copy the founder over the member.
      const founderAt = 1 + 16 + 4 + 4 + 16;
      linked.setRange(
        founderAt + 32,
        founderAt + 64,
        linked.sublist(founderAt, founderAt + 32),
      );

      expect(
        () => VaultHeader.parse(linked),
        throwsA(isA<MalformedSyncDataException>()),
      );
    });

    Glados(any.list(any.uint8))
        .test('random bytes never crash the parser', (bytes) {
          try {
            VaultHeader.parse(Uint8List.fromList(bytes));
          } on MalformedSyncDataException {
            // The only acceptable failure.
          }
        });
  });
}
