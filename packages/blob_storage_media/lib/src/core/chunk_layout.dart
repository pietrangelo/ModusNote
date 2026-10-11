import 'dart:typed_data';

import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

/// Wire layout of an encrypted blob: a sequence of frames, each
/// `uint32 length | EncryptedEnvelope`, one per fixed-size plaintext chunk.
///
/// Every chunk is its own AEAD envelope whose associated data names the
/// blob, the chunk index and whether it is the last one (the STREAM
/// construction). That makes reordering, splicing chunks from another blob
/// and dropping the tail all detectable, while still letting a player
/// decrypt any chunk on its own for seeking or ranged downloads from R2.
abstract final class ChunkLayout {
  static const plaintextChunkBytes = 64 * 1024;

  /// About 70 hours of 32 kbit/s Opus; a bound so lengths stay small ints
  /// and a lying header cannot ask for unbounded work.
  static const maxPlaintextBytes = 1024 * 1024 * 1024;

  static const lengthPrefixBytes = 4;
  static const envelopeOverhead =
      1 + Nonce.length + EncryptedEnvelope.tagLength;
  static const frameOverhead = lengthPrefixBytes + envelopeOverhead;

  static const minEnvelopeBytes = envelopeOverhead;
  static const maxEnvelopeBytes = plaintextChunkBytes + envelopeOverhead;

  static const _context = 'modusnote.blob.chunk.v1';

  static int chunkCountFor(int plaintextLength) => plaintextLength == 0
      ? 1
      : (plaintextLength + plaintextChunkBytes - 1) ~/ plaintextChunkBytes;

  static int ciphertextLengthFor(int plaintextLength) =>
      plaintextLength + chunkCountFor(plaintextLength) * frameOverhead;

  /// BlobId only admits `[A-Za-z0-9_-]`, so `:` cannot be forged into it.
  static AssociatedData associatedDataFor(
    BlobId blob, {
    required int index,
    required bool isFinal,
  }) => AssociatedData.forContext(
    _context,
    '${blob.value}:$index:${isFinal ? 'final' : 'more'}',
  );

  static Uint8List encodeFrame(EncryptedEnvelope envelope) {
    final body = envelope.toBytes();
    final frame = Uint8List(lengthPrefixBytes + body.length);
    ByteData.sublistView(frame).setUint32(0, body.length);
    frame.setAll(lengthPrefixBytes, body);
    return frame;
  }
}
