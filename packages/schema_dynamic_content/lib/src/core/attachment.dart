import 'package:meta/meta.dart';

import 'identifiers.dart';
import 'schema_exception.dart';
import 'unsafe_text.dart';

/// Something placed in a page beside its text: a picture or a link.
///
/// Both are held as written and drawn by the app; nothing is fetched to
/// show them. A picture is an encrypted blob of this vault, so showing it
/// asks no server; a link is only text until the person taps it and says
/// yes.
@immutable
sealed class Attachment {
  const Attachment();

  /// Longest caption or link title, in characters.
  static const maxText = 200;

  /// The words a person wrote for it, searched like the rest of the note.
  String get text;
}

String _oneSafeLine(String text, String what) {
  final trimmed = text.trim();
  if (trimmed.runes.length > Attachment.maxText) {
    throw InvalidValueException('$what too long');
  }
  if (containsUnsafeCharacters(trimmed)) {
    throw InvalidValueException('$what characters');
  }
  return trimmed;
}

/// A picture stored as an encrypted blob, like a recording. Its format,
/// size and key travel sealed beside the note, never in the entry.
final class ImageAttachment extends Attachment {
  ImageAttachment(this.blob, {String caption = ''})
    : caption = _oneSafeLine(caption, 'caption');

  final BlobId blob;

  /// What the picture shows, in the person's words; may be empty.
  final String caption;

  @override
  String get text => caption;

  ImageAttachment captioned(String caption) =>
      ImageAttachment(blob, caption: caption);

  @override
  bool operator ==(Object other) =>
      other is ImageAttachment &&
      other.blob == blob &&
      other.caption == caption;

  @override
  int get hashCode => Object.hash(blob, caption);
}

/// An address on the web, kept as text. The app never fetches it (no
/// preview, no icon, no title lookup): the server of that page learns
/// nothing until the person opens it.
///
/// Only `http` and `https`, without credentials, in printable ASCII: no
/// scheme that runs code or reaches the device (`javascript:`, `file:`,
/// `intent:`), and no look-alike letters from other scripts in the host,
/// so the address shown is the address opened.
final class WebLink extends Attachment {
  /// A link exactly as [parse] would write it; throws
  /// [InvalidValueException] otherwise.
  factory WebLink(String url, {String title = ''}) {
    final link = parse(url, title: title);
    if (link == null || link.url != url) {
      throw const InvalidValueException('malformed link');
    }
    return link;
  }

  WebLink._(this.url, this.title, this.host);

  static const maxLength = 2048;

  static final _printableAscii = RegExp(r'^[\x21-\x7E]+$');

  /// What a person typed or pasted, made a link; null when it is not one
  /// this app opens. An address without a scheme is taken as `https`.
  static WebLink? parse(String input, {String title = ''}) {
    var text = input.trim();
    if (text.isEmpty ||
        text.length > maxLength ||
        !_printableAscii.hasMatch(text)) {
      return null;
    }
    var uri = Uri.tryParse(text);
    if (uri != null && !uri.hasScheme) {
      text = 'https://$text';
      if (text.length > maxLength) return null;
      uri = Uri.tryParse(text);
    }
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        !text.startsWith('${uri.scheme}://') ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      return null;
    }
    try {
      return WebLink._(text, _oneSafeLine(title, 'title'), uri.host);
    } on InvalidValueException {
      return null;
    }
  }

  /// The address, as it will be opened.
  final String url;

  /// What the person called it; may be empty.
  final String title;

  /// The site, shown beside the title so the destination is never hidden.
  final String host;

  @override
  String get text => title;

  @override
  bool operator ==(Object other) =>
      other is WebLink && other.url == url && other.title == title;

  @override
  int get hashCode => Object.hash(url, title);
}
