import 'package:collaboration_access_control/collaboration_access_control.dart';
import 'package:identity_cryptography/identity_cryptography.dart';

import '../core/record_revision.dart';
import '../core/sync_exception.dart';

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

    final head = revision.ledgerHead;
    if (head.sequence >= ledger.records.length) {
      throw const LedgerBehindException();
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
    // A revoked writer still holds the old keys and can cite an old log
    // position, so the right to write is also checked against today's log.
    // An edit they made before removal but synced after is lost with it.
    if (!_writes(ledger.workspace, revision.author)) {
      throw const RejectedRevisionException('author no longer writes');
    }
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
