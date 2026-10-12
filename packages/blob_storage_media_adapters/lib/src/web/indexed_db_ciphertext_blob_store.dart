import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:blob_storage_media/blob_storage_media.dart';
import 'package:meta/meta.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';
import 'package:web/web.dart' as web;

/// The browser refused a storage operation: the disk quota is used up,
/// the user cleared site data mid-write, or a private window forbids it.
/// [reason] is the DOMException name, never anything from the blob.
final class BrowserStorageException implements Exception {
  const BrowserStorageException(this.reason);

  final String reason;

  @override
  String toString() => 'BrowserStorageException: $reason';
}

/// [CiphertextBlobStore] in IndexedDB, for the web client.
///
/// Two object stores: `blobs` maps an id to its state (writing, or the
/// number of chunks once committed) and `chunks` holds each piece handed
/// to [CiphertextBlobWriter.add] under `[id, index]`. Commit is a single
/// write of the state, so a reader sees all of a blob or none of it, and
/// a tab closed mid-recording leaves a "writing" entry that
/// [discardIncomplete] removes at the next start. Everything stored is
/// ciphertext from the domain's envelopes.
///
/// Reading goes piece by piece, one transaction each, so a long recording
/// is never loaded at once. The blobs live in their own database, apart
/// from the SQLite vault file.
final class IndexedDbCiphertextBlobStore implements CiphertextBlobStore {
  IndexedDbCiphertextBlobStore._(this._database);

  static const defaultName = 'modusnote-blobs';
  static const _version = 1;
  static const _blobs = 'blobs';
  static const _chunks = 'chunks';

  /// The state of a blob whose write has not been committed.
  static const _writing = -1;

  final web.IDBDatabase _database;

  static Future<IndexedDbCiphertextBlobStore> open({
    String name = defaultName,
  }) async {
    final request = web.window.indexedDB.open(name, _version);
    request.onupgradeneeded = ((web.Event _) {
      final database = request.result! as web.IDBDatabase;
      database
        ..createObjectStore(_blobs)
        ..createObjectStore(_chunks);
    }).toJS;
    final database = await _result(request) as web.IDBDatabase;
    return IndexedDbCiphertextBlobStore._(database);
  }

  /// Removes the whole database [name]; for tests and for wiping the
  /// device. Waits until every connection to it is closed.
  static Future<void> deleteDatabase(String name) async {
    await _result(web.window.indexedDB.deleteDatabase(name));
  }

  void close() => _database.close();

  @override
  Future<CiphertextBlobWriter> create(BlobId id) async {
    final transaction = _transaction(_blobs, readWrite: true);
    // `add` fails on an existing key inside the transaction, so two
    // writers can never both claim an id.
    transaction.objectStore(_blobs).add(_writing.toJS, _key(id));
    try {
      await _completion(transaction);
    } on BrowserStorageException catch (error) {
      if (error.reason == 'ConstraintError') {
        throw BlobAlreadyExistsException(id);
      }
      rethrow;
    }
    return _IndexedDbWriter(this, id);
  }

  @override
  Stream<Uint8List> read(BlobId id) async* {
    final chunks = await _committedChunks(id);
    if (chunks == null) throw BlobNotFoundException(id);
    for (var index = 0; index < chunks; index++) {
      final transaction = _transaction(_chunks);
      final value = await _result(
        transaction.objectStore(_chunks).get(_chunkKey(id, index)),
      );
      // Deleted while being read: stop. Decryption reports the blob as
      // truncated, as it would for a cut-off file.
      if (value == null || !value.isA<JSUint8Array>()) return;
      yield (value as JSUint8Array).toDart;
    }
  }

  @override
  Future<bool> contains(BlobId id) async => await _committedChunks(id) != null;

  @override
  Future<void> delete(BlobId id) async {
    final transaction = _transaction(_blobs, also: _chunks, readWrite: true);
    final blobs = transaction.objectStore(_blobs);
    final request = blobs.get(_key(id));
    // Decide and delete inside the same transaction: a write in flight is
    // not ours to remove, only its writer may abort it.
    request.onsuccess = ((web.Event _) {
      final state = request.result;
      if (state == null || _stateOf(state) == _writing) return;
      blobs.delete(_key(id));
      transaction.objectStore(_chunks).delete(_chunkRange(id));
    }).toJS;
    await _completion(transaction);
  }

  @override
  Future<void> discardIncomplete() async {
    final transaction = _transaction(_blobs, also: _chunks, readWrite: true);
    final chunks = transaction.objectStore(_chunks);
    final cursorRequest = transaction.objectStore(_blobs).openCursor();
    cursorRequest.onsuccess = ((web.Event _) {
      final cursor = cursorRequest.result as web.IDBCursorWithValue?;
      if (cursor == null) return;
      if (_stateOf(cursor.value) == _writing) {
        chunks.delete(_chunkRange(BlobId((cursor.key! as JSString).toDart)));
        cursor.delete();
      }
      cursor.continue_();
    }).toJS;
    await _completion(transaction);
  }

  /// How many pieces are stored across all blobs, committed or not.
  @visibleForTesting
  Future<int> storedChunkCount() async {
    final transaction = _transaction(_chunks);
    final count = await _result(transaction.objectStore(_chunks).count());
    return (count! as JSNumber).toDartInt;
  }

  /// The number of chunks of [id], or null unless it is committed.
  Future<int?> _committedChunks(BlobId id) async {
    final transaction = _transaction(_blobs);
    final state = await _result(transaction.objectStore(_blobs).get(_key(id)));
    if (state == null) return null;
    final chunks = _stateOf(state);
    return chunks < 0 ? null : chunks;
  }

  Future<void> _putChunk(BlobId id, int index, Uint8List ciphertext) async {
    final transaction = _transaction(_chunks, readWrite: true);
    transaction
        .objectStore(_chunks)
        .put(_exact(ciphertext).toJS, _chunkKey(id, index));
    await _completion(transaction);
  }

  /// IndexedDB clones a typed array with its whole buffer: a view must be
  /// copied out first, or whatever shares its buffer would be stored too.
  static Uint8List _exact(Uint8List bytes) =>
      bytes.offsetInBytes == 0 && bytes.buffer.lengthInBytes == bytes.length
      ? bytes
      : Uint8List.fromList(bytes);

  Future<void> _commit(BlobId id, int chunks) async {
    final transaction = _transaction(_blobs, readWrite: true);
    transaction.objectStore(_blobs).put(chunks.toJS, _key(id));
    await _completion(transaction);
  }

  Future<void> _discard(BlobId id) async {
    final transaction = _transaction(_blobs, also: _chunks, readWrite: true);
    transaction.objectStore(_chunks).delete(_chunkRange(id));
    transaction.objectStore(_blobs).delete(_key(id));
    await _completion(transaction);
  }

  web.IDBTransaction _transaction(
    String store, {
    String? also,
    bool readWrite = false,
  }) => _database.transaction(
    also == null ? store.toJS : [store.toJS, also.toJS].toJS,
    readWrite ? 'readwrite' : 'readonly',
  );

  static JSString _key(BlobId id) => id.value.toJS;

  static JSArray<JSAny> _chunkKey(BlobId id, int index) =>
      [id.value.toJS, index.toJS].toJS;

  /// Every `[id, n]` key of one blob and of no other: array keys compare
  /// element by element, so `[id, 0]`..`[id, ∞]` cannot reach `[id2, n]`.
  static web.IDBKeyRange _chunkRange(BlobId id) => web.IDBKeyRange.bound(
    [id.value.toJS, 0.toJS].toJS,
    [id.value.toJS, double.infinity.toJS].toJS,
  );

  /// A state we did not write (another app on the origin, a damaged
  /// profile) reads as "writing": never served, dropped at startup.
  static int _stateOf(JSAny? state) => state != null && state.isA<JSNumber>()
      ? (state as JSNumber).toDartInt
      : _writing;
}

final class _IndexedDbWriter implements CiphertextBlobWriter {
  _IndexedDbWriter(this._store, this._id);

  final IndexedDbCiphertextBlobStore _store;
  final BlobId _id;
  var _chunks = 0;
  var _state = _WriterState.open;

  @override
  Future<void> add(Uint8List ciphertext) async {
    if (_state != _WriterState.open) throw StateError('blob writer closed');
    if (ciphertext.isEmpty) return;
    await _store._putChunk(_id, _chunks, ciphertext);
    _chunks++;
  }

  @override
  Future<void> commit() async {
    if (_state != _WriterState.open) throw StateError('blob writer closed');
    _state = _WriterState.committed;
    await _store._commit(_id, _chunks);
  }

  @override
  Future<void> abort() async {
    // After a commit the blob belongs to readers: abort must not touch it.
    if (_state == _WriterState.committed) return;
    _state = _WriterState.aborted;
    await _store._discard(_id);
  }
}

enum _WriterState { open, committed, aborted }

Future<JSAny?> _result(web.IDBRequest request) {
  final completer = Completer<JSAny?>();
  request
    ..onsuccess = ((web.Event _) => completer.complete(request.result)).toJS
    ..onerror = ((web.Event event) {
      // Handled here: keep it from also aborting silently elsewhere.
      event.preventDefault();
      completer.completeError(
        BrowserStorageException(request.error?.name ?? 'UnknownError'),
      );
    }).toJS;
  return completer.future;
}

Future<void> _completion(web.IDBTransaction transaction) {
  final completer = Completer<void>();
  void fail(web.Event event) {
    if (completer.isCompleted) return;
    // A failed request reaches the transaction first as its own error
    // event, before the transaction records why it aborted.
    final target = event.target;
    final cause = target != null && target.isA<web.IDBRequest>()
        ? (target as web.IDBRequest).error
        : transaction.error;
    completer.completeError(
      BrowserStorageException(cause?.name ?? 'AbortError'),
    );
  }

  transaction
    ..oncomplete = ((web.Event _) => completer.complete()).toJS
    ..onerror = fail.toJS
    ..onabort = fail.toJS;
  return completer.future;
}
