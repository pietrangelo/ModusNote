import 'dart:async';
import 'dart:typed_data';

import 'package:blob_storage_media/blob_storage_media.dart';
import 'package:publishing/publishing.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

/// [PublicationMedia] for the vault's notes: a picture is opened and
/// encoded again by [reencode] (no metadata of the original survives, see
/// `reencodePicture`); a recording is passed as it is only when it is Opus
/// in Ogg or WebM, the containers serv.pub takes (a WAV or AAC take is left
/// out); a step's video is opened and cleaned again ([VideoScrubber]),
/// though it was cleaned before it was sealed: what leaves the device is
/// checked where it leaves.
final class VaultPublicationMedia implements PublicationMedia {
  VaultPublicationMedia({
    required this._imageOf,
    required this._recordingOf,
    required this._openImage,
    required this._openRecording,
    required this._reencode,
    this._videoOf,
    this._openVideo,
  });

  final KeyedImage? Function(BlobId blob) _imageOf;
  final KeyedRecording? Function(BlobId blob) _recordingOf;
  final Future<Uint8List> Function(KeyedImage image) _openImage;
  final Stream<Uint8List> Function(KeyedRecording take) _openRecording;
  final Future<Uint8List?> Function(Uint8List picture) _reencode;
  final KeyedVideo? Function(BlobId blob)? _videoOf;
  final Future<Uint8List> Function(KeyedVideo video)? _openVideo;

  /// serv.pub's limit for one file.
  static const maxBytes = 21 << 20;

  @override
  Future<PreparedMedia?> prepare(BlobId blob) async {
    if (_imageOf(blob) case final image?) {
      final original = await _openImage(image);
      try {
        final clean = await _reencode(original);
        if (clean == null || clean.length > maxBytes) return null;
        return PreparedMedia(MediaKind.png, clean);
      } finally {
        original.fillRange(0, original.length, 0);
      }
    }
    if ((_videoOf?.call(blob), _openVideo) case (final video?, final open?)) {
      final original = await open(video);
      try {
        final clean = VideoScrubber.scrub(original);
        if (clean.length > maxBytes) return null;
        return PreparedMedia(MediaKind.mp4, clean);
      } on BlobException {
        return null;
      } finally {
        original.fillRange(0, original.length, 0);
      }
    }
    if (_recordingOf(blob) case final take?) {
      final kind = switch (take.metadata.format) {
        AudioFormat.opusOgg => MediaKind.ogg,
        AudioFormat.opusWebm => MediaKind.webm,
        AudioFormat.pcm16Wav || AudioFormat.aacMp4 => null,
      };
      if (kind == null || take.blob.plaintextLength > maxBytes) return null;
      final out = BytesBuilder(copy: false);
      await for (final chunk in _openRecording(take)) {
        out.add(chunk);
        if (out.length > maxBytes) return null;
      }
      return PreparedMedia(kind, out.takeBytes());
    }
    return null;
  }
}
