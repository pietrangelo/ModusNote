import 'dart:math';
import 'dart:typed_data';

import 'package:blob_storage_media/blob_storage_media.dart';
import 'package:offline_sync/offline_sync.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

/// Port: lets the person pick one picture from the device, as bytes.
/// Null when they cancel. Implementations leave no copy of their own
/// behind (a picker's cache file is deleted once read).
abstract interface class ImageChooser {
  /// Throws [ImageTooLargeException] for a file past
  /// [ImageProbe.maxBytes], before reading it.
  Future<Uint8List?> choose();
}

/// Port: lets the person pick or record one short video, as bytes. Null
/// when they cancel. Like [ImageChooser], no copy of its own is left.
abstract interface class VideoChooser {
  /// From the camera when [camera], else from the device's videos. Throws
  /// [VideoTooLargeException] for a file past [VideoProbe.maxBytes],
  /// before reading it.
  Future<Uint8List?> choose({required bool camera});
}

/// The pictures of the vault's notes, and the videos of recipes' steps: picked from the device straight into
/// blobs sealed under the current GroupKey, and opened again in memory,
/// downloaded first when another device added them.
final class NoteImages {
  NoteImages({
    required this.blobs,
    required this._engine,
    required this._chooser,
    this._videoChooser,
    this._ensureLocal,
    this._clock = DateTime.now,
    Random? random,
  }) : _images = ImageStorage(storage: blobs),
       _videos = VideoStorage(storage: blobs),
       _random = random ?? Random.secure();

  /// Where pictures land, beside the recordings.
  final EncryptedBlobStorage blobs;
  final ImageStorage _images;
  final SyncEngine _engine;
  final ImageChooser _chooser;
  final VideoStorage _videos;
  final VideoChooser? _videoChooser;

  /// Whether videos can be added here; off where nothing picks them.
  bool get takesVideos => _videoChooser != null;
  final Future<void> Function(SealedBlob blob)? _ensureLocal;
  final DateTime Function() _clock;
  final Random _random;

  /// A picture the person picks, sealed; null when they cancel. Throws
  /// [UnsupportedImageException] or [ImageTooLargeException] for a file
  /// this app does not keep.
  Future<KeyedImage?> choose() async {
    final bytes = await _chooser.choose();
    if (bytes == null) return null;
    try {
      final epoch = _engine.currentEpoch;
      final metadata = await _images.seal(
        bytes,
        id: _newBlobId(),
        contentKey: _engine.contentKeyFor(epoch),
        at: _clock(),
      );
      return KeyedImage(epoch: epoch, metadata: metadata);
    } finally {
      // The plaintext is ours to wipe once sealed.
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  /// The picture's bytes, checked against its metadata. Throws
  /// [RemoteBlobUnavailableException] when it must be downloaded and
  /// cannot be now, [MalformedBlobException] or [TruncatedBlobException]
  /// when it is damaged.
  Future<Uint8List> open(KeyedImage image) async {
    await _ensureLocal?.call(image.blob);
    return _images.open(
      image.metadata,
      contentKey: _engine.contentKeyFor(image.epoch),
    );
  }

  /// A video the person picks or records, cleaned of its metadata and
  /// sealed; null when they cancel. Throws [UnsupportedVideoException] or
  /// [VideoTooLargeException] for a file this app does not keep.
  Future<KeyedVideo?> chooseVideo({required bool camera}) async {
    final bytes = await _videoChooser?.choose(camera: camera);
    if (bytes == null) return null;
    try {
      final epoch = _engine.currentEpoch;
      final metadata = await _videos.seal(
        bytes,
        id: _newBlobId(),
        contentKey: _engine.contentKeyFor(epoch),
        at: _clock(),
      );
      return KeyedVideo(epoch: epoch, metadata: metadata);
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  /// The video's bytes, checked against its metadata; errors as [open].
  Future<Uint8List> openVideo(KeyedVideo video) async {
    await _ensureLocal?.call(video.blob);
    return _videos.open(
      video.metadata,
      contentKey: _engine.contentKeyFor(video.epoch),
    );
  }

  /// Opaque and random, like note ids: blob ids reach R2 in clear.
  BlobId _newBlobId() => BlobId(
    List.generate(
      16,
      (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join(),
  );
}
