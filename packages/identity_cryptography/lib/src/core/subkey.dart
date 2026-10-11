import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'cryptography_exception.dart';
import 'fixed_bytes.dart';

/// Domain separation label for subkey derivation (crypto_kdf_CONTEXTBYTES).
///
/// Each purpose gets its own context, so a subkey derived for one purpose
/// can never coincide with a subkey for another, even under the same parent
/// key and id.
@immutable
final class KeyContext {
  KeyContext(this.value) {
    if (!_eightPrintableAscii.hasMatch(value)) {
      throw const InvalidKeyContextException();
    }
  }

  static final _eightPrintableAscii = RegExp(r'^[\x21-\x7E]{8}$');

  final String value;

  @override
  bool operator ==(Object other) => other is KeyContext && other.value == value;

  @override
  int get hashCode => value.hashCode;
}

/// Public selector of one subkey under a parent key (crypto_kdf uint64 id),
/// stored in clear next to whatever the subkey protects.
@immutable
final class SubkeyId {
  SubkeyId.fromBytes(List<int> bytes)
    : _bytes = copyExactly('SubkeyId', bytes, length);

  static const length = 8;

  final Uint8List _bytes;

  Uint8List get bytes => _bytes.asUnmodifiableView();

  @override
  bool operator ==(Object other) =>
      other is SubkeyId && bytesEqual(_bytes, other._bytes);

  @override
  int get hashCode => bytesHash(_bytes);
}
