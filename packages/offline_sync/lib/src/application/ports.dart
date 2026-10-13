import 'package:collaboration_access_control/collaboration_access_control.dart';
import 'package:identity_cryptography/identity_cryptography.dart';

import '../core/outbox.dart';
import '../core/passkey_slot.dart';
import '../core/record_revision.dart';
import '../core/sync_row.dart';
import '../core/vault_header.dart';

/// Port: the zero-knowledge sync server (Supabase in production). Every
/// method throws [ServerUnavailableException] when it cannot be reached.
///
/// All three streams are append-only: the server never overwrites a row,
/// and conflicts are resolved by the clients, which see every revision.
abstract interface class SyncServer {
  Future<void> push(WorkspaceId workspace, List<SealedRow> rows);

  /// Rows appended after position [after], each with its own position.
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
}

enum SyncStream { rows, keyBundles }

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

  /// The passkey enrolled on this device, if any.
  Future<PasskeySlot?> loadPasskey();

  /// Stores [slot], replacing any earlier one. Throws [NoVaultException]
  /// when there is no vault for it to open.
  Future<void> savePasskey(PasskeySlot slot);

  Future<void> removePasskey();
}

/// Port: wall-clock time, used only to order concurrent edits.
abstract interface class Clock {
  DateTime now();
}
