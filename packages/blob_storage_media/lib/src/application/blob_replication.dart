import 'dart:typed_data';

import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import '../core/blob_exception.dart';
import '../core/blob_metadata.dart';
import '../core/chunk_layout.dart';
import 'ciphertext_blob_store.dart';

/// Port: the copy of a workspace's blobs every member can reach (R2 behind
/// presigned URLs). It holds the same ciphertext as the local store and
/// nothing else: no key, no metadata beyond the id and the size.
///
/// Both methods throw [RemoteBlobUnavailableException] when the storage
/// cannot be reached and [RemoteBlobRejectedException] when it refuses.
abstract interface class RemoteBlobStore {
  /// Stores [ciphertext], exactly [length] bytes, as blob [id]. Blobs are
  /// written once: an object already stored under [id] is kept, and that is
  /// not an error.
  Future<void> upload(
    BlobId id,
    Stream<Uint8List> ciphertext, {
    required int length,
  });

  /// The ciphertext of blob [id]. Throws [BlobNotFoundException] when the
  /// storage holds none (not uploaded yet).
  Stream<Uint8List> download(BlobId id);
}

/// Use case: copies blobs between this device and the workspace's shared
/// storage, as ciphertext only.
///
/// Nothing downloaded is trusted: it lands in the local store only when it
/// is exactly as long as the note's metadata says, and every chunk is still
/// authenticated by [EncryptedBlobStorage] when it is played.
final class BlobReplication {
  BlobReplication({required this._local, required this._remote});

  final CiphertextBlobStore _local;
  final RemoteBlobStore _remote;
  final _fetching = <BlobId, Future<void>>{};

  /// Whether this device holds blob [id].
  Future<bool> isLocal(BlobId id) => _local.contains(id);

  Future<void> upload(SealedBlob blob) => _remote.upload(
    blob.id,
    _local.read(blob.id),
    length: ChunkLayout.ciphertextLengthFor(blob.plaintextLength),
  );

  /// Makes [blob] readable from the local store, downloading it when this
  /// device does not have it. Concurrent calls for one blob share one
  /// download.
  Future<void> ensureLocal(SealedBlob blob) async {
    if (await _local.contains(blob.id)) return;
    return _fetching[blob.id] ??= _fetch(blob).whenComplete(() {
      // Not `=> remove(...)`: that returns this very future, and
      // whenComplete would wait on itself.
      _fetching.remove(blob.id);
    });
  }

  Future<void> _fetch(SealedBlob blob) async {
    final expected = ChunkLayout.ciphertextLengthFor(blob.plaintextLength);
    final writer = await _local.create(blob.id);
    try {
      var received = 0;
      await for (final piece in _remote.download(blob.id)) {
        received += piece.length;
        // A server cannot fill the device: it stops at the announced size.
        if (received > expected) {
          throw const MalformedBlobException('download longer than the blob');
        }
        await writer.add(piece);
      }
      if (received != expected) throw const TruncatedBlobException();
      await writer.commit();
    } catch (_) {
      await writer.abort();
      rethrow;
    }
  }
}
