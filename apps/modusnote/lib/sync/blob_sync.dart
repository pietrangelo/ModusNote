import 'dart:convert';
import 'dart:typed_data';

import 'package:blob_storage_media/blob_storage_media.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

/// A workspace's shared storage as the open vault uses it: copying blobs
/// and deleting the ones no note references.
typedef SharedBlobs = ({BlobReplication replication, BlobPruning pruning});

/// Keeps the vault's recordings and pictures in the workspace's shared
/// storage: every blob a note references and this device holds goes up
/// once, after the notes sync; one from another device comes down the
/// first time it is played or shown; one no note references any more is
/// deleted there too.
///
/// What this device knows about the server (which blobs it already has,
/// which ones notes here let go of) is kept as device settings sealed in
/// the vault ([load] and [save], by name), so the server learns nothing
/// new and nothing is sent twice.
final class BlobSync {
  BlobSync({
    required this._replication,
    required this._blobs,
    required this._load,
    required this._save,
    this._pruning,
    bool Function()? canPrune,
    Future<bool> Function()? unsentWrites,
    DateTime Function()? clock,
    this._sweepEvery = const Duration(days: 1),
  }) : _canPrune = canPrune ?? (() => true),
       _unsentWrites = unsentWrites ?? (() async => false),
       _clock = clock ?? DateTime.now;

  /// Blobs the server holds, uploaded or downloaded here.
  static const sentSetting = 'sync.blobs-sent';

  /// Blobs notes on this device stopped referencing, still to delete on
  /// the server.
  static const releasedSetting = 'sync.blobs-released';

  /// When this device last swept the server, so a new unlock does not
  /// list the workspace again.
  static const sweptSetting = 'sync.blobs-swept';

  final BlobReplication _replication;
  final BlobPruning? _pruning;
  final Iterable<KeyedBlob> Function() _blobs;
  final Future<Uint8List?> Function(String name) _load;
  final Future<void> Function(String name, Uint8List? value) _save;
  final bool Function() _canPrune;
  final Future<bool> Function() _unsentWrites;
  final DateTime Function() _clock;
  final Duration _sweepEvery;
  Future<Set<String>>? _sent;
  Future<Set<String>>? _released;

  /// Blobs of other devices this one has not downloaded: they only come
  /// down through [ensureLocal], so they are not looked for every minute.
  final _remoteOnly = <String>{};

  /// Runs after each sync that reached the server. After one that [moved]
  /// the vault to a new server, which holds none of the old one's blobs,
  /// every blob here goes up again and the sweep starts over.
  Future<void> afterSync({bool moved = false}) async {
    if (moved) {
      _sent = Future.value(<String>{});
      _remoteOnly.clear();
      await _save(sentSetting, null);
      await _save(sweptSetting, null);
    }
    // A blob that does not go up must not keep the server from being
    // cleaned: the pruning runs anyway, and the upload's failure is what
    // the sync reports.
    Object? failure;
    StackTrace? trace;
    try {
      await uploadPending();
    } on BlobException catch (error, stack) {
      failure = error;
      trace = stack;
    }
    await prune();
    if (failure != null) Error.throwWithStackTrace(failure, trace!);
  }

  /// Uploads the blobs the server does not have yet, the smallest first.
  /// One the server refuses (too large, its storage full) is skipped, so
  /// it does not hold back the others; the first refusal is thrown once
  /// they went up. Stops when the server cannot be reached: what went up
  /// stays recorded as sent.
  Future<void> uploadPending() async {
    final sent = await _sentIds();
    final pending = [
      for (final blob in _blobs())
        if (!sent.contains(blob.id.value) &&
            !_remoteOnly.contains(blob.id.value))
          blob,
    ]..sort((a, b) => a.blob.plaintextLength.compareTo(b.blob.plaintextLength));
    var uploaded = false;
    RemoteBlobRejectedException? refused;
    try {
      for (final blob in pending) {
        final id = blob.id.value;
        if (sent.contains(id)) continue;
        if (!await _replication.isLocal(blob.id)) {
          _remoteOnly.add(id);
          continue;
        }
        try {
          await _replication.upload(blob.blob);
        } on RemoteBlobRejectedException catch (error) {
          refused ??= error;
          continue;
        }
        sent.add(id);
        uploaded = true;
      }
    } finally {
      // Sealed once, not after every blob; one lost to a crash is only
      // uploaded again, which the server takes as already there.
      if (uploaded) await _store(sentSetting, sent);
    }
    if (refused != null) throw refused;
  }

  /// Downloads [blob] when this device does not hold it; a downloaded blob
  /// is already on the server.
  Future<void> ensureLocal(SealedBlob blob) async {
    if (await _replication.isLocal(blob.id)) return;
    await _replication.ensureLocal(blob);
    final sent = await _sentIds();
    if (sent.add(blob.id.value)) await _store(sentSetting, sent);
  }

  /// Notes here stopped referencing [ids] (deleted for good, or a
  /// recording or picture removed): they go from the server at the next
  /// [prune], wherever they were uploaded from.
  Future<void> release(Iterable<BlobId> ids) async {
    final released = await _releasedIds();
    final before = released.length;
    released.addAll([for (final id in ids) id.value]);
    if (released.length != before) await _store(releasedSetting, released);
  }

  /// Deletes on the server the released blobs no note took back, and, at
  /// most once every [_sweepEvery], every older blob no note references.
  ///
  /// Only from a vault that agrees with the server: with edits still
  /// queued, the server's notes may reference what this device let go of;
  /// with a record this app cannot read, a note of a newer app may
  /// reference blobs this one does not see.
  Future<void> prune() async {
    final pruning = _pruning;
    if (pruning == null || !_canPrune() || await _unsentWrites()) return;
    final referenced = {for (final blob in _blobs()) blob.id};
    final released = await _releasedIds();
    final sent = await _sentIds();
    if (released.isNotEmpty) {
      final snapshot = {...released};
      final deleted = await pruning.deleteReleased([
        for (final id in snapshot) ?_blobId(id),
      ], referenced: referenced);
      // Taken back by a note, deleted, or not an id at all: done with.
      released.removeAll(snapshot);
      await _store(releasedSetting, released);
      await _forget(sent, deleted);
    }
    final now = _clock();
    final since = now.difference(await _sweptAt() ?? DateTime(0));
    // A clock set back counts as due, so a wrong date never stops sweeps.
    if (!since.isNegative && since < _sweepEvery) return;
    final deleted = await pruning.sweep(referenced: referenced, now: now);
    await _save(
      sweptSetting,
      utf8.encode('${now.toUtc().microsecondsSinceEpoch}'),
    );
    await _forget(sent, deleted);
  }

  /// A blob deleted on the server is no longer there: should a note take
  /// it back, it goes up again.
  Future<void> _forget(Set<String> sent, Set<BlobId> deleted) async {
    final before = sent.length;
    sent.removeAll([for (final id in deleted) id.value]);
    if (sent.length != before) await _store(sentSetting, sent);
  }

  static BlobId? _blobId(String value) {
    try {
      return BlobId(value);
    } on InvalidSchemaException {
      return null;
    }
  }

  // Futures, so calls racing on the first read share one set.
  Future<Set<String>> _sentIds() => _sent ??= _restore(sentSetting);

  Future<Set<String>> _releasedIds() => _released ??= _restore(releasedSetting);

  /// A damaged value counts as never swept: one listing too many.
  Future<DateTime?> _sweptAt() async {
    final stored = await _load(sweptSetting);
    final micros = stored == null
        ? null
        : int.tryParse(utf8.decode(stored, allowMalformed: true));
    return micros == null
        ? null
        : DateTime.fromMicrosecondsSinceEpoch(micros, isUtc: true);
  }

  Future<Set<String>> _restore(String name) async {
    final stored = await _load(name);
    return {
      if (stored != null)
        for (final line
            in utf8.decode(stored, allowMalformed: true).split('\n'))
          if (line.isNotEmpty) line,
    };
  }

  Future<void> _store(String name, Set<String> ids) =>
      _save(name, Uint8List.fromList(utf8.encode(ids.join('\n'))));
}
