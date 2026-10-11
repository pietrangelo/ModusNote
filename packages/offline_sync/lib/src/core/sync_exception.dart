/// Failures of the Offline Sync context.
///
/// Messages are fixed strings: they may reach a log or crash report and must
/// never carry payloads, keys or ciphertext.
sealed class SyncException implements Exception {
  const SyncException();

  String get message;

  @override
  String toString() => '$runtimeType: $message';
}

final class MalformedSyncDataException extends SyncException {
  const MalformedSyncDataException(this.message);

  @override
  final String message;
}

/// A revision failed authentication: bad signature, wrong record, wrong
/// epoch, or an author without the right to write. It is discarded.
final class RejectedRevisionException extends SyncException {
  const RejectedRevisionException(this.message);

  @override
  final String message;
}

/// A revision cites a membership record this device has not verified yet;
/// the log has to be fetched before the revision can be judged.
final class LedgerBehindException extends SyncException {
  const LedgerBehindException();

  @override
  String get message => 'revision cites an unknown membership record';
}

/// Another member has seen membership records the server will not give us,
/// or a different record at the same position: the server is withholding or
/// forking the log. Sync stops for this workspace until it is resolved.
final class LedgerRollbackException extends SyncException {
  const LedgerRollbackException();

  @override
  String get message => 'server is withholding or forking the membership log';
}

/// The sync server could not be reached; queued work stays queued.
final class ServerUnavailableException extends SyncException {
  const ServerUnavailableException();

  @override
  String get message => 'sync server unavailable';
}
