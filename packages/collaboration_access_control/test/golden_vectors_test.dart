import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:collaboration_access_control/collaboration_access_control.dart';
import 'package:test/test.dart';

import 'crypto_support.dart';

/// The vectors the Rust server checks too (server/vectors/ledger.json,
/// written by tool/golden_vectors.dart): the domain must give each case the
/// verdict it was built to have, so client and server never disagree on
/// what enters a membership log or a key bundle stream.
void main() {
  setUpAll(initServices);

  final file = File('../../server/vectors/ledger.json');
  final vectors = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
  final cases = (vectors['cases']! as List).cast<Map<String, Object?>>();

  test('there are vectors', () => expect(cases, hasLength(greaterThan(20))));

  for (final vector in cases) {
    test(vector['name'], () {
      final records = [
        for (final record in vector['records']! as List)
          _bytes(record as String),
      ];
      final (ledger, accepted) = _verify(records);

      expect(accepted, vector['accepted'], reason: 'records accepted');
      if (ledger == null) return;
      expect(
        {
          for (final member in ledger.workspace.members.values)
            member.id.hex: member.role.wireCode,
        },
        {
          for (final member
              in (vector['members']! as List).cast<Map<String, Object?>>())
            member['key']: member['role'],
        },
      );
      expect(ledger.workspace.epoch.value, vector['epoch']);
      for (final (i, bundle)
          in (vector['bundles']! as List)
              .cast<Map<String, Object?>>()
              .indexed) {
        expect(
          _bundleValid(_bytes(bundle['bundle']! as String), ledger),
          bundle['valid'],
          reason: 'bundle $i',
        );
      }
    });
  }
}

/// Verifies the log the way the server does: the first record pins its own
/// founder, every later one must extend the verified log.
(VerifiedLedger?, int) _verify(List<Uint8List> records) {
  VerifiedLedger? ledger;
  for (final wire in records) {
    try {
      final record = MembershipRecord.parse(wire);
      ledger = ledger == null
          ? ledgers.verify(
              [record],
              invitation: Invitation(
                workspace: record.workspace,
                founder: record.author,
              ),
            )
          : ledgers.extend(ledger, [record]);
    } on CollaborationException {
      break;
    }
  }
  return (ledger, ledger?.records.length ?? 0);
}

bool _bundleValid(Uint8List wire, VerifiedLedger ledger) {
  try {
    administration.verify(KeyBundle.parse(wire), ledger: ledger);
    return true;
  } on CollaborationException {
    return false;
  }
}

Uint8List _bytes(String hex) => Uint8List.fromList([
  for (var i = 0; i < hex.length; i += 2)
    int.parse(hex.substring(i, i + 2), radix: 16),
]);
