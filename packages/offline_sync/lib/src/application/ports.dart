import 'package:collaboration_access_control/collaboration_access_control.dart';
import 'package:identity_cryptography/identity_cryptography.dart';

import '../core/outbox.dart';
import '../core/record_revision.dart';
import '../core/sync_row.dart';

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

/// Port: the local database (SQLCipher on mobile, SQLite WASM on web). It is
/// only ever handed sealed data.
abstract interface class LocalRecordStore {
  Future<EncryptedEnvelope?> load(RecordId id);

  Future<void> save(RecordId id, EncryptedEnvelope sealed);

  Future<Outbox> loadOutbox();

  Future<void> saveOutbox(Outbox outbox);

  Future<int> loadCursor(SyncStream stream);

  Future<void> saveCursor(SyncStream stream, int cursor);
}

/// Port: wall-clock time, used only to order concurrent edits.
abstract interface class Clock {
  DateTime now();
}
