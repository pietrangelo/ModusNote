import 'dart:convert';
import 'dart:typed_data';

import 'package:blob_storage_media/blob_storage_media.dart';

/// Keeps the vault's recordings in the workspace's shared storage: every
/// recording a note references and this device holds goes up once, after
/// the notes sync; a recording from another device comes down the first
/// time it is played.
///
/// Which blobs the server already has is remembered as a device setting
/// sealed in the vault ([load] and [save]), so the server learns nothing
/// new and nothing is sent twice.
final class BlobSync {
  BlobSync({
    required this._replication,
    required this._recordings,
    required this._load,
    required this._save,
  });

  final BlobReplication _replication;
  final Iterable<KeyedRecording> Function() _recordings;
  final Future<Uint8List?> Function() _load;
  final Future<void> Function(Uint8List? value) _save;
  Set<String>? _sent;

  /// Uploads the recordings the server does not have yet. Stops at the
  /// first failure: what went up stays recorded as sent.
  Future<void> uploadPending() async {
    final sent = await _sentIds();
    for (final take in _recordings()) {
      final id = take.id.value;
      if (sent.contains(id) || !await _replication.isLocal(take.id)) continue;
      await _replication.upload(take.metadata.blob);
      sent.add(id);
      await _store(sent);
    }
  }

  /// Downloads [take] when this device does not hold it; a downloaded
  /// recording is already on the server.
  Future<void> ensureLocal(KeyedRecording take) async {
    if (await _replication.isLocal(take.id)) return;
    await _replication.ensureLocal(take.metadata.blob);
    final sent = await _sentIds();
    if (sent.add(take.id.value)) await _store(sent);
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
