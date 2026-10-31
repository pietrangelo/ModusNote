/// Failures of the Publishing context.
///
/// Messages are fixed strings: they may reach a log and must never carry
/// the content of a note.
sealed class PublishingException implements Exception {
  const PublishingException();

  String get message;

  @override
  String toString() => '$runtimeType: $message';
}

final class InvalidSiteNameException extends PublishingException {
  const InvalidSiteNameException();

  @override
  String get message => 'not a valid site name';
}

final class InvalidPageSlugException extends PublishingException {
  const InvalidPageSlugException();

  @override
  String get message => 'not a valid page slug';
}

final class InvalidColorException extends PublishingException {
  const InvalidColorException();

  @override
  String get message => 'not a valid colour or hue';
}

/// The note, or a part of it asked for, may not be made public.
final class NotPublishableException extends PublishingException {
  const NotPublishableException(this.message);

  @override
  final String message;
}

final class InvalidMediaIdException extends PublishingException {
  const InvalidMediaIdException();

  @override
  String get message => 'not a valid media id';
}

/// The vault has no site yet: one must be claimed first.
final class NoSiteException extends PublishingException {
  const NoSiteException();

  @override
  String get message => 'no site';
}

/// Someone else holds the site's name on serv.pub.
final class SiteNameTakenException extends PublishingException {
  const SiteNameTakenException();

  @override
  String get message => 'site name taken';
}

/// Publishing makes a note readable by anyone: the person must prove
/// again, at the device, that the vault is theirs.
final class PublishingConfirmationRequiredException
    extends PublishingException {
  const PublishingConfirmationRequiredException();

  @override
  String get message => 'confirmation required';
}

/// serv.pub refused the request for good (a limit, a page it does not
/// accept): retrying the same will not help.
final class PublishingRejectedException extends PublishingException {
  const PublishingRejectedException(this.reason);

  final PublishingRejection reason;

  @override
  String get message => 'rejected: ${reason.name}';
}

enum PublishingRejection {
  /// Over a site's pages, files or bytes, or a file too large.
  limit,

  /// Not the site's key.
  notOwner,

  /// The server would not take the page or the file as it is.
  invalid,
}

/// serv.pub could not be reached, or was busy: trying again later may work.
final class PublishingUnavailableException extends PublishingException {
  const PublishingUnavailableException();

  @override
  String get message => 'unavailable';
}
