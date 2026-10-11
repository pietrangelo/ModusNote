import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'fixed_bytes.dart';

/// Authenticated-but-not-encrypted context bound into every envelope.
///
/// Binding the envelope to what it belongs to (e.g. which entry) makes a
/// ciphertext copied onto another record fail authentication, which is the
/// cut-and-paste attack a zero-knowledge server could otherwise mount.
@immutable
final class AssociatedData {
  const AssociatedData._(this._bytes);

  factory AssociatedData.forContext(String context, String identifier) {
    final builder = BytesBuilder(copy: false);
    for (final part in [context, identifier]) {
      final encoded = utf8.encode(part);
      builder
        ..add(_uint32(encoded.length))
        ..add(encoded);
    }
    return AssociatedData._(builder.takeBytes());
  }

  static final empty = AssociatedData._(Uint8List(0));

  final Uint8List _bytes;

  Uint8List get bytes => _bytes.asUnmodifiableView();

  static Uint8List _uint32(int value) =>
      Uint8List(4)..buffer.asByteData().setUint32(0, value);

  @override
  bool operator ==(Object other) =>
      other is AssociatedData && bytesEqual(_bytes, other._bytes);

  @override
  int get hashCode => bytesHash(_bytes);
}
