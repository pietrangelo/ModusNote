import 'dart:typed_data';

import 'package:blob_storage_media/blob_storage_media.dart';
import 'package:file/file.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

/// [CiphertextBlobStore] on a directory: `<id>.enc` once committed,
/// `<id>.enc.part` while being written.
///
/// Commit is a rename, which is atomic on one file system, so a crash
/// leaves either a complete `.enc` or a stray `.part` that
/// [discardIncomplete] removes at the next start. Both only ever hold
/// ciphertext. `BlobId` admits only `[A-Za-z0-9_-]`, so an id cannot
/// name a path outside [root].
final class FileSystemCiphertextBlobStore implements CiphertextBlobStore {
  FileSystemCiphertextBlobStore(this.root);

  final Directory root;

  static const _committedSuffix = '.enc';
  static const _partialSuffix = '.enc.part';

  File _committed(BlobId id) => root.childFile('${id.value}$_committedSuffix');

  File _partial(BlobId id) => root.childFile('${id.value}$_partialSuffix');

  @override
  Future<CiphertextBlobWriter> create(BlobId id) async {
    await root.create(recursive: true);
    if (await _committed(id).exists()) throw BlobAlreadyExistsException(id);
    final partial = _partial(id);
    // Two writers must never interleave into one blob. A leftover `.part`
    // from a crash also counts until discardIncomplete() has run.
    if (await partial.exists()) throw BlobAlreadyExistsException(id);
    await partial.create(exclusive: true);
    return _FileWriter(
      await partial.open(mode: FileMode.write),
      partial,
      _committed(id),
    );
  }

  @override
  Stream<Uint8List> read(BlobId id) async* {
    final file = _committed(id);
    if (!await file.exists()) throw BlobNotFoundException(id);
    await for (final piece in file.openRead()) {
      yield piece is Uint8List ? piece : Uint8List.fromList(piece);
    }
  }

  @override
  Future<bool> contains(BlobId id) => _committed(id).exists();

  @override
  Future<void> delete(BlobId id) async {
    final file = _committed(id);
    if (await file.exists()) await file.delete();
  }

  @override
  Future<void> discardIncomplete() async {
    if (!await root.exists()) return;
    await for (final entity in root.list()) {
      if (entity is File && entity.path.endsWith(_partialSuffix)) {
        await entity.delete();
      }
    }
  }
}

final class _FileWriter implements CiphertextBlobWriter {
  _FileWriter(this._handle, this._partial, this._committed);

  final RandomAccessFile _handle;
  final File _partial;
  final File _committed;
  bool _closed = false;

  @override
  Future<void> add(Uint8List ciphertext) => _handle.writeFrom(ciphertext);

  @override
  Future<void> commit() async {
    await _handle.flush();
    await _close();
    await _partial.rename(_committed.path);
  }

  @override
  Future<void> abort() async {
    try {
      await _close();
    } on FileSystemException {
      // Already broken; deleting the file below is what matters.
    }
    if (await _partial.exists()) await _partial.delete();
  }

  Future<void> _close() async {
    if (_closed) return;
    _closed = true;
    await _handle.close();
  }
}
