import 'dart:convert';
import 'dart:math';

import 'package:meta/meta.dart';

import 'publishing_exception.dart';

/// The kinds of file a published page may show, as serv.pub checks them by
/// their first bytes. Never SVG, which can carry scripts.
enum MediaKind {
  jpeg('image/jpeg'),
  png('image/png'),
  webp('image/webp'),
  ogg('audio/ogg'),
  webm('audio/webm'),

  /// A recipe step's short clip, cleaned of its metadata on the device.
  mp4('video/mp4');

  const MediaKind(this.contentType);

  final String contentType;

  bool get isImage => this == jpeg || this == png || this == webp;

  bool get isVideo => this == mp4;
}

/// The name of one uploaded file on a site: random and new for every
/// upload, so it never repeats the id of a blob of the vault (which the
/// sync server knows) and a cached copy never changes under it.
@immutable
final class MediaId {
  MediaId(this.value) {
    if (value.length < minLength ||
        value.length > maxLength ||
        !_alphabet.hasMatch(value)) {
      throw const InvalidMediaIdException();
    }
  }

  /// 128 random bits in base64url, 22 symbols.
  factory MediaId.random(Random random) => MediaId(
    base64Url
        .encode(List.generate(16, (_) => random.nextInt(256)))
        .replaceAll('=', ''),
  );

  static const minLength = 16;
  static const maxLength = 64;
  static final _alphabet = RegExp(r'^[A-Za-z0-9_-]+$');

  final String value;

  @override
  bool operator ==(Object other) => other is MediaId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'MediaId($value)';
}
