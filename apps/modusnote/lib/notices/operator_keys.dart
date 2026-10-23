import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:offline_sync/offline_sync.dart';

/// The operator keys the app pins: a service notice counts only if one of
/// them signed it, so the server, which holds none, can withhold a notice
/// but never write or alter one. They ship inside the app, and so in the
/// SHA-256 list of every web bundle.
///
/// Empty for now: service notices are off and the app fetches nothing.
///
/// To pin a key, run from `packages/offline_sync`
///
///     dart run tool/service_notice.dart keygen <key file>
///
/// which keeps the private key sealed under a passphrase in the key file
/// (on the operator's computer only: never in the repository, the CI or
/// the Worker) and prints the public key in hex, then add it here with its
/// `notAfter`, at most two years after the release that pins it:
///
///     (key: '<64 hex digits>', notAfter: '2028-10-23T00:00:00Z'),
///
/// Pin two keys, a primary and a spare kept elsewhere.
/// `test/platform/service_notices_test.dart` fails six months before a
/// `notAfter`, so the key is replaced in time.
const pinnedOperatorKeys = <({String key, String notAfter})>[];

/// [pinnedOperatorKeys], ready for [ServiceNoticeBoard].
List<OperatorKey> operatorKeys([
  List<({String key, String notAfter})> pinned = pinnedOperatorKeys,
]) => [
  for (final (:key, :notAfter) in pinned)
    OperatorKey(
      PublicSigningKey.fromBytes([
        for (var i = 0; i < key.length; i += 2)
          int.parse(key.substring(i, i + 2), radix: 16),
      ]),
      notAfter: DateTime.parse(notAfter),
    ),
];
