/// Failures of the Collaboration & Access Control context.
///
/// Messages are fixed strings: they may reach a log or crash report and must
/// never carry keys, identities or ciphertext.
sealed class CollaborationException implements Exception {
  const CollaborationException();

  String get message;

  @override
  String toString() => '$runtimeType: $message';
}

final class InvalidWorkspaceValueException extends CollaborationException {
  const InvalidWorkspaceValueException(this.message);

  @override
  final String message;
}

/// The author of a membership change lacks the role it requires, or is not
/// a member at all.
final class NotAuthorizedException extends CollaborationException {
  const NotAuthorizedException();

  @override
  String get message => 'author may not make this membership change';
}

final class AlreadyMemberException extends CollaborationException {
  const AlreadyMemberException();

  @override
  String get message => 'identity is already a member';
}

final class NotAMemberException extends CollaborationException {
  const NotAMemberException();

  @override
  String get message => 'identity is not a member';
}

/// A workspace without an owner could never change membership or rotate its
/// GroupKey again.
final class LastOwnerException extends CollaborationException {
  const LastOwnerException();

  @override
  String get message => 'a workspace must keep at least one owner';
}

final class InvalidMembershipChangeException extends CollaborationException {
  const InvalidMembershipChangeException(this.message);

  @override
  final String message;
}

/// A membership record or KeyBundle failed verification: bad signature,
/// broken chain, wrong workspace, or an issuer without authority. Whatever
/// carried it (usually the sync server) is not to be trusted for it.
final class TamperedWorkspaceDataException extends CollaborationException {
  const TamperedWorkspaceDataException(this.message);

  @override
  final String message;
}

final class MalformedWorkspaceDataException extends CollaborationException {
  const MalformedWorkspaceDataException(this.message);

  @override
  final String message;
}

/// No GroupKey for the epoch a ciphertext was sealed under: the device was
/// never granted it (for instance because it was revoked before then).
final class MissingGroupKeyException extends CollaborationException {
  const MissingGroupKeyException();

  @override
  String get message => 'no group key for this epoch';
}
