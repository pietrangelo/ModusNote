import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'fixed_bytes.dart';

/// A collision-resistant digest of some bytes (BLAKE2b-256): names exactly
/// one byte string, even to someone who holds every key.
@immutable
final class ContentDigest {
  ContentDigest.fromBytes(List<int> bytes)
    : _bytes = copyExactly('ContentDigest', bytes, length);

  static const length = 32;

  final Uint8List _bytes;

  Uint8List get bytes => _bytes.asUnmodifiableView();

  @override
  bool operator ==(Object other) =>
      other is ContentDigest && bytesEqual(_bytes, other._bytes);

  @override
  int get hashCode => bytesHash(_bytes);
}
