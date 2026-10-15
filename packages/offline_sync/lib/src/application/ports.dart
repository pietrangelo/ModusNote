import 'package:collaboration_access_control/collaboration_access_control.dart';
import 'package:identity_cryptography/identity_cryptography.dart';

import '../core/device_link.dart';
import '../core/outbox.dart';
import '../core/passkey_slot.dart';
import '../core/record_revision.dart';
import '../core/sync_row.dart';
import '../core/vault_header.dart';

/// Port: the zero-knowledge sync server (Supabase in production). Every
/// method throws [ServerUnavailableException] when it cannot be reached.
///
/// All three streams are append-only for clients: the server never
/// overwrites a row, and conflicts are resolved by the clients. The one
/// removal is the writer's: a pushed row may name the rows of its record it
/// supersedes ([SealedRow.supersedes]), and the server drops them.
abstract interface class SyncServer {
  /// Registers [workspace] for this account. Idempotent: a workspace this
  /// account already registered is not an error.
  Future<void> createWorkspace(WorkspaceId workspace);

  /// Appends one signed record to the workspace's membership log. The
  /// server holds each sequence number once.
  Future<void> appendMembership(MembershipRecord record);

  /// Appends [rows], then drops the rows each one supersedes.
  Future<void> push(WorkspaceId workspace, List<SealedRow> rows);

  /// The newest position of each stream, in one request, so a sync that
  /// finds nothing new costs one question instead of three. Null when the
  /// server cannot tell (an older deployment): the device then asks for
  /// every stream. A server that lies here can only delay what it could
  /// already withhold.
  Future<SyncHeads?> heads(WorkspaceId workspace);

  /// Rows appended after position [after], each with its own position;
  /// superseded rows are gone, so positions may skip.
  Future<List<PulledRow>> pull(WorkspaceId workspace, {required int after});

  /// Membership records from sequence [from] on.
  Future<List<MembershipRecord>> membership(
    WorkspaceId workspace, {
    required int from,
  });

  Future<List<(int, KeyBundle)>> keyBundles(
    WorkspaceId workspace, {
    required int after,
  });

  /// Appends a signed bundle of GroupKey grants to its workspace.
  Future<void> appendKeyBundle(KeyBundle bundle);
}

/// Port: where two devices of the same account meet to link (Supabase in
/// production). The server relays two sealed messages and learns nothing
/// but their size and the link's random id; every method throws
/// [ServerUnavailableException] when it cannot be reached.
abstract interface class DeviceLinkChannel {
  Future<void> postOffer(LinkOffer offer);

  /// The newest offer this account posted in the last few minutes.
  Future<LinkOffer?> latestOffer();

  Future<void> postAnswer(LinkAnswer answer);

  /// The answers posted for [link], oldest first.
  Future<List<LinkAnswer>> answers(LinkId link);

  /// Removes what was posted for [link], once it is done with.
  Future<void> close(LinkId link);
}

/// Port: where an owner and another person's device meet to join (Supabase
/// in production). Like [DeviceLinkChannel], but across accounts: the offer
/// is found by its lookup, and its answers are read by the account that
/// posted it. Every method throws [ServerUnavailableException] when the
/// server cannot be reached.
abstract interface class InviteChannel {
  Future<void> postInvite(InviteOffer offer);

  /// The newest offer posted under [lookup] in the last few minutes.
  Future<InviteOffer?> invite(String lookup);

  Future<void> postInviteAnswer(InviteAnswer answer);

  /// The answers to this account's offer under [lookup], oldest first.
  Future<List<InviteAnswer>> inviteAnswers(String lookup);

  /// Removes the offer under [lookup] and its answers.
  Future<void> closeInvite(String lookup);
}

/// Port: which server account each member signs in with, so that removing
/// a member also shuts its account out once no other member uses it. Every
/// method throws [ServerUnavailableException] when the server cannot be
/// reached.
abstract interface class MemberAccounts {
  /// Lets [account] (this device's own when null) into [workspace] and
  /// records that [member] signs in with it; [manages] lets it admit and
  /// remove others. Safe to repeat.
  Future<void> admitMember(
    WorkspaceId workspace,
    MemberId member, {
    AccountId? account,
    bool manages = false,
  });

  /// Forgets [member]'s account and removes it from [workspace] once no
  /// other member uses it; this device's own account always stays. Safe to
  /// repeat.
  Future<void> removeMember(WorkspaceId workspace, MemberId member);
}

enum SyncStream {
  rows,
  keyBundles,

  /// How many records of the membership log the server is known to hold.
  membership,
}

/// Port: the local database (SQLite, native or WASM). It is only ever
/// handed sealed data.
abstract interface class LocalRecordStore {
  Future<EncryptedEnvelope?> load(RecordId id);

  Future<List<RecordId>> recordIds();

  Future<void> save(RecordId id, EncryptedEnvelope sealed);

  Future<Outbox> loadOutbox();

  Future<void> saveOutbox(Outbox outbox);

  Future<int> loadCursor(SyncStream stream);

  Future<void> saveCursor(SyncStream stream, int cursor);

  /// The lowest position of a row of [id] this device pulled and could not
  /// open (its GroupKey was missing), if any.
  Future<int?> loadUnreadable(RecordId id);

  /// Remembers that the row of [id] at [position] could not be opened;
  /// only the lowest such position is kept.
  Future<void> markUnreadable(RecordId id, int position);
}

/// Port: where the device keeps its vault header and the signed log of its
/// personal workspace, so the vault reopens offline.
///
/// None of it is trusted on load: the header only opens with the right
/// passphrase, and the log is re-verified against the founder it pins.
abstract interface class VaultStore {
  Future<VaultHeader?> loadHeader();

  /// Writes the header and the founding log together, all or nothing.
  Future<void> create(
    VaultHeader header, {
    required List<MembershipRecord> membership,
    required List<KeyBundle> bundles,
  });

  Future<List<MembershipRecord>> loadMembership();

  Future<List<KeyBundle>> loadKeyBundles();

  /// Keeps membership records verified after the vault was created; a
  /// sequence already stored is left as it is.
  Future<void> appendMembership(List<MembershipRecord> records);

  /// Keeps key bundles that granted this device GroupKeys after the vault
  /// was created.
  Future<void> appendKeyBundles(List<KeyBundle> bundles);

  /// The passkey enrolled on this device, if any.
  Future<PasskeySlot?> loadPasskey();

  /// Stores [slot], replacing any earlier one. Throws [NoVaultException]
  /// when there is no vault for it to open.
  Future<void> savePasskey(PasskeySlot slot);

  Future<void> removePasskey();

  /// A device setting sealed under the local key, if one is stored.
  Future<EncryptedEnvelope?> loadSetting(String name);

  /// Stores [sealed] under [name], or removes the setting when null.
  Future<void> saveSetting(String name, EncryptedEnvelope? sealed);
}

/// Port: wall-clock time, used only to order concurrent edits.
abstract interface class Clock {
  DateTime now();
}
