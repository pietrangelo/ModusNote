import 'package:collaboration_access_control/collaboration_access_control.dart';
import 'package:identity_cryptography/identity_cryptography.dart';

import '../core/invite.dart';
import '../core/outbox.dart';
import '../core/passkey_slot.dart';
import '../core/record_revision.dart';
import '../core/sync_row.dart';
import '../core/vault_header.dart';
import '../core/vault_shelf.dart';
import 'request_signer.dart';

/// Port: the zero-knowledge sync server (our Worker on Durable Objects in
/// production), as one device sees it: every request is signed by that
/// device ([RequestSigner]) and admitted only for a member of the
/// workspace's verified log. Every method throws
/// [ServerUnavailableException] when the server cannot be reached, or does
/// not admit the device (yet).
///
/// All three streams are append-only for clients: the server never
/// overwrites a row, and conflicts are resolved by the clients. The one
/// removal is the writer's: a pushed row may name the rows of its record it
/// supersedes ([SealedRow.supersedes]), and the server drops them.
abstract interface class SyncServer {
  /// Which server this is. A server with another id starts empty: a vault
  /// that synced elsewhere publishes itself there again.
  Future<String> serverId();

  /// Registers a workspace with the start of its log: its first records,
  /// up to the one that admits this device (the founder sends only the
  /// first), which the server verifies as it would one by one. Idempotent:
  /// the same first record again is not an error; another first record
  /// already holding the id is a [LedgerRollbackException].
  Future<void> createWorkspace(List<MembershipRecord> start);

  /// Deletes the workspace from the server, with its rows, log, bundles
  /// and blobs; an owner's call. Nothing on any device changes. A
  /// workspace already gone is not an error.
  Future<void> deleteWorkspace(WorkspaceId workspace);

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

/// Port: where an owner and a device that knows a code meet to join: a
/// device of the owner's or another person's. The offer is found by its
/// lookup; only the owner who posted it reads its answers and closes it.
/// Every method throws [ServerUnavailableException] when the server cannot
/// be reached.
abstract interface class InviteChannel {
  /// Posts [offer] for [workspace], whose owner this device must be. Throws
  /// [LookupTakenException] when another offer holds the lookup.
  Future<void> postInvite(WorkspaceId workspace, InviteOffer offer);

  /// The newest offer posted under [lookup] in the last few minutes.
  Future<InviteOffer?> invite(String lookup);

  Future<void> postInviteAnswer(InviteAnswer answer);

  /// The answers to this device's offer under [lookup], oldest first.
  Future<List<InviteAnswer>> inviteAnswers(String lookup);

  /// Removes the offer under [lookup] and its answers.
  Future<void> closeInvite(String lookup);
}

/// Port: reaches the sync server as one device.
abstract interface class SyncGateway {
  /// The server, every request signed by [signer]'s device.
  SyncServer server(RequestSigner signer);

  /// Codes: reading an offer and answering it need no signature (the
  /// device has no workspace yet); posting one, reading its answers and
  /// closing it need [signer], the owner's.
  InviteChannel invites(RequestSigner? signer);
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

  /// Every record of the workspace, in one read.
  Future<Map<RecordId, EncryptedEnvelope>> loadAll();

  Future<void> save(RecordId id, EncryptedEnvelope sealed);

  Future<Outbox> loadOutbox();

  /// Adds [row] to the outbox as [Outbox.enqueue] does: it replaces a
  /// queued row of the same record in place, or goes last.
  Future<void> queue(SealedRow row);

  /// Drops these rows once the server holds them; a row queued since for
  /// the same record stays.
  Future<void> unqueue(Iterable<SealedRow> pushed);

  Future<int> loadCursor(SyncStream stream);

  Future<void> saveCursor(SyncStream stream, int cursor);

  /// The lowest position of a row of [id] this device pulled and could not
  /// open (its GroupKey was missing), if any.
  Future<int?> loadUnreadable(RecordId id);

  /// Remembers that the row of [id] at [position] could not be opened;
  /// only the lowest such position is kept.
  Future<void> markUnreadable(RecordId id, int position);

  /// Forgets every position learned from a server (cursors and unreadable
  /// rows), before syncing with a new one. Records and outbox stay.
  Future<void> forgetServer();
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

/// Where the device keeps its [VaultShelf], in clear: it must be readable
/// before any vault is unlocked. A shelf that does not read back as one is
/// [VaultShelf.initial], never an error, so the first vault always opens.
abstract interface class ShelfStore {
  Future<VaultShelf> load();

  Future<void> save(VaultShelf shelf);
}
