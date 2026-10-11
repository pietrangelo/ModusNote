import 'dart:typed_data';

import 'package:schema_dynamic_content/schema_dynamic_content.dart';

/// Port: durable storage of encrypted blobs, local disk or OPFS.
///
/// Adapters only ever receive ciphertext, so they need no crypto and a
/// stolen device cache or a server-side copy reveals nothing but sizes.
abstract interface class CiphertextBlobStore {
  /// Starts a write that stays invisible to [read] until committed.
  /// Throws `BlobAlreadyExistsException` if [id] exists or is being written.
  Future<CiphertextBlobWriter> create(BlobId id);

  /// Throws `BlobNotFoundException` if [id] was never committed.
  Stream<Uint8List> read(BlobId id);

  Future<bool> contains(BlobId id);

  Future<void> delete(BlobId id);

  /// Drops writes that were never committed, e.g. after the app was killed
  /// mid-recording. Called once at startup.
  Future<void> discardIncomplete();
}

abstract interface class CiphertextBlobWriter {
  Future<void> add(Uint8List ciphertext);

  /// Makes the blob visible atomically: readers see all of it or none.
  Future<void> commit();

  /// Removes everything written so far. Safe to call after a failed add.
  Future<void> abort();
}
