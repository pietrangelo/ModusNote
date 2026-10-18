import 'package:collaboration_access_control/collaboration_access_control.dart';
import 'package:identity_cryptography/identity_cryptography.dart';

import '../core/record_revision.dart';
import '../core/sync_exception.dart';
import '../core/version_vector.dart';

/// Use case: decides whether a revision pulled from the server may be
/// applied.
///
/// The GroupKey only proves the writer is, or was, in the workspace. These
/// checks add who wrote it and whether they were allowed to, measured
/// against the membership log this device verified itself.
final class RevisionAuthenticator {
  RevisionAuthenticator(this._identities);

  final IdentityService _identities;

  void authenticate(
    SignedRevision signed, {
    required SealedRowContext row,
    required VerifiedLedger ledger,
  }) {
    final revision = signed.revision;
    if (revision.record != row.record ||
        revision.workspace != ledger.workspace.id) {
      throw const RejectedRevisionException('revision for another record');
    }
    try {
      _identities.verify(
        revision.signable,
        signature: signed.signature,
        signer: revision.author.signingKey,
      );
    } on InvalidSignatureException {
      throw const RejectedRevisionException('bad revision signature');
    }

    // Today's log first: a row from someone who cannot write now is only
    // skipped, never taken as evidence of a hidden or forked log, which
    // stops the sync for everyone until the log is explained.
    final writesNow = _writes(ledger.workspace, revision.author);
    final head = revision.ledgerHead;
    if (head.sequence >= ledger.records.length) {
      throw const LedgerBehindException();
    }
    if (!writesNow) {
      throw const RejectedRevisionException('author no longer writes');
    }
    if (ledger.records[head.sequence].signature != head.signature) {
      throw const LedgerRollbackException();
    }

    final then = ledger.at(head.sequence);
    if (!_writes(then, revision.author)) {
      throw const RejectedRevisionException('author could not write then');
    }
    if (row.epoch != then.epoch) {
      throw const RejectedRevisionException('sealed under the wrong epoch');
    }
    // Every counter an honest device writes is far below this, and the
    // members it names are in the log: a vector beyond either would
    // overflow the wire format at the next local edit of the record.
    if (!revision.version.members.every(
          (member) => _everMember(ledger, member),
        ) ||
        revision.version.highest > VersionVector.maxCounter) {
      throw const RejectedRevisionException('implausible version');
    }
  }

  /// Whether a [RejectedRevisionException] is the answer when [signed]
  /// still cites a log position the server cannot show: its author does
  /// not write today, so it proves nothing about the log.
  bool rejectsUnknownHead(SignedRevision signed, VerifiedLedger ledger) =>
      !_writes(ledger.workspace, signed.revision.author);

  static bool _everMember(VerifiedLedger ledger, MemberId member) {
    for (var sequence = ledger.records.length - 1; sequence >= 0; sequence--) {
      if (ledger.at(sequence).isMember(member)) return true;
    }
    return false;
  }

  static bool _writes(Workspace workspace, MemberId author) =>
      workspace.member(author)?.role.writesContent ?? false;
}

/// The clear-text facts about the row a revision arrived in.
final class SealedRowContext {
  const SealedRowContext({required this.record, required this.epoch});

  final RecordId record;
  final KeyEpoch epoch;
}
