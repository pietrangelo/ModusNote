import 'dart:typed_data';

import 'package:blob_storage_media/blob_storage_media.dart';
import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';
import 'package:test/test.dart';

final keyId = SubkeyId.fromBytes(Uint8List(8));
final recordedAt = DateTime.utc(2026, 10, 11, 12);

SealedBlob sealed(int plaintextLength, [String id = 'b1']) =>
    SealedBlob(id: BlobId(id), keyId: keyId, plaintextLength: plaintextLength);

void main() {
  const chunk = ChunkLayout.plaintextChunkBytes;

  group('ChunkLayout', () {
    test('every blob has at least one chunk, so empty blobs carry a tag', () {
      expect(ChunkLayout.chunkCountFor(0), 1);
      expect(ChunkLayout.chunkCountFor(1), 1);
      expect(ChunkLayout.chunkCountFor(chunk), 1);
      expect(ChunkLayout.chunkCountFor(chunk + 1), 2);
      expect(ChunkLayout.chunkCountFor(3 * chunk), 3);
    });

    test('a frame is a 4-byte length prefix plus an envelope', () {
      expect(
        ChunkLayout.frameOverhead,
        4 + 1 + Nonce.length + EncryptedEnvelope.tagLength,
      );
      expect(
        ChunkLayout.ciphertextLengthFor(chunk + 1),
        chunk + 1 + 2 * ChunkLayout.frameOverhead,
      );
    });

    test('associated data binds blob, position and finality', () {
      final base = ChunkLayout.associatedDataFor(
        BlobId('b1'),
        index: 0,
        isFinal: false,
      );

      expect(
        ChunkLayout.associatedDataFor(BlobId('b1'), index: 0, isFinal: false),
        base,
      );
      for (final other in [
        ChunkLayout.associatedDataFor(BlobId('b2'), index: 0, isFinal: false),
        ChunkLayout.associatedDataFor(BlobId('b1'), index: 1, isFinal: false),
        ChunkLayout.associatedDataFor(BlobId('b1'), index: 0, isFinal: true),
      ]) {
        expect(other, isNot(base));
      }
    });

    test('frames round-trip through the length prefix', () {
      final envelope = EncryptedEnvelope(
        nonce: Nonce.fromBytes(Uint8List(Nonce.length)),
        ciphertext: Uint8List(EncryptedEnvelope.tagLength + 3),
      );
      final frame = ChunkLayout.encodeFrame(envelope);

      expect(frame, hasLength(3 + ChunkLayout.frameOverhead));
      expect(
        ByteData.sublistView(frame).getUint32(0),
        frame.length - ChunkLayout.lengthPrefixBytes,
      );
    });
  });

  group('SealedBlob', () {
    test('derives chunk count and ciphertext length from the plaintext', () {
      final blob = sealed(chunk * 2 + 5);

      expect(blob.chunkCount, 3);
      expect(blob.ciphertextLength, chunk * 2 + 5 + 3 * 45);
    });

    test('rejects negative or oversized lengths', () {
      for (final length in [-1, ChunkLayout.maxPlaintextBytes + 1]) {
        expect(
          () => sealed(length),
          throwsA(isA<InvalidBlobMetadataException>()),
          reason: '$length',
        );
      }
    });

    test('has value equality', () {
      expect(sealed(10), sealed(10));
      expect(sealed(10), isNot(sealed(11)));
      expect(sealed(10), isNot(sealed(10, 'b2')));
    });
  });

  group('BlobMetadata', () {
    BlobMetadata metadata({
      Duration duration = const Duration(seconds: 3),
      DateTime? at,
    }) => BlobMetadata(
      blob: sealed(100),
      format: AudioFormat.opusOgg,
      duration: duration,
      recordedAt: at ?? recordedAt,
    );

    test('exposes the blob id it describes', () {
      expect(metadata().id, BlobId('b1'));
    });

    test('rejects a negative duration', () {
      expect(
        () => metadata(duration: const Duration(milliseconds: -1)),
        throwsA(isA<InvalidBlobMetadataException>()),
      );
    });

    test('rejects a local timestamp, so ordering is device independent', () {
      expect(
        () => metadata(at: DateTime(2026, 10, 11)),
        throwsA(isA<InvalidBlobMetadataException>()),
      );
    });

    test('has value equality', () {
      expect(metadata(), metadata());
      expect(metadata(), isNot(metadata(duration: Duration.zero)));
    });
  });

  group('AudioFormat', () {
    test('every format has a MIME type and a unique wire name', () {
      final names = {for (final f in AudioFormat.values) f.wireName};

      expect(names, hasLength(AudioFormat.values.length));
      for (final format in AudioFormat.values) {
        expect(format.mimeType, startsWith('audio/'));
        expect(AudioFormat.fromWireName(format.wireName), format);
      }
    });

    test('an unknown wire name is malformed metadata, not a crash', () {
      expect(
        () => AudioFormat.fromWireName('audio/x-evil'),
        throwsA(isA<InvalidBlobMetadataException>()),
      );
    });
  });

  group('BlobException', () {
    test('messages are fixed strings that never echo payload bytes', () {
      final exceptions = <BlobException>[
        const TruncatedBlobException(),
        const MalformedBlobException('frame length out of bounds'),
        const InvalidBlobMetadataException('negative length'),
        BlobNotFoundException(BlobId('b1')),
        BlobAlreadyExistsException(BlobId('b1')),
      ];
      for (final exception in exceptions) {
        expect(exception.toString(), startsWith('${exception.runtimeType}: '));
      }
    });
  });
}
