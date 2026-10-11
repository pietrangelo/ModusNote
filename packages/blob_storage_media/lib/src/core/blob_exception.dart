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
