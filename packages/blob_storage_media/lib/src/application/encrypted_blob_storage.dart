import 'dart:math';
import 'dart:typed_data';

import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import '../core/blob_exception.dart';
import '../core/blob_metadata.dart';
import '../core/chunk_layout.dart';
import 'ciphertext_blob_store.dart';

/// Use case: streams plaintext through chunked encryption into a
/// [CiphertextBlobStore], and back.
///
/// Each blob gets its own BlobKey, derived from the content key with a
/// fresh public [SubkeyId], so a key handed out for one blob opens nothing
/// else. Chunks are sealed as they fill: no plaintext waits on disk.
final class EncryptedBlobStorage {
  EncryptedBlobStorage({
    required this._store,
    required this._encryptor,
    required this._subkeys,
  });

  static final blobKeyContext = KeyContext('mn-blob1');

  final CiphertextBlobStore _store;
  final EnvelopeEncryptor _encryptor;
  final SubkeyDerivationService _subkeys;

  /// Encrypts [plaintext] into blob [id]. If [plaintext] errors, the write
  /// is aborted and the error rethrown: a blob is complete or absent.
  Future<SealedBlob> write(
    Stream<List<int>> plaintext, {
    required BlobId id,
    required SymmetricKey contentKey,
  }) async {
    final writer = await _store.create(id);
    final keyId = _subkeys.newSubkeyId();
    final blobKey = _blobKey(contentKey, keyId);
    final buffer = Uint8List(ChunkLayout.plaintextChunkBytes);
    try {
      var filled = 0;
      var index = 0;
      var total = 0;
      await for (final piece in plaintext) {
        total += piece.length;
        if (total > ChunkLayout.maxPlaintextBytes) {
          throw const MalformedBlobException('blob exceeds the maximum size');
        }
        var offset = 0;
        while (offset < piece.length) {
          // A full chunk is sealed only once more data proves it is not the
          // last, so the final flag is always truthful.
          if (filled == buffer.length) {
            await writer.add(_seal(buffer, blobKey, id, index++, false));
            filled = 0;
          }
          final take = min(buffer.length - filled, piece.length - offset);
          buffer.setRange(filled, filled + take, piece, offset);
          filled += take;
          offset += take;
        }
      }
      await writer.add(
        _seal(
          Uint8List.sublistView(buffer, 0, filled),
          blobKey,
          id,
          index,
          true,
        ),
      );
      await writer.commit();
      return SealedBlob(id: id, keyId: keyId, plaintextLength: total);
    } catch (_) {
      await writer.abort();
      rethrow;
    } finally {
      buffer.fillRange(0, buffer.length, 0);
      blobKey.dispose();
    }
  }

  /// Decrypts [blob] chunk by chunk. Every chunk is authenticated before it
  /// is yielded, in order; truncation can only be known at the end, so a
  /// consumer must treat a late error as "the recording is incomplete".
  Stream<Uint8List> read(
    SealedBlob blob, {
    required SymmetricKey contentKey,
  }) async* {
    final blobKey = _blobKey(contentKey, blob.keyId);
    try {
      final frames = _FrameReader();
      final lastIndex = blob.chunkCount - 1;
      var index = 0;
      await for (final piece in _store.read(blob.id)) {
        frames.add(piece);
        for (Uint8List? body; (body = frames.next()) != null;) {
          if (index > lastIndex) {
            throw const MalformedBlobException('data after the final chunk');
          }
          final plaintext = _encryptor.open(
            EncryptedEnvelope.parse(body!),
            key: blobKey,
            associatedData: ChunkLayout.associatedDataFor(
              blob.id,
              index: index,
              isFinal: index == lastIndex,
            ),
          );
          if (plaintext.length != _expectedLength(blob, index)) {
            throw const MalformedBlobException('chunk length mismatch');
          }
          index++;
          yield plaintext;
        }
      }
      if (frames.hasRemainder || index <= lastIndex) {
        throw const TruncatedBlobException();
      }
    } finally {
      blobKey.dispose();
    }
  }

  Future<void> delete(BlobId id) => _store.delete(id);

  SymmetricKey _blobKey(SymmetricKey contentKey, SubkeyId keyId) => _subkeys
      .deriveSubkey(parent: contentKey, context: blobKeyContext, id: keyId);

  Uint8List _seal(
    Uint8List chunk,
    SymmetricKey blobKey,
    BlobId id,
    int index,
    bool isFinal,
  ) => ChunkLayout.encodeFrame(
    _encryptor.seal(
      chunk,
      key: blobKey,
      associatedData: ChunkLayout.associatedDataFor(
        id,
        index: index,
        isFinal: isFinal,
      ),
    ),
  );

  static int _expectedLength(SealedBlob blob, int index) =>
      index < blob.chunkCount - 1
      ? ChunkLayout.plaintextChunkBytes
      : blob.plaintextLength -
            (blob.chunkCount - 1) * ChunkLayout.plaintextChunkBytes;
}

/// Splits a byte stream into frame bodies, rejecting a length prefix
/// outside one chunk's bounds before buffering a single byte of it.
final class _FrameReader {
  Uint8List _pending = Uint8List(0);

  bool get hasRemainder => _pending.isNotEmpty;

  void add(Uint8List piece) {
    _pending = _pending.isEmpty
        ? Uint8List.fromList(piece)
        : (Uint8List(_pending.length + piece.length)
            ..setAll(0, _pending)
            ..setAll(_pending.length, piece));
  }

  Uint8List? next() {
    const prefix = ChunkLayout.lengthPrefixBytes;
    if (_pending.length < prefix) return null;
    final length = ByteData.sublistView(_pending).getUint32(0);
    if (length < ChunkLayout.minEnvelopeBytes ||
        length > ChunkLayout.maxEnvelopeBytes) {
      throw const MalformedBlobException('frame length out of bounds');
    }
    if (_pending.length < prefix + length) return null;
    final body = Uint8List.sublistView(_pending, prefix, prefix + length);
    _pending = Uint8List.sublistView(_pending, prefix + length);
    return body;
  }
}
