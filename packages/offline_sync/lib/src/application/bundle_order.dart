import 'package:collaboration_access_control/collaboration_access_control.dart';

import '../core/sync_row.dart';

/// Whether the membership record [bundle] names can still arrive, for a
/// bundle read before this device has that record.
///
/// Every genuine bundle goes out after its record, so the server's [heads],
/// asked after the bundles were read, already count that record; one they
/// do not count was forged by an account that may append bundles, and
/// waiting for it would hold back every bundle after it. A server without
/// heads cannot say, so the bundle waits.
Future<bool> recordWillCome(KeyBundle bundle, Future<SyncHeads?> heads) async {
  final known = await heads;
  return known == null || bundle.atSequence < known.membership;
}
