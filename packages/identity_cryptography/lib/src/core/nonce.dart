import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'fixed_bytes.dart';

/// XChaCha20-Poly1305 nonce. 24 bytes are large enough to pick at random for
/// every message without tracking counters across offline devices.
@immutable
final class Nonce {
  Nonce.fromBytes(List<int> bytes)
    : _bytes = copyExactly('Nonce', bytes, length);

  static const length = 24;

  final Uint8List _bytes;

  Uint8List get bytes => _bytes.asUnmodifiableView();

  @override
  bool operator ==(Object other) =>
      other is Nonce && bytesEqual(_bytes, other._bytes);

  @override
  int get hashCode => bytesHash(_bytes);
}
