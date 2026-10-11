import 'package:meta/meta.dart';

import 'cryptography_exception.dart';

/// Argon2id cost parameters. Anything weaker than libsodium's INTERACTIVE
/// preset is unrepresentable, so a vault can never be created with a cheap KDF.
@immutable
final class KdfParameters {
  const KdfParameters._(this.opsLimit, this.memLimitBytes);

  factory KdfParameters.custom({
    required int opsLimit,
    required int memLimitBytes,
  }) {
    if (opsLimit < interactive.opsLimit ||
        memLimitBytes < interactive.memLimitBytes) {
      throw const WeakKdfParametersException();
    }
    return KdfParameters._(opsLimit, memLimitBytes);
  }

  static const interactive = KdfParameters._(2, 64 * 1024 * 1024);
  static const moderate = KdfParameters._(3, 256 * 1024 * 1024);

  final int opsLimit;
  final int memLimitBytes;

  @override
  bool operator ==(Object other) =>
      other is KdfParameters &&
      other.opsLimit == opsLimit &&
      other.memLimitBytes == memLimitBytes;

  @override
  int get hashCode => Object.hash(opsLimit, memLimitBytes);
}
