import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'cryptography_exception.dart';
import 'encrypted_envelope.dart';
import 'fixed_bytes.dart';
import 'nonce.dart';

/// Ed25519 verification key: who signed a membership change or a KeyBundle.
@immutable
final class PublicSigningKey {
  PublicSigningKey.fromBytes(List<int> bytes)
    : _bytes = copyExactly('PublicSigningKey', bytes, length);

  static const length = 32;

  final Uint8List _bytes;

  Uint8List get bytes => _bytes.asUnmodifiableView();

  /// Lower-case hex, used where the key doubles as a stable identifier.
  String get hex =>
      _bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

  @override
  bool operator ==(Object other) =>
      other is PublicSigningKey && bytesEqual(_bytes, other._bytes);

  @override
  int get hashCode => bytesHash(_bytes);
}

/// X-Wing (ML-KEM-768 + X25519) encapsulation key.
///
/// A hybrid KEM, because a GroupKey sealed today protects notes for years:
/// ciphertext recorded now stays safe against a future quantum attacker as
/// long as ML-KEM holds, and against today's attacker as long as X25519
/// holds.
@immutable
final class PublicEncryptionKey {
  PublicEncryptionKey.fromBytes(List<int> bytes)
    : _bytes = copyExactly('PublicEncryptionKey', bytes, length);

  static const length = 1216;

  final Uint8List _bytes;

  Uint8List get bytes => _bytes.asUnmodifiableView();

  @override
  bool operator ==(Object other) =>
      other is PublicEncryptionKey && bytesEqual(_bytes, other._bytes);

  @override
  int get hashCode => bytesHash(_bytes);
}

@immutable
final class Signature {
  Signature.fromBytes(List<int> bytes)
    : _bytes = copyExactly('Signature', bytes, length);

  static const length = 64;

  final Uint8List _bytes;

  Uint8List get bytes => _bytes.asUnmodifiableView();

  @override
  bool operator ==(Object other) =>
      other is Signature && bytesEqual(_bytes, other._bytes);

  @override
  int get hashCode => bytesHash(_bytes);
}

/// The public half of a device's identity, shared with whoever invites it.
@immutable
final class PublicIdentity {
  const PublicIdentity({required this.signingKey, required this.encryptionKey});

  factory PublicIdentity.parse(List<int> wire) {
    final bytes = copyExactly('PublicIdentity', wire, length);
    return PublicIdentity(
      signingKey: PublicSigningKey.fromBytes(
        Uint8List.sublistView(bytes, 0, PublicSigningKey.length),
      ),
      encryptionKey: PublicEncryptionKey.fromBytes(
        Uint8List.sublistView(bytes, PublicSigningKey.length),
      ),
    );
  }

  static const length = PublicSigningKey.length + PublicEncryptionKey.length;

  final PublicSigningKey signingKey;
  final PublicEncryptionKey encryptionKey;

  Uint8List toBytes() =>
      Uint8List.fromList([...signingKey.bytes, ...encryptionKey.bytes]);

  @override
  bool operator ==(Object other) =>
      other is PublicIdentity &&
      other.signingKey == signingKey &&
      other.encryptionKey == encryptionKey;

  @override
  int get hashCode => Object.hash(signingKey, encryptionKey);
}

/// A [SymmetricKey] sealed to one recipient: `X-Wing ciphertext | envelope`.
///
/// The length is fixed because the payload is always one 32-byte key, so a
/// parser never has to trust a length field from the wire.
@immutable
final class SealedKey {
  SealedKey({required List<int> encapsulation, required this.envelope})
    : _encapsulation = copyExactly(
        'SealedKey.encapsulation',
        encapsulation,
        encapsulationLength,
      ) {
    if (envelope.ciphertext.length != _ciphertextLength) {
      throw const MalformedEnvelopeException('sealed key has wrong length');
    }
  }

  factory SealedKey.parse(Uint8List wire) {
    if (wire.length != length) {
      throw const MalformedEnvelopeException('sealed key has wrong length');
    }
    return SealedKey(
      encapsulation: Uint8List.sublistView(wire, 0, encapsulationLength),
      envelope: EncryptedEnvelope.parse(
        Uint8List.sublistView(wire, encapsulationLength),
      ),
    );
  }

  static const encapsulationLength = 1120;
  static const keyLength = 32;
  static const _ciphertextLength = keyLength + EncryptedEnvelope.tagLength;
  static const length =
      encapsulationLength + 1 + Nonce.length + _ciphertextLength;

  final Uint8List _encapsulation;
  final EncryptedEnvelope envelope;

  Uint8List get encapsulation => _encapsulation.asUnmodifiableView();

  Uint8List toBytes() =>
      Uint8List.fromList([..._encapsulation, ...envelope.toBytes()]);

  @override
  bool operator ==(Object other) =>
      other is SealedKey &&
      other.envelope == envelope &&
      bytesEqual(_encapsulation, other._encapsulation);

  @override
  int get hashCode => Object.hash(envelope, bytesHash(_encapsulation));
}
