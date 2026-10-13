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

/// Opening or creating the device's vault failed. Like every message in
/// this context, the reason never carries the passphrase or key material.
sealed class VaultException extends SyncException {
  const VaultException();
}

final class NoVaultException extends VaultException {
  const NoVaultException();

  @override
  String get message => 'no vault on this device';
}

/// A device holds one vault; creating another would orphan the first.
final class VaultAlreadyExistsException extends VaultException {
  const VaultAlreadyExistsException();

  @override
  String get message => 'a vault already exists on this device';
}

/// The passphrase does not open the identity, or the header around it was
/// altered: the two are indistinguishable by design.
final class WrongPassphraseException extends VaultException {
  const WrongPassphraseException();

  @override
  String get message => 'wrong passphrase or altered vault';
}

final class VaultLockedException extends VaultException {
  const VaultLockedException();

  @override
  String get message => 'vault is locked';
}

/// No passkey is enrolled for this vault on this device.
final class NoPasskeyException extends VaultException {
  const NoPasskeyException();

  @override
  String get message => 'no passkey enrolled on this device';
}

/// The passkey's key does not open the vault: another passkey answered, or
/// the slot or the header around it was altered. Like a wrong passphrase,
/// the cases are indistinguishable by design.
final class PasskeyRejectedException extends VaultException {
  const PasskeyRejectedException();

  @override
  String get message => 'passkey does not open this vault';
}

/// No offer of this account opens with the code: mistyped, or expired, or
/// another offer was made since. Indistinguishable by design.
final class LinkCodeRejectedException extends VaultException {
  const LinkCodeRejectedException();

  @override
  String get message => 'no link offer opens with this code';
}

/// The link was not completed in time; a new code is needed.
final class LinkExpiredException extends VaultException {
  const LinkExpiredException();

  @override
  String get message => 'device link expired';
}
