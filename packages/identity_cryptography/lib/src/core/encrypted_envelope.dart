import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'associated_data.dart';
import 'cryptography_exception.dart';
import 'fixed_bytes.dart';
import 'nonce.dart';

/// Wire format of every symmetric ciphertext: `version | nonce | ciphertext`,
/// where the ciphertext carries the 16-byte Poly1305 tag.
@immutable
final class EncryptedEnvelope {
  EncryptedEnvelope({required this.nonce, required List<int> ciphertext})
    : _ciphertext = Uint8List.fromList(ciphertext) {
    if (_ciphertext.length < tagLength) {
      throw const MalformedEnvelopeException('ciphertext shorter than tag');
    }
  }

  factory EncryptedEnvelope.parse(Uint8List wire) {
    if (wire.length < _headerLength + tagLength) {
      throw const MalformedEnvelopeException('envelope too short');
    }
    if (wire[0] != currentVersion) {
      throw const MalformedEnvelopeException('unsupported envelope version');
    }
    return EncryptedEnvelope(
      nonce: Nonce.fromBytes(Uint8List.sublistView(wire, 1, _headerLength)),
      ciphertext: Uint8List.sublistView(wire, _headerLength),
    );
  }

  static const currentVersion = 1;
  static const tagLength = 16;
  static const _headerLength = 1 + Nonce.length;

  final Nonce nonce;
  final Uint8List _ciphertext;

  Uint8List get ciphertext => _ciphertext.asUnmodifiableView();

  /// The bytes every adapter must authenticate: the format version is bound
  /// in, so a downgrade to a future weaker format cannot be spliced in.
  static Uint8List authenticatedData(AssociatedData associatedData) =>
      Uint8List.fromList([currentVersion, ...associatedData.bytes]);

  Uint8List toBytes() =>
      Uint8List.fromList([currentVersion, ...nonce.bytes, ..._ciphertext]);

  @override
  bool operator ==(Object other) =>
      other is EncryptedEnvelope &&
      other.nonce == nonce &&
      bytesEqual(_ciphertext, other._ciphertext);

  @override
  int get hashCode => Object.hash(nonce, bytesHash(_ciphertext));
}
