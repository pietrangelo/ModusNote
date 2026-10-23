import 'dart:convert';
import 'dart:typed_data';

import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:meta/meta.dart';

import 'sync_exception.dart';
import 'wire.dart';

enum ServiceNoticeLevel {
  info(0),
  warning(1);

  const ServiceNoticeLevel(this.wireCode);

  final int wireCode;
}

/// A short text from the people who run the service ("update the app",
/// "maintenance on Sunday"), signed with an operator key the app pins, so
/// the server that hands it out cannot write one.
///
/// Wire (the body): `version(1) | serial(u32) | issued(int64 ms) |
/// expires(int64 ms) | level(u8) | count(u8) | (language(2) | length(u16) |
/// UTF-8 text)*`. Each text is plain: at most [maxTextLength] UTF-16 units
/// in at most [maxLines] lines, no other control or bidirectional
/// character, no spaces at its edges; never Markdown or a link.
@immutable
final class ServiceNotice {
  /// Throws [MalformedSyncDataException] for anything the wire format
  /// would refuse, so the operator's tool cannot sign a notice no device
  /// would show.
  ServiceNotice({
    required this.serial,
    required DateTime issued,
    required DateTime expires,
    required this.level,
    required Map<String, String> texts,
  }) : issued = issued.toUtc(),
       expires = expires.toUtc(),
       texts = Map.unmodifiable(texts) {
    if (serial < 0 || serial > 0xffffffff) {
      throw const MalformedSyncDataException('notice serial out of range');
    }
    _checkTimes(issued.millisecondsSinceEpoch, expires.millisecondsSinceEpoch);
    if (texts.isEmpty || texts.length > maxTexts) {
      throw const MalformedSyncDataException('notice needs one to four texts');
    }
    for (final MapEntry(:key, :value) in texts.entries) {
      _checkLanguage(key);
      _checkText(value);
    }
  }

  /// Throws [MalformedSyncDataException] for anything but one body.
  factory ServiceNotice.parse(List<int> body) {
    final reader = WireReader(body);
    if (reader.uint8() != _version) {
      throw const MalformedSyncDataException('unknown notice version');
    }
    final serial = reader.uint32();
    final issued = reader.int64();
    final expires = reader.int64();
    _checkTimes(issued, expires);
    final level = switch (reader.uint8()) {
      0 => ServiceNoticeLevel.info,
      1 => ServiceNoticeLevel.warning,
      _ => throw const MalformedSyncDataException('unknown notice level'),
    };
    final count = reader.uint8();
    if (count == 0 || count > maxTexts) {
      throw const MalformedSyncDataException('notice needs one to four texts');
    }
    final texts = <String, String>{};
    for (var i = 0; i < count; i++) {
      final language = String.fromCharCodes(reader.bytes(2));
      final length = reader.uint16();
      // UTF-8 never takes more than three bytes per UTF-16 unit.
      if (length > maxTextLength * 3) {
        throw const MalformedSyncDataException('notice text too long');
      }
      final String text;
      try {
        text = utf8.decode(reader.bytes(length));
      } on FormatException {
        throw const MalformedSyncDataException('notice text is not UTF-8');
      }
      if (texts.containsKey(language)) {
        throw const MalformedSyncDataException('notice language repeated');
      }
      texts[language] = text;
    }
    reader.finish();
    return ServiceNotice(
      serial: serial,
      issued: DateTime.fromMillisecondsSinceEpoch(issued, isUtc: true),
      expires: DateTime.fromMillisecondsSinceEpoch(expires, isUtc: true),
      level: level,
      texts: texts,
    );
  }

  static const label = 'modusnote.service-notice.v1';
  static const _version = 1;
  static const maxTexts = 4;
  static const maxTextLength = 600;
  static const maxLines = 8;
  static const maxDuration = Duration(days: 90);

  // The latest instant a DateTime holds; well within 2^53 − 1.
  static const _maxMillis = 8640000000000000;
  static final _language = RegExp(r'^[a-z]{2}$');

  // Control and bidirectional formatting characters would let a text
  // render as something else; a line break is the one allowed, and the
  // Unicode line and paragraph separators would get around the line cap.
  static final _unsafe = RegExp(
    r'[\x00-\x09\x0B-\x1F\x7F-\x9F\u061C\u200E\u200F\u2028\u2029'
    r'\u202A-\u202E\u2066-\u2069]',
  );

  /// Raises the operator's changes in order; a later notice has a higher
  /// one. A device remembers which serials the person closed.
  final int serial;
  final DateTime issued;

  /// No device shows the notice from this instant on.
  final DateTime expires;
  final ServiceNoticeLevel level;

  /// By two-letter language code, in the order the operator wrote them.
  final Map<String, String> texts;

  /// The text in [languageCode], else in English, else the first one.
  String textFor(String languageCode) =>
      texts[languageCode] ?? texts['en'] ?? texts.values.first;

  Uint8List toBytes() {
    final writer = WireWriter()
      ..uint8(_version)
      ..uint32(serial)
      ..int64(issued.millisecondsSinceEpoch)
      ..int64(expires.millisecondsSinceEpoch)
      ..uint8(level.wireCode)
      ..uint8(texts.length);
    for (final MapEntry(:key, :value) in texts.entries) {
      final text = utf8.encode(value);
      writer
        ..bytes(ascii.encode(key))
        ..uint16(text.length)
        ..bytes(text);
    }
    return writer.take();
  }

  /// What the operator key signs: the purpose label, then the body.
  Uint8List get signable =>
      Uint8List.fromList([...ascii.encode(label), ...toBytes()]);

  static void _checkTimes(int issued, int expires) {
    if (issued < 0 || expires > _maxMillis) {
      throw const MalformedSyncDataException('notice time out of range');
    }
    final lasts = expires - issued;
    if (lasts <= 0 || lasts > maxDuration.inMilliseconds) {
      throw const MalformedSyncDataException('notice lasts too long or never');
    }
  }

  static void _checkLanguage(String language) {
    if (!_language.hasMatch(language)) {
      throw const MalformedSyncDataException('bad notice language');
    }
  }

  static void _checkText(String text) {
    if (text.isEmpty ||
        text.length > maxTextLength ||
        text.trim() != text ||
        '\n'.allMatches(text).length >= maxLines ||
        _unsafe.hasMatch(text) ||
        _hasLoneSurrogate(text)) {
      throw const MalformedSyncDataException('bad notice text');
    }
  }

  /// A lone surrogate has no UTF-8 form: it would be signed as one text
  /// and shown as another.
  static bool _hasLoneSurrogate(String text) {
    for (var i = 0; i < text.length; i++) {
      final unit = text.codeUnitAt(i);
      if (unit >= 0xD800 && unit <= 0xDBFF) {
        final next = i + 1 < text.length ? text.codeUnitAt(i + 1) : 0;
        if (next < 0xDC00 || next > 0xDFFF) return true;
        i++;
      } else if (unit >= 0xDC00 && unit <= 0xDFFF) {
        return true;
      }
    }
    return false;
  }

  @override
  bool operator ==(Object other) =>
      other is ServiceNotice &&
      other.serial == serial &&
      other.issued == issued &&
      other.expires == expires &&
      other.level == level &&
      _sameTexts(other.texts, texts);

  @override
  int get hashCode => Object.hash(
    serial,
    issued,
    expires,
    level,
    Object.hashAll([
      for (final e in texts.entries) Object.hash(e.key, e.value),
    ]),
  );

  /// Same texts in the same order: the order decides the fallback.
  static bool _sameTexts(Map<String, String> a, Map<String, String> b) {
    if (a.length != b.length) return false;
    final left = a.entries.toList();
    final right = b.entries.toList();
    for (var i = 0; i < left.length; i++) {
      if (left[i].key != right[i].key || left[i].value != right[i].value) {
        return false;
      }
    }
    return true;
  }
}

/// A [ServiceNotice] with the operator's signature, as published in
/// `notices.json`.
///
/// Wire: `body | signature(64)`, the Ed25519 signature over
/// [ServiceNotice.signable].
@immutable
final class SignedServiceNotice {
  const SignedServiceNotice({required this.notice, required this.signature});

  /// Throws [MalformedSyncDataException] for anything but one envelope.
  /// The signature is not checked here: that takes the pinned keys.
  factory SignedServiceNotice.parse(List<int> envelope) {
    final split = envelope.length - Signature.length;
    if (split <= 0) {
      throw const MalformedSyncDataException('notice too short');
    }
    final bytes = Uint8List.fromList(envelope);
    return SignedServiceNotice(
      notice: ServiceNotice.parse(Uint8List.sublistView(bytes, 0, split)),
      signature: Signature.fromBytes(Uint8List.sublistView(bytes, split)),
    );
  }

  final ServiceNotice notice;
  final Signature signature;

  Uint8List get signedMessage => notice.signable;

  Uint8List toBytes() =>
      Uint8List.fromList([...notice.toBytes(), ...signature.bytes]);
}
