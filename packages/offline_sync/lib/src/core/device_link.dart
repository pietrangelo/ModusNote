import 'dart:math';
import 'dart:typed_data';

import 'package:collaboration_access_control/collaboration_access_control.dart';
import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:meta/meta.dart';

import 'sync_exception.dart';
import 'wire.dart';

/// The one-time code a device in the workspace shows and a new device
/// types to join it: ten symbols of Crockford's base 32, 50 bits.
///
/// Argon2id stretches it into the key that seals the link's two messages,
/// so the server relaying them would have to guess it within the link's
/// lifetime, at the cost of one Argon2id per guess, to pass off a device
/// or a workspace of its own.
@immutable
final class LinkCode {
  const LinkCode._(this._symbols);

  factory LinkCode.random(Random random) => LinkCode._(
    String.fromCharCodes([
      for (var i = 0; i < length; i++)
        _alphabet.codeUnitAt(random.nextInt(_alphabet.length)),
    ]),
  );

  /// Reads a typed code: case, spaces and dashes are ignored, and the
  /// letters people confuse with digits (O, I, L) read as those digits.
  static LinkCode? tryParse(String input) {
    final symbols = StringBuffer();
    for (final char in input.toUpperCase().split('')) {
      if (char == ' ' || char == '-') continue;
      final symbol = switch (char) {
        'O' => '0',
        'I' || 'L' => '1',
        _ => char,
      };
      if (!_alphabet.contains(symbol)) return null;
      symbols.write(symbol);
    }
    final code = symbols.toString();
    return code.length == length ? LinkCode._(code) : null;
  }

  static const length = 10;
  static const bits = 50;
  static const _alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

  final String _symbols;

  /// As shown on screen: `K7MQ4-XT9AB`.
  String get display => '${_symbols.substring(0, 5)}-${_symbols.substring(5)}';

  /// The symbols as ASCII, to be moved into a [PasswordSecret].
  Uint8List toBytes() => Uint8List.fromList(_symbols.codeUnits);

  @override
  bool operator ==(Object other) =>
      other is LinkCode && other._symbols == _symbols;

  @override
  int get hashCode => _symbols.hashCode;

  @override
  String toString() => 'LinkCode(hidden)';
}

/// Random id of one linking attempt; the only part the server can read.
@immutable
final class LinkId {
  const LinkId._(this.hex);

  factory LinkId.parse(String hex) {
    if (!_hex32.hasMatch(hex)) {
      throw const MalformedSyncDataException('malformed link id');
    }
    return LinkId._(hex);
  }

  factory LinkId.random(Random random) => LinkId._(
    List.generate(
      length,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join(),
  );

  static const length = 16;
  static final _hex32 = RegExp(r'^[0-9a-f]{32}$');

  final String hex;

  Uint8List get bytes => Uint8List.fromList([
    for (var i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ]);

  static LinkId _read(WireReader reader) => LinkId._(
    reader.bytes(length).map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
  );

  @override
  bool operator ==(Object other) => other is LinkId && other.hex == hex;

  @override
  int get hashCode => hex.hashCode;
}

/// What the device already in the workspace posts: the [Invitation] that
/// pins the workspace and its founder, sealed under the code's key.
///
/// Wire: `kind(1) | id(16) | salt(16) | sealedInvitation(blob)`.
@immutable
final class LinkOffer {
  const LinkOffer({
    required this.id,
    required this.salt,
    required this.sealedInvitation,
  });

  factory LinkOffer.parse(List<int> wire) {
    final reader = WireReader(wire);
    if (reader.uint8() != _kind) {
      throw const MalformedSyncDataException('not a link offer');
    }
    final id = LinkId._read(reader);
    final salt = Salt.fromBytes(reader.bytes(Salt.length));
    final sealed = _envelope(reader.blob(), invitationLength);
    reader.finish();
    return LinkOffer(id: id, salt: salt, sealedInvitation: sealed);
  }

  static const _kind = 1;
  static const invitationLength = Invitation.length;

  final LinkId id;

  /// Argon2id salt for the code; fresh for every offer.
  final Salt salt;
  final EncryptedEnvelope sealedInvitation;

  static AssociatedData associatedData(LinkId id) =>
      AssociatedData.forContext('modusnote.link.offer.v1', id.hex);

  Uint8List toBytes() =>
      (WireWriter()
            ..uint8(_kind)
            ..bytes(id.bytes)
            ..bytes(salt.bytes)
            ..blob(sealedInvitation.toBytes()))
          .take();

  @override
  bool operator ==(Object other) =>
      other is LinkOffer &&
      other.id == id &&
      other.salt == salt &&
      other.sealedInvitation == sealedInvitation;

  @override
  int get hashCode => Object.hash(id, salt, sealedInvitation);
}

/// What the joining device posts back: its [PublicIdentity], sealed under
/// the same key, so only a device that knew the code can be admitted.
///
/// Wire: `kind(1) | id(16) | sealedIdentity(blob)`.
@immutable
final class LinkAnswer {
  const LinkAnswer({required this.id, required this.sealedIdentity});

  factory LinkAnswer.parse(List<int> wire) {
    final reader = WireReader(wire);
    if (reader.uint8() != _kind) {
      throw const MalformedSyncDataException('not a link answer');
    }
    final id = LinkId._read(reader);
    final sealed = _envelope(reader.blob(), PublicIdentity.length);
    reader.finish();
    return LinkAnswer(id: id, sealedIdentity: sealed);
  }

  static const _kind = 2;

  final LinkId id;
  final EncryptedEnvelope sealedIdentity;

  static AssociatedData associatedData(LinkId id) =>
      AssociatedData.forContext('modusnote.link.answer.v1', id.hex);

  Uint8List toBytes() =>
      (WireWriter()
            ..uint8(_kind)
            ..bytes(id.bytes)
            ..blob(sealedIdentity.toBytes()))
          .take();

  @override
  bool operator ==(Object other) =>
      other is LinkAnswer &&
      other.id == id &&
      other.sealedIdentity == sealedIdentity;

  @override
  int get hashCode => Object.hash(id, sealedIdentity);
}

/// The sealed payload's size is known in advance; anything else is refused
/// before it reaches the cipher.
EncryptedEnvelope _envelope(Uint8List bytes, int plaintextLength) {
  final EncryptedEnvelope envelope;
  try {
    envelope = EncryptedEnvelope.parse(bytes);
  } on CryptographyException {
    throw const MalformedSyncDataException('malformed link payload');
  }
  if (envelope.ciphertext.length !=
      plaintextLength + EncryptedEnvelope.tagLength) {
    throw const MalformedSyncDataException('link payload of the wrong size');
  }
  return envelope;
}
