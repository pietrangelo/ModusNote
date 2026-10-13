import 'package:identity_cryptography/identity_cryptography.dart';

import '../core/collaboration_exception.dart';
import '../core/identifiers.dart';
import '../core/invitation.dart';
import '../core/key_bundle.dart';
import '../core/membership_change.dart';
import '../core/membership_record.dart';
import '../core/role.dart';
import 'group_keyring.dart';
import 'membership_ledger.dart';

/// A signed membership change to publish, with the key grants it requires.
final class MembershipUpdate {
  const MembershipUpdate({
    required this.ledger,
    required this.record,
    this.bundle,
  });

  final VerifiedLedger ledger;
  final MembershipRecord record;
  final KeyBundle? bundle;
}

final class FoundedWorkspace extends MembershipUpdate {
  const FoundedWorkspace({
    required super.ledger,
    required super.record,
    required KeyBundle super.bundle,
    required this.keyring,
  });

  final GroupKeyring keyring;

  Invitation get invitation =>
      Invitation(workspace: record.workspace, founder: record.author);
}

/// Use case: founding, inviting, revoking and GroupKey rotation.
///
/// Every outcome is a signed record and/or a signed [KeyBundle] that the
/// sync server stores as opaque bytes; nothing here trusts the server.
final class WorkspaceAdministration {
  WorkspaceAdministration({
    required this._identities,
    required this._encapsulation,
    required this._envelopes,
  }) : _ledgers = MembershipLedger(_identities);

  final IdentityService _identities;
  final KeyEncapsulation _encapsulation;
  final EnvelopeEncryptor _envelopes;
  final MembershipLedger _ledgers;

  /// The founder also seals epoch 0 to themselves, so a reinstalled device
  /// with the same identity can recover the key from the server.
  FoundedWorkspace found(WorkspaceId id, {required IdentityKeyPair founder}) {
    final ledger = _ledgers.found(id, founder: founder);
    final keyring = GroupKeyring(id)
      ..add(KeyEpoch.initial, _envelopes.generateKey());
    return FoundedWorkspace(
      ledger: ledger,
      record: ledger.records.single,
      keyring: keyring,
      bundle: grant(
        ledger,
        keyring,
        issuer: founder,
        epoch: KeyEpoch.initial,
        recipients: [MemberId.of(founder.publicIdentity)],
      ),
    );
  }

  /// A new member gets every epoch the owner holds, so they can read the
  /// workspace's history, not only what is written from now on.
  MembershipUpdate invite(
    VerifiedLedger ledger,
    GroupKeyring keyring, {
    required IdentityKeyPair owner,
    required PublicIdentity invitee,
    required Role role,
  }) {
    final appended = _ledgers.append(
      ledger,
      MemberInvited(invitee, role),
      author: owner,
    );
    return MembershipUpdate(
      ledger: appended.ledger,
      record: appended.record,
      bundle: _issue(
        appended.ledger,
        keyring,
        issuer: owner,
        grants: [
          for (final epoch in keyring.epochs) (epoch, MemberId.of(invitee)),
        ],
      ),
    );
  }

  /// Removes [member] and rotates at once: a fresh GroupKey for the next
  /// epoch, sealed only to those who remain.
  MembershipUpdate revoke(
    VerifiedLedger ledger,
    GroupKeyring keyring, {
    required IdentityKeyPair owner,
    required MemberId member,
  }) {
    if (member == MemberId.of(owner.publicIdentity)) {
      throw const InvalidMembershipChangeException('use leave to leave');
    }
    final appended = _ledgers.append(
      ledger,
      MemberRevoked(member),
      author: owner,
    );
    return MembershipUpdate(
      ledger: appended.ledger,
      record: appended.record,
      bundle: rotate(appended.ledger, keyring, owner: owner),
    );
  }

  /// A member leaving does not rotate: the leaver would learn the new key.
  /// An owner calls [rotate] once they see the departure.
  MembershipUpdate leave(
    VerifiedLedger ledger, {
    required IdentityKeyPair member,
  }) {
    final appended = _ledgers.append(
      ledger,
      MemberRevoked(MemberId.of(member.publicIdentity)),
      author: member,
    );
    return MembershipUpdate(ledger: appended.ledger, record: appended.record);
  }

  MembershipUpdate changeRole(
    VerifiedLedger ledger, {
    required IdentityKeyPair owner,
    required MemberId member,
    required Role role,
  }) {
    final appended = _ledgers.append(
      ledger,
      RoleChanged(member, role),
      author: owner,
    );
    return MembershipUpdate(ledger: appended.ledger, record: appended.record);
  }

  /// Generates the GroupKey for the current epoch and grants it to every
  /// current member. Refused if this device already holds that epoch.
  KeyBundle rotate(
    VerifiedLedger ledger,
    GroupKeyring keyring, {
    required IdentityKeyPair owner,
  }) {
    final epoch = ledger.workspace.epoch;
    if (keyring.holds(epoch)) {
      throw const InvalidMembershipChangeException('epoch already has a key');
    }
    keyring.add(epoch, _envelopes.generateKey());
    return grant(
      ledger,
      keyring,
      issuer: owner,
      epoch: epoch,
      recipients: ledger.workspace.members.keys.toList(),
    );
  }

  /// Grants one epoch's key, which [keyring] must hold, to [recipients].
  KeyBundle grant(
    VerifiedLedger ledger,
    GroupKeyring keyring, {
    required IdentityKeyPair issuer,
    required KeyEpoch epoch,
    required List<MemberId> recipients,
  }) => _issue(
    ledger,
    keyring,
    issuer: issuer,
    grants: [for (final recipient in recipients) (epoch, recipient)],
  );

  /// Grants every epoch [keyring] holds to [recipient], already a member:
  /// how a device whose admission was cut short gets its keys again.
  KeyBundle grantAll(
    VerifiedLedger ledger,
    GroupKeyring keyring, {
    required IdentityKeyPair issuer,
    required MemberId recipient,
  }) => _issue(
    ledger,
    keyring,
    issuer: issuer,
    grants: [for (final epoch in keyring.epochs) (epoch, recipient)],
  );

  /// Verifies [bundle] and adds the keys it grants to [me] to [keyring].
  ///
  /// The issuer must have been an owner at the log position the bundle
  /// names, and may only grant epochs that existed there: a member revoked
  /// later cannot use an old position to hand out a key for an epoch that
  /// began after their removal.
  void accept(
    KeyBundle bundle, {
    required VerifiedLedger ledger,
    required IdentityKeyPair me,
    required GroupKeyring keyring,
  }) {
    final state = ledger.at(bundle.atSequence);
    if (bundle.workspace != state.id || keyring.workspace != state.id) {
      throw const TamperedWorkspaceDataException('bundle for another space');
    }
    if (!state.isOwner(bundle.issuer)) {
      throw const TamperedWorkspaceDataException('issuer is not an owner');
    }
    try {
      _identities.verify(
        bundle.signedMessage,
        signature: bundle.signature,
        signer: bundle.issuer.signingKey,
      );
    } on InvalidSignatureException {
      throw const TamperedWorkspaceDataException('bad bundle signature');
    }
    final myId = MemberId.of(me.publicIdentity);
    for (final grant in bundle.grants.where((g) => g.recipient == myId)) {
      if (grant.epoch.value > state.epoch.value || !state.isMember(myId)) {
        throw const TamperedWorkspaceDataException('grant beyond authority');
      }
      final SymmetricKey key;
      try {
        key = _encapsulation.open(
          grant.sealedKey,
          recipient: me,
          associatedData: GroupKeyGrant.associatedData(
            state.id,
            grant.epoch,
            myId,
          ),
        );
      } on AuthenticationTagMismatchException {
        throw const TamperedWorkspaceDataException('grant does not open');
      }
      keyring.add(grant.epoch, key);
    }
  }

  KeyBundle _issue(
    VerifiedLedger ledger,
    GroupKeyring keyring, {
    required IdentityKeyPair issuer,
    required List<(KeyEpoch, MemberId)> grants,
  }) {
    final workspace = ledger.workspace;
    final sealed = [
      for (final (epoch, recipient) in grants)
        GroupKeyGrant(
          recipient: recipient,
          epoch: epoch,
          sealedKey: _encapsulation.seal(
            keyring.keyFor(epoch),
            recipient:
                (workspace.member(recipient) ??
                        (throw const NotAMemberException()))
                    .identity
                    .encryptionKey,
            associatedData: GroupKeyGrant.associatedData(
              workspace.id,
              epoch,
              recipient,
            ),
          ),
        ),
    ];
    final issuerId = MemberId.of(issuer.publicIdentity);
    return KeyBundle(
      workspace: workspace.id,
      atSequence: workspace.sequence,
      issuer: issuerId,
      grants: sealed,
      signature: _identities.sign(
        KeyBundle.signable(
          workspace: workspace.id,
          atSequence: workspace.sequence,
          issuer: issuerId,
          grants: sealed,
        ),
        signer: issuer,
      ),
    );
  }
}
