import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:meta/meta.dart';

import 'fingerprint.dart';

/// What two devices of the same workspace compare to learn that the server
/// shows them the same membership log: how many records it has, and the
/// start of the last one's signature, which through the chain of
/// signatures covers every record before it.
///
/// A server cannot forge or alter records, but it can withhold them from
/// one device; two screens that show different fingerprints reveal it.
@immutable
final class LedgerFingerprint {
  const LedgerFingerprint({required this.records, required this.signature});

  LedgerFingerprint.after(int records, Signature last)
    : this(records: records, signature: fingerprintOf(last.bytes));

  final int records;

  /// Four groups of four upper-case hex digits.
  final String signature;

  @override
  bool operator ==(Object other) =>
      other is LedgerFingerprint &&
      other.records == records &&
      other.signature == signature;

  @override
  int get hashCode => Object.hash(records, signature);

  @override
  String toString() => '$records · $signature';
}
