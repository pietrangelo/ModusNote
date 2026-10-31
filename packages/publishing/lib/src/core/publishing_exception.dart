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
