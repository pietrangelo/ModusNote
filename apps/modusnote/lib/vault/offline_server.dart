import 'package:collaboration_access_control/collaboration_access_control.dart';
import 'package:offline_sync/offline_sync.dart';

/// The sync server until the Supabase project exists: always unreachable,
/// so edits stay in the outbox, sealed, ready to push later.
final class OfflineSyncServer implements SyncServer {
  const OfflineSyncServer();

  @override
  Future<void> push(WorkspaceId workspace, List<SealedRow> rows) =>
      throw const ServerUnavailableException();

  @override
  Future<List<PulledRow>> pull(WorkspaceId workspace, {required int after}) =>
      throw const ServerUnavailableException();

  @override
  Future<List<MembershipRecord>> membership(
    WorkspaceId workspace, {
    required int from,
  }) => throw const ServerUnavailableException();

  @override
  Future<List<(int, KeyBundle)>> keyBundles(
    WorkspaceId workspace, {
    required int after,
  }) => throw const ServerUnavailableException();
}

final class SystemClock implements Clock {
  const SystemClock();

  @override
  DateTime now() => DateTime.now().toUtc();
}
