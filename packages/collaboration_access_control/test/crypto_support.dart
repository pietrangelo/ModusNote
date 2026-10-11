import 'dart:convert';
import 'dart:typed_data';

import 'package:collaboration_access_control/collaboration_access_control.dart';
import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:identity_cryptography_adapters/identity_cryptography_adapters.dart';
import 'package:sodium/sodium_sumo.dart';

late SodiumSumo sodium;
late IdentityService identities;
late MembershipLedger ledgers;
late WorkspaceAdministration administration;
late WorkspaceContentCipher contents;

Future<void> initServices() async {
  sodium = await SodiumSumoInit.init();
  identities = SodiumIdentityService(sodium);
  ledgers = MembershipLedger(identities);
  administration = WorkspaceAdministration(
    identities: identities,
    encapsulation: SodiumKeyEncapsulation(sodium),
    envelopes: SodiumEnvelopeEncryptor(sodium),
  );
  contents = WorkspaceContentCipher(SodiumEnvelopeEncryptor(sodium));
}

Uint8List utf8Bytes(String text) => Uint8List.fromList(utf8.encode(text));

/// One device taking part in a workspace: its identity, what it has
/// verified of the membership log, and the GroupKeys it was granted.
final class Device {
  Device(this.name) : identity = identities.generateIdentity();

  final String name;
  final IdentityKeyPair identity;
  late VerifiedLedger ledger;
  GroupKeyring? _keyring;

  GroupKeyring get keyring => _keyring!;
  set keyring(GroupKeyring value) => _keyring = value;

  MemberId get id => MemberId.of(identity.publicIdentity);
  PublicIdentity get publicIdentity => identity.publicIdentity;

  /// Joins from the invitation (pins the founder) and what the server holds.
  void join(Invitation invitation, List<MembershipRecord> log) {
    ledger = ledgers.verify(log, invitation: invitation);
    keyring = GroupKeyring(invitation.workspace);
  }

  void sync(List<MembershipRecord> log, List<KeyBundle> bundles) {
    ledger = ledgers.extend(ledger, log.skip(ledger.records.length).toList());
    for (final bundle in bundles) {
      administration.accept(
        bundle,
        ledger: ledger,
        me: identity,
        keyring: keyring,
      );
    }
  }

  void dispose() {
    identity.dispose();
    _keyring?.dispose();
  }
}
