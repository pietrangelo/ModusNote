import 'dart:convert';
import 'dart:typed_data';

import 'package:blob_storage_media/blob_storage_media.dart';

/// Keeps the vault's recordings and pictures in the workspace's shared
/// storage: every blob a note references and this device holds goes up
/// once, after the notes sync; one from another device comes down the
/// first time it is played or shown.
///
/// Which blobs the server already has is remembered as a device setting
/// sealed in the vault ([load] and [save]), so the server learns nothing
/// new and nothing is sent twice.
final class BlobSync {
  BlobSync({
    required this._replication,
    required this._blobs,
    required this._load,
    required this._save,
  });

  final BlobReplication _replication;
  final Iterable<KeyedBlob> Function() _blobs;
  final Future<Uint8List?> Function() _load;
  final Future<void> Function(Uint8List? value) _save;
  Set<String>? _sent;

  /// Uploads the blobs the server does not have yet. Stops at the first
  /// failure: what went up stays recorded as sent.
  Future<void> uploadPending() async {
    final sent = await _sentIds();
    for (final blob in _blobs()) {
      final id = blob.id.value;
      if (sent.contains(id) || !await _replication.isLocal(blob.id)) continue;
      await _replication.upload(blob.blob);
      sent.add(id);
      await _store(sent);
    }
  }

  /// Downloads [blob] when this device does not hold it; a downloaded blob
  /// is already on the server.
  Future<void> ensureLocal(SealedBlob blob) async {
    if (await _replication.isLocal(blob.id)) return;
    await _replication.ensureLocal(blob);
    final sent = await _sentIds();
    if (sent.add(blob.id.value)) await _store(sent);
  }

  Future<Set<String>> _sentIds() async {
    if (_sent case final sent?) return sent;
    final stored = await _load();
    return _sent = {
      if (stored != null)
        for (final line
            in utf8.decode(stored, allowMalformed: true).split('\n'))
          if (line.isNotEmpty) line,
    };
  }

  Future<void> _store(Set<String> sent) =>
      _save(Uint8List.fromList(utf8.encode(sent.join('\n'))));
}
