import 'dart:typed_data';

import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import '../core/blob_exception.dart';
import '../core/image_format.dart';
import 'encrypted_blob_storage.dart';

/// Use case: pictures in and out of encrypted blobs, whole and in memory.
///
/// A picture is checked before it is sealed (a format every platform
/// decodes, a size it can hold) and again after it is opened: the
/// metadata comes from whoever wrote the note, so the bytes must agree
/// with it before any decoder sees them.
final class ImageStorage {
  ImageStorage({required this._storage});

  final EncryptedBlobStorage _storage;

  /// Seals [bytes] into blob [id]. Throws [UnsupportedImageException] or
  /// [ImageTooLargeException] without writing anything.
  Future<ImageMetadata> seal(
    Uint8List bytes, {
    required BlobId id,
    required SymmetricKey contentKey,
    required DateTime at,
  }) async {
    final info = ImageProbe.probe(bytes);
    final blob = await _storage.write(
      Stream.value(bytes),
      id: id,
      contentKey: contentKey,
    );
    return ImageMetadata(blob: blob, info: info, addedAt: at.toUtc());
  }

  /// The picture's bytes, authenticated chunk by chunk. Throws
  /// [MalformedBlobException] when they are not the picture the metadata
  /// describes.
  Future<Uint8List> open(
    ImageMetadata image, {
    required SymmetricKey contentKey,
  }) async {
    // The blob's own length bounds the buffer: [EncryptedBlobStorage.read]
    // refuses any chunk past it.
    final out = BytesBuilder(copy: false);
    await for (final chunk in _storage.read(
      image.blob,
      contentKey: contentKey,
    )) {
      out.add(chunk);
    }
    final bytes = out.takeBytes();
    final ImageHeader info;
    try {
      info = ImageProbe.probe(bytes);
    } on UnsupportedImageException {
      throw const MalformedBlobException('not the picture described');
    } on ImageTooLargeException {
      throw const MalformedBlobException('not the picture described');
    }
    if (info != image.info) {
      throw const MalformedBlobException('not the picture described');
    }
    return bytes;
  }
}
