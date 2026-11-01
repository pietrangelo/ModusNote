import 'dart:typed_data';

import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import '../core/blob_exception.dart';
import '../core/video_format.dart';
import 'encrypted_blob_storage.dart';

/// Use case: the short videos of a recipe's steps in and out of encrypted
/// blobs, whole and in memory (21 MiB at most).
///
/// A video is cleaned before it is sealed ([VideoScrubber]): the vault
/// never holds the location or the device a phone wrote into it. It is
/// checked again after it is opened, like a picture: the metadata comes
/// from whoever wrote the note.
final class VideoStorage {
  VideoStorage({required this._storage});

  final EncryptedBlobStorage _storage;

  /// Seals a clean copy of [bytes] into blob [id]. Throws
  /// [UnsupportedVideoException] or [VideoTooLargeException] without
  /// writing anything.
  Future<VideoMetadata> seal(
    Uint8List bytes, {
    required BlobId id,
    required SymmetricKey contentKey,
    required DateTime at,
  }) async {
    final clean = VideoScrubber.scrub(bytes);
    final info = VideoProbe.probe(clean);
    final blob = await _storage.write(
      Stream.value(clean),
      id: id,
      contentKey: contentKey,
    );
    return VideoMetadata(blob: blob, info: info, addedAt: at.toUtc());
  }

  /// The video's bytes, authenticated chunk by chunk. Throws
  /// [MalformedBlobException] when they are not the video the metadata
  /// describes.
  Future<Uint8List> open(
    VideoMetadata video, {
    required SymmetricKey contentKey,
  }) async {
    final out = BytesBuilder(copy: false);
    await for (final chunk in _storage.read(
      video.blob,
      contentKey: contentKey,
    )) {
      out.add(chunk);
    }
    final bytes = out.takeBytes();
    final VideoHeader info;
    try {
      info = VideoProbe.probe(bytes);
    } on UnsupportedVideoException {
      throw const MalformedBlobException('not the video described');
    } on VideoTooLargeException {
      throw const MalformedBlobException('not the video described');
    }
    if (info != video.info) {
      throw const MalformedBlobException('not the video described');
    }
    return bytes;
  }
}
