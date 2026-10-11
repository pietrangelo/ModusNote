import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:meta/meta.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import 'audio_format.dart';
import 'blob_exception.dart';
import 'chunk_layout.dart';

/// What a reader needs to decrypt and verify a blob: which BlobKey to
/// derive and how long the plaintext must be. Knowing the exact length is
/// what turns a dropped or appended chunk into a detectable error.
@immutable
final class SealedBlob {
  SealedBlob({
    required this.id,
    required this.keyId,
    required this.plaintextLength,
  }) {
    if (plaintextLength < 0 ||
        plaintextLength > ChunkLayout.maxPlaintextBytes) {
      throw const InvalidBlobMetadataException('plaintext length out of range');
    }
  }

  final BlobId id;

  /// Selects the BlobKey under the content key; public by design.
  final SubkeyId keyId;
  final int plaintextLength;

  int get chunkCount => ChunkLayout.chunkCountFor(plaintextLength);

  int get ciphertextLength => ChunkLayout.ciphertextLengthFor(plaintextLength);

  @override
  bool operator ==(Object other) =>
      other is SealedBlob &&
      other.id == id &&
      other.keyId == keyId &&
      other.plaintextLength == plaintextLength;

  @override
  int get hashCode => Object.hash(id, keyId, plaintextLength);
}

/// Describes one encrypted audio blob. It travels only inside encrypted
/// entry payloads: the server sees the `.enc` object and its size, never
/// the format, duration or recording time.
@immutable
final class BlobMetadata {
  BlobMetadata({
    required this.blob,
    required this.format,
    required this.duration,
    required this.recordedAt,
  }) {
    if (duration.isNegative) {
      throw const InvalidBlobMetadataException('negative duration');
    }
    if (!recordedAt.isUtc) {
      throw const InvalidBlobMetadataException('recordedAt must be UTC');
    }
  }

  final SealedBlob blob;
  final AudioFormat format;
  final Duration duration;
  final DateTime recordedAt;

  BlobId get id => blob.id;

  @override
  bool operator ==(Object other) =>
      other is BlobMetadata &&
      other.blob == blob &&
      other.format == format &&
      other.duration == duration &&
      other.recordedAt == recordedAt;

  @override
  int get hashCode => Object.hash(blob, format, duration, recordedAt);
}
