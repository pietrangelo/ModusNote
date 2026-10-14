import 'dart:typed_data';

import 'package:blob_storage_media/blob_storage_media.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';
import 'package:test/test.dart';

/// The shared storage as a listing sees it: ids and upload times.
final class ListedRemote implements RemoteBlobStore {
  ListedRemote(Map<String, DateTime> objects, {this.pageSize = 2})
    : objects = {
        for (final MapEntry(:key, :value) in objects.entries)
          BlobId(key): value,
      };

  final Map<BlobId, DateTime> objects;
  final int pageSize;
  final deletions = <List<BlobId>>[];
  var listings = 0;
  var online = true;
  var _snapshot = <StoredBlob>[];

  /// Answers instead of the honest page, as a hostile server would.
  StoredBlobPage Function(String? after)? serve;

  @override
  Future<void> delete(List<BlobId> ids) async {
    if (!online) throw const RemoteBlobUnavailableException();
    deletions.add(ids);
    ids.forEach(objects.remove);
  }

  @override
  Future<StoredBlobPage> list({String? after}) async {
    listings++;
    if (!online) throw const RemoteBlobUnavailableException();
    if (serve case final serve?) return serve(after);
    // Like R2's cursors, deleting listed blobs does not shift the pages.
    if (after == null) {
      _snapshot = [
        for (final MapEntry(:key, :value) in objects.entries)
          StoredBlob(key, storedAt: value),
      ];
    }
    final all = _snapshot;
    final start = after == null ? 0 : int.parse(after);
    final end = start + pageSize < all.length ? start + pageSize : all.length;
    return StoredBlobPage(
      all.sublist(start, end),
      next: end < all.length ? '$end' : null,
    );
  }

  @override
  Future<void> upload(
    BlobId id,
    Stream<Uint8List> ciphertext, {
    required int length,
  }) => throw UnimplementedError();

  @override
  Stream<Uint8List> download(BlobId id) => throw UnimplementedError();
}

void main() {
  final now = DateTime.utc(2026, 10, 14, 12);
  final old = now.subtract(const Duration(days: 3));
  final fresh = now.subtract(const Duration(hours: 2));
  Set<BlobId> ids(Iterable<String> values) => {
    for (final v in values) BlobId(v),
  };

  group('released blobs', () {
    test('are deleted unless a note references them again', () async {
      final remote = ListedRemote({'a': fresh, 'b': fresh, 'c': fresh});
      final pruning = BlobPruning(remote: remote);

      final deleted = await pruning.deleteReleased(
        ids(['a', 'b']),
        referenced: ids(['b', 'c']),
      );

      expect(deleted, ids(['a']));
      expect(remote.objects.keys, ids(['b', 'c']));
    });

    test('nothing to delete asks nothing of the server', () async {
      final remote = ListedRemote({'a': old});
      final pruning = BlobPruning(remote: remote);

      expect(
        await pruning.deleteReleased(ids(['a']), referenced: ids(['a'])),
        isEmpty,
      );
      expect(await pruning.deleteReleased({}, referenced: {}), isEmpty);
      expect(remote.deletions, isEmpty);
    });

    test(
      'an unreachable server is reported, so they are deleted later',
      () async {
        final remote = ListedRemote({'a': old})..online = false;

        await expectLater(
          BlobPruning(remote: remote)
              .deleteReleased(ids(['a']), referenced: {}),
          throwsA(isA<RemoteBlobUnavailableException>()),
        );
      },
    );
  });

  group('a sweep', () {
    test(
      'deletes every unreferenced blob older than the grace period',
      () async {
        final remote = ListedRemote({
          'kept': old,
          'orphan-1': old,
          'young-orphan': fresh,
          'orphan-2': old,
          'orphan-3': old,
        });
        final pruning = BlobPruning(remote: remote);

        final deleted = await pruning.sweep(
          referenced: ids(['kept']),
          now: now,
        );

        expect(deleted, ids(['orphan-1', 'orphan-2', 'orphan-3']));
        expect(remote.objects.keys, ids(['kept', 'young-orphan']));
        expect(remote.listings, 3);
      },
    );

    test('a blob uploaded within the grace period stays: its note may have '
        'reached the server after this device pulled', () async {
      final remote = ListedRemote({
        'edge': now.subtract(const Duration(hours: 23, minutes: 59)),
      });

      final deleted = await BlobPruning(remote: remote)
          .sweep(referenced: {}, now: now);

      expect(deleted, isEmpty);
      expect(remote.deletions, isEmpty);
    });

    test('a page with nothing to delete sends no deletion', () async {
      final remote = ListedRemote({'a': old, 'b': old});

      await BlobPruning(remote: remote)
          .sweep(referenced: ids(['a', 'b']), now: now);

      expect(remote.deletions, isEmpty);
    });
  });

  group('adversary', () {
    test('a listing that never ends stops at the page limit', () async {
      final remote = ListedRemote({})
        ..serve = (after) =>
            StoredBlobPage(const [], next: '${int.parse(after ?? '0') + 1}');

      await BlobPruning(
        remote: remote,
        maxPages: 5,
      ).sweep(referenced: {}, now: now);

      expect(remote.listings, 5);
    });

    test('a listing that repeats its cursor stops there', () async {
      final remote = ListedRemote({})
        ..serve = (_) => const StoredBlobPage([], next: 'again');

      await BlobPruning(remote: remote).sweep(referenced: {}, now: now);

      expect(remote.listings, 2);
    });

    test(
      'a referenced blob is never deleted, whatever the listing claims',
      () async {
        final remote = ListedRemote({})
          ..serve = (_) => StoredBlobPage([
            StoredBlob(BlobId('kept'), storedAt: DateTime.utc(1970)),
            StoredBlob(BlobId('kept'), storedAt: DateTime.utc(1970)),
            StoredBlob(BlobId('orphan'), storedAt: DateTime.utc(1970)),
            StoredBlob(BlobId('orphan'), storedAt: DateTime.utc(1970)),
          ]);

        final deleted = await BlobPruning(remote: remote)
            .sweep(referenced: ids(['kept']), now: now);

        expect(deleted, ids(['orphan']));
        expect(remote.deletions, [
          [BlobId('orphan')],
        ]);
      },
    );

    test('a blob dated in the future is young, not old', () async {
      final remote = ListedRemote({'a': now.add(const Duration(days: 400))});

      expect(
        await BlobPruning(remote: remote).sweep(referenced: {}, now: now),
        isEmpty,
      );
    });
  });
}
