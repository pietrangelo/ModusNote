import 'dart:typed_data';

import 'package:glados/glados.dart';
import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:offline_sync/offline_sync.dart';

import 'vault_header_test.dart' show header;

PasskeySlot slot({int credential = 5, int salt = 6, int keyId = 8}) =>
    PasskeySlot(
      credential: PasskeyCredentialId.fromBytes(List.filled(20, credential)),
      salt: PrfSalt.fromBytes(List.filled(PrfSalt.length, salt)),
      keyId: SubkeyId.fromBytes(List.filled(SubkeyId.length, keyId)),
      sealedIdentity: EncryptedEnvelope(
        nonce: Nonce.fromBytes(List.filled(Nonce.length, 3)),
        ciphertext: List.filled(64 + 16, 4),
      ),
      sealedLocalKey: SealedKey(
        encapsulation: List.filled(SealedKey.encapsulationLength, 1),
        envelope: EncryptedEnvelope(
          nonce: Nonce.fromBytes(List.filled(Nonce.length, 2)),
          ciphertext: List.filled(
            SealedKey.keyLength + EncryptedEnvelope.tagLength,
            9,
          ),
        ),
      ),
    );

void main() {
  test('round-trips through its wire form', () {
    expect(PasskeySlot.parse(slot().toBytes()), slot());
  });

  test('sealing binds both secrets to the header and the slot', () {
    late AssociatedData identitySlot;
    late AssociatedData localKeySlot;
    final sealed = PasskeySlot.sealing(
      header: header(),
      credential: slot().credential,
      salt: slot().salt,
      keyId: slot().keyId,
      sealIdentity: (data) {
        identitySlot = data;
        return slot().sealedIdentity;
      },
      sealLocalKey: (data) {
        localKeySlot = data;
        return slot().sealedLocalKey;
      },
    );

    expect(sealed, slot());
    expect(identitySlot, sealed.identitySlot(header()));
    expect(localKeySlot, sealed.localKeySlot(header()));
    expect(identitySlot, isNot(localKeySlot));
  });

  test('its slots change with every clear field of header and slot', () {
    final base = slot().identitySlot(header());
    final local = slot().localKeySlot(header());

    for (final other in [slot(credential: 1), slot(salt: 1), slot(keyId: 1)]) {
      expect(other.identitySlot(header()), isNot(base));
      expect(other.localKeySlot(header()), isNot(local));
    }
    expect(slot().identitySlot(header(fill: 2)), isNot(base));
    expect(
      slot().identitySlot(header(kdf: KdfParameters.interactive)),
      isNot(base),
    );
    expect(slot().localKeySlot(header(fill: 2)), isNot(local));
    expect(
      slot().identitySlot(header()),
      isNot(header().identitySlot),
      reason: 'a passphrase seal and a passkey seal are never interchangeable',
    );
  });

  group('adversary', () {
    test('every truncation and trailing byte is refused as malformed', () {
      final wire = slot().toBytes();
      for (var length = 0; length < wire.length; length++) {
        expect(
          () => PasskeySlot.parse(Uint8List.sublistView(wire, 0, length)),
          throwsA(isA<MalformedSyncDataException>()),
          reason: '$length bytes',
        );
      }
      expect(
        () => PasskeySlot.parse(Uint8List.fromList([...wire, 0])),
        throwsA(isA<MalformedSyncDataException>()),
      );
    });

    test('an unknown version is refused', () {
      final wire = slot().toBytes()..[0] = 2;

      expect(
        () => PasskeySlot.parse(wire),
        throwsA(isA<MalformedSyncDataException>()),
      );
    });

    test('a credential id outside what WebAuthn allows is refused', () {
      // version(1) | credential blob: uint32 length then the id.
      for (final length in [0, 15, 1024]) {
        final wire =
            (BytesBuilder()
                  ..addByte(1)
                  ..add(Uint8List(4)..buffer.asByteData().setUint32(0, length))
                  ..add(Uint8List(length))
                  ..add(slot().toBytes().sublist(1 + 4 + 20)))
                .takeBytes();
        expect(
          () => PasskeySlot.parse(wire),
          throwsA(isA<MalformedSyncDataException>()),
          reason: '$length bytes',
        );
      }
    });

    Glados(any.list(any.uint8))
        .test('random bytes never crash the parser', (bytes) {
          try {
            PasskeySlot.parse(Uint8List.fromList(bytes));
          } on MalformedSyncDataException {
            // The only acceptable failure.
          }
        });
  });
}
