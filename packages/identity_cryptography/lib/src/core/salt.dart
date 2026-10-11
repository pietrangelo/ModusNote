import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'fixed_bytes.dart';

/// Public, per-derivation randomness for Argon2id (crypto_pwhash_SALTBYTES).
@immutable
final class Salt {
  Salt.fromBytes(List<int> bytes) : _bytes = copyExactly('Salt', bytes, length);

  static const length = 16;

  final Uint8List _bytes;

  Uint8List get bytes => _bytes.asUnmodifiableView();

  @override
  bool operator ==(Object other) =>
      other is Salt && bytesEqual(_bytes, other._bytes);

  @override
  int get hashCode => bytesHash(_bytes);
}
