import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:offline_sync/offline_sync.dart';

/// The operator keys the app pins: a service notice counts only if one of
/// them signed it, so the server, which holds none, can withhold a notice
/// but never write or alter one. They ship inside the app, and so in the
/// SHA-256 list of every web bundle.
///
/// With the list empty, service notices are off and the app fetches
/// nothing.
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
const pinnedOperatorKeys = <({String key, String notAfter})>[
  // Primary, pinned 2026-10-23.
  (
    key: '3a9ad26e8b4c36953876d84a6b4e22472a4fa2c47ff6e1e9e50040512cf007b2',
    notAfter: '2028-10-23T00:00:00Z',
  ),
  // Spare, kept elsewhere, pinned 2026-10-23.
  (
    key: 'cc13eb43c64b429f4ce750f5610da1b559352ddae7b25c724b8bd215da352b34',
    notAfter: '2028-10-23T00:00:00Z',
  ),
];

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
