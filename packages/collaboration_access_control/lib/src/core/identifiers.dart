import 'dart:math';
import 'dart:typed_data';

import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:meta/meta.dart';

import 'collaboration_exception.dart';
import 'fingerprint.dart';

/// Opaque, random workspace identifier; the only workspace data the sync
/// server sees in clear.
@immutable
final class WorkspaceId {
  WorkspaceId._(this.hex);

  factory WorkspaceId.parse(String hex) {
    if (!_hex32.hasMatch(hex)) {
      throw const InvalidWorkspaceValueException(
        'WorkspaceId must be 32 lower-case hex digits',
      );
    }
    return WorkspaceId._(hex);
  }

  factory WorkspaceId.random(Random random) => WorkspaceId._(
    List.generate(
      length,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join(),
  );

  static const length = 16;
  static final _hex32 = RegExp(r'^[0-9a-f]{32}$');

  final String hex;

  Uint8List get bytes => Uint8List.fromList([
    for (var i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ]);

  @override
  bool operator ==(Object other) => other is WorkspaceId && other.hex == hex;

  @override
  int get hashCode => hex.hashCode;

  @override
  String toString() => hex;
}

/// A member is identified by its signing key, not by a name or number the
/// server assigns, so the server cannot remap who is who.
extension type const MemberId(PublicSigningKey signingKey) {
  MemberId.of(PublicIdentity identity) : this(identity.signingKey);

  String get hex => signingKey.hex;

  /// The start of the signing key, in four groups: devices have no names,
  /// so this is how two screens are compared.
  String get fingerprint => fingerprintOf(signingKey.bytes);
}

/// Generation of the GroupKey. It advances whenever someone leaves, so what
/// is written afterwards is sealed under a key the departed never had.
extension type const KeyEpoch._(int value) {
  factory KeyEpoch(int value) {
    if (value < 0 || value > maxValue) {
      throw const InvalidWorkspaceValueException('KeyEpoch out of range');
    }
    return KeyEpoch._(value);
  }

  static const initial = KeyEpoch._(0);
  static const maxValue = 0xFFFFFFFF;

  KeyEpoch get next => KeyEpoch(value + 1);
}
