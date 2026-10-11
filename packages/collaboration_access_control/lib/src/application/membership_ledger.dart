import 'package:identity_cryptography/identity_cryptography.dart';

import '../core/collaboration_exception.dart';
import '../core/identifiers.dart';
import '../core/invitation.dart';
import '../core/membership_change.dart';
import '../core/membership_record.dart';
import '../core/workspace.dart';

/// A membership log in which every record has been checked: signature,
/// chain, workspace, and the author's authority at that point.
///
/// Only [MembershipLedger] creates one, so holding a [VerifiedLedger] is
/// proof that the checks ran.
final class VerifiedLedger {
  VerifiedLedger._(List<MembershipRecord> records, List<Workspace> states)
    : records = List.unmodifiable(records),
      _states = List.unmodifiable(states);

  final List<MembershipRecord> records;
  final List<Workspace> _states;

  Workspace get workspace => _states.last;

  /// The membership as it stood right after record [sequence].
  Workspace at(int sequence) {
    if (sequence < 0 || sequence >= _states.length) {
      throw const TamperedWorkspaceDataException('unknown log position');
    }
    return _states[sequence];
  }
}

/// Use case: builds and verifies the signed membership log.
final class MembershipLedger {
  MembershipLedger(this._identities);

  final IdentityService _identities;

  VerifiedLedger found(WorkspaceId id, {required IdentityKeyPair founder}) {
    final founderId = MemberId.of(founder.publicIdentity);
    final record = _signed(
      founder,
      workspace: id,
      sequence: 0,
      author: founderId,
      previous: null,
      change: WorkspaceFounded(founder.publicIdentity),
    );
    return VerifiedLedger._(
      [record],
      [Workspace.found(id, founder: founder.publicIdentity)],
    );
  }

  /// Verifies a whole log fetched from the server against the founder the
  /// invitee pinned from their [Invitation].
  VerifiedLedger verify(
    List<MembershipRecord> records, {
    required Invitation invitation,
  }) {
    if (records.isEmpty) {
      throw const TamperedWorkspaceDataException('empty membership log');
    }
    final genesis = records.first;
    final founder = switch (genesis.change) {
      WorkspaceFounded(:final founder)
          when MemberId.of(founder) == invitation.founder =>
        founder,
      _ => null,
    };
    if (founder == null ||
        genesis.sequence != 0 ||
        genesis.workspace != invitation.workspace ||
        genesis.author != invitation.founder) {
      throw const TamperedWorkspaceDataException('log not founded as invited');
    }
    _verifySignature(genesis);
    final founded = VerifiedLedger._(
      [genesis],
      [Workspace.found(genesis.workspace, founder: founder)],
    );
    return extend(founded, records.sublist(1));
  }

  /// Appends records fetched after [ledger] was verified.
  VerifiedLedger extend(VerifiedLedger ledger, List<MembershipRecord> newer) {
    final records = [...ledger.records];
    final states = [...ledger._states];
    for (final record in newer) {
      final last = records.last;
      if (record.workspace != last.workspace ||
          record.sequence != last.sequence + 1 ||
          record.previous != last.signature) {
        throw const TamperedWorkspaceDataException('broken membership chain');
      }
      _verifySignature(record);
      try {
        states.add(states.last.apply(record.change, author: record.author));
      } on CollaborationException {
        throw const TamperedWorkspaceDataException(
          'record breaks the membership rules',
        );
      }
      records.add(record);
    }
    return VerifiedLedger._(records, states);
  }

  /// Signs [change] as [author] and appends it. Membership rules are
  /// checked before signing, so an invalid change is never signed.
  ({VerifiedLedger ledger, MembershipRecord record}) append(
    VerifiedLedger ledger,
    MembershipChange change, {
    required IdentityKeyPair author,
  }) {
    final authorId = MemberId.of(author.publicIdentity);
    final next = ledger.workspace.apply(change, author: authorId);
    final last = ledger.records.last;
    final record = _signed(
      author,
      workspace: last.workspace,
      sequence: last.sequence + 1,
      author: authorId,
      previous: last.signature,
      change: change,
    );
    return (
      ledger: VerifiedLedger._(
        [...ledger.records, record],
        [...ledger._states, next],
      ),
      record: record,
    );
  }

  MembershipRecord _signed(
    IdentityKeyPair signer, {
    required WorkspaceId workspace,
    required int sequence,
    required MemberId author,
    required Signature? previous,
    required MembershipChange change,
  }) => MembershipRecord(
    workspace: workspace,
    sequence: sequence,
    author: author,
    previous: previous,
    change: change,
    signature: _identities.sign(
      MembershipRecord.signable(
        workspace: workspace,
        sequence: sequence,
        author: author,
        previous: previous,
        change: change,
      ),
      signer: signer,
    ),
  );

  void _verifySignature(MembershipRecord record) {
    try {
      _identities.verify(
        record.signedMessage,
        signature: record.signature,
        signer: record.author.signingKey,
      );
    } on InvalidSignatureException {
      throw const TamperedWorkspaceDataException('bad record signature');
    }
  }
}
