import 'package:schema_dynamic_content/schema_dynamic_content.dart';

/// Failures of the Blob Storage & Media context.
///
/// Like every exception in the domain, messages are fixed strings: they may
/// reach a log or crash report and must never carry audio or ciphertext.
sealed class BlobException implements Exception {
  const BlobException();

  String get message;

  @override
  String toString() => '$runtimeType: $message';
}

/// The ciphertext ended before its final chunk: a cut download, a recording
/// interrupted by a crash, or an attacker dropping the tail.
final class TruncatedBlobException extends BlobException {
  const TruncatedBlobException();

  @override
  String get message => 'blob ends before its final chunk';
}

final class MalformedBlobException extends BlobException {
  const MalformedBlobException(this.message);

  @override
  final String message;
}

final class InvalidBlobMetadataException extends BlobException {
  const InvalidBlobMetadataException(this.message);

  @override
  final String message;
}

final class BlobNotFoundException extends BlobException {
  const BlobNotFoundException(this.id);

  final BlobId id;

  @override
  String get message => 'no committed blob ${id.value}';
}

/// Blob ids are never reused: overwriting one would let a stale or
/// malicious write replace audio another entry still points to.
final class BlobAlreadyExistsException extends BlobException {
  const BlobAlreadyExistsException(this.id);

  final BlobId id;

  @override
  String get message => 'blob ${id.value} already exists';
}

/// The user or the platform refused microphone access.
final class MicrophonePermissionDeniedException extends BlobException {
  const MicrophonePermissionDeniedException();

  @override
  String get message => 'microphone permission denied';
}

/// No decoder on this platform reads the recording's format (e.g. AAC
/// recorded by Safari, played back on a device without an AAC decoder).
final class UnsupportedAudioFormatException extends BlobException {
  const UnsupportedAudioFormatException();

  @override
  String get message => 'no decoder for this audio format';
}

/// Bytes that are not a PNG, JPEG, GIF or WebP picture whose size can be
/// read from its header.
final class UnsupportedImageException extends BlobException {
  const UnsupportedImageException();

  @override
  String get message => 'not a picture this app keeps';
}

/// A picture past `ImageProbe.maxBytes` or the limits in pixels.
final class ImageTooLargeException extends BlobException {
  const ImageTooLargeException();

  @override
  String get message => 'picture too large';
}

/// A recording longer than playback holds in memory
/// (`DecodedAudio.maxDuration`).
final class RecordingTooLongException extends BlobException {
  const RecordingTooLongException();

  @override
  String get message => 'recording too long to play';
}

/// The shared blob storage could not be reached: no network, a timeout or
/// a server error. Nothing was lost; the transfer is retried later.
final class RemoteBlobUnavailableException extends BlobException {
  const RemoteBlobUnavailableException();

  @override
  String get message => 'remote blob storage unavailable';
}

/// The shared blob storage refused the transfer (an account that is not
/// in the workspace, an expired session).
final class RemoteBlobRejectedException extends BlobException {
  const RemoteBlobRejectedException(this.status);

  final int status;

  @override
  String get message => 'remote blob storage refused ($status)';
}
