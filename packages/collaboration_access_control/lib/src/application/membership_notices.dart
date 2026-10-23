import '../core/membership_notice.dart';
import 'membership_ledger.dart';

/// Use case: the notices of a verified membership log, from the records a
/// device has not shown yet.
abstract final class MembershipNotices {
  /// The notices of the records of [ledger] from sequence [from] on,
  /// oldest first. [from] is how many records were already seen (a mark
  /// the device keeps); one out of range is clamped to the log, so a
  /// strange mark shows at most every record and never fails.
  static List<MembershipNotice> of(VerifiedLedger ledger, {int from = 1}) {
    final length = ledger.records.length;
    final start = from.clamp(1, length);
    return [
      for (var i = start; i < length; i++)
        ?MembershipNotice.between(
          ledger.at(i - 1),
          ledger.records[i],
          ledger.at(i),
        ),
    ];
  }
}
