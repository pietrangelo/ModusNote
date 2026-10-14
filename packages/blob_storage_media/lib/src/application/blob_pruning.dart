import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import 'blob_replication.dart';

/// Use case: deletes from the workspace's shared storage the blobs no note
/// references any more. The server cannot tell which those are (it sees no
/// note), so a member device decides, from a vault it has just synced.
///
/// Both methods throw what [RemoteBlobStore] throws; deleting is
/// idempotent, so whatever was left is deleted on the next try.
final class BlobPruning {
  BlobPruning({
    required this._remote,
    this.grace = const Duration(days: 1),
    this.maxPages = 100,
  });

  final RemoteBlobStore _remote;

  /// How old an unreferenced blob must be before a sweep deletes it. A
  /// device uploads a blob only after the note that references it reached
  /// the server, so a blob older than this one's last pull, and still
  /// unreferenced, belongs to no note any device has synced.
  final Duration grace;

  /// A sweep reads at most this many pages, whatever the server says.
  final int maxPages;

  /// Deletes the [released] blobs (a note stopped referencing them on this
  /// device) that no note in [referenced] has taken back. Returns them.
  Future<Set<BlobId>> deleteReleased(
    Iterable<BlobId> released, {
    required Set<BlobId> referenced,
  }) async {
    final doomed = {
      for (final id in released)
        if (!referenced.contains(id)) id,
    };
    if (doomed.isNotEmpty) await _remote.delete([...doomed]);
    return doomed;
  }

  /// Lists the whole storage and deletes every blob outside [referenced]
  /// that was uploaded more than [grace] before [now]. Returns them.
  Future<Set<BlobId>> sweep({
    required Set<BlobId> referenced,
    required DateTime now,
  }) async {
    final cutoff = now.subtract(grace);
    final deleted = <BlobId>{};
    final seen = <String>{};
    String? after;
    for (var page = 0; page < maxPages; page++) {
      final listing = await _remote.list(after: after);
      final doomed = {
        for (final blob in listing.blobs)
          if (!referenced.contains(blob.id) &&
              !deleted.contains(blob.id) &&
              blob.storedAt.isBefore(cutoff))
            blob.id,
      };
      if (doomed.isNotEmpty) {
        await _remote.delete([...doomed]);
        deleted.addAll(doomed);
      }
      after = listing.next;
      // A cursor seen before would read the same pages forever.
      if (after == null || !seen.add(after)) break;
    }
    return deleted;
  }
}
