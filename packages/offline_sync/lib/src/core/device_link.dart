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

/// The one-time code an owner gives another person to invite them: sixteen
/// symbols of Crockford's base 32. The first six are the offer's lookup,
/// the only part the server learns; the other ten (50 bits) it would have
/// to guess, one Argon2id per guess, within the invitation's lifetime.
@immutable
final class InviteCode {
  const InviteCode._(this._symbols);

  factory InviteCode.random(Random random) => InviteCode._(
    String.fromCharCodes([
      for (var i = 0; i < length; i++)
        LinkCode._alphabet.codeUnitAt(
          random.nextInt(LinkCode._alphabet.length),
        ),
    ]),
  );

  /// Reads a typed code like [LinkCode.tryParse] does.
  static InviteCode? tryParse(String input) {
    final symbols = StringBuffer();
    for (final char in input.toUpperCase().split('')) {
      if (char == ' ' || char == '-') continue;
      final symbol = switch (char) {
        'O' => '0',
        'I' || 'L' => '1',
        _ => char,
      };
      if (!LinkCode._alphabet.contains(symbol)) return null;
      symbols.write(symbol);
    }
    final code = symbols.toString();
    return code.length == length ? InviteCode._(code) : null;
  }

  static const length = 16;
  static const lookupLength = 6;

  final String _symbols;

  /// What the server may see: the first six symbols.
  String get lookup => _symbols.substring(0, lookupLength);

  /// As shown on screen: `K7MQ4X-T9ABC-D2EFG`.
  String get display =>
      '${_symbols.substring(0, 6)}-${_symbols.substring(6, 11)}'
      '-${_symbols.substring(11)}';

  /// The symbols as ASCII, to be moved into a [PasswordSecret].
  Uint8List toBytes() => Uint8List.fromList(_symbols.codeUnits);

  @override
  bool operator ==(Object other) =>
      other is InviteCode && other._symbols == _symbols;

  @override
  int get hashCode => _symbols.hashCode;

  @override
  String toString() => 'InviteCode(hidden)';
}

/// The sync server's id of an account (a Supabase user id), as the
/// invitee tells it to the owner inside its sealed answer.
@immutable
final class AccountId {
  const AccountId._(this.uuid);

  factory AccountId.parse(String uuid) {
    final lower = uuid.toLowerCase();
    if (!_uuid.hasMatch(lower)) {
      throw const MalformedSyncDataException('malformed account id');
    }
    return AccountId._(lower);
  }

  static AccountId _fromBytes(Uint8List bytes) {
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return AccountId._(
      '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}'
      '-${hex.substring(16, 20)}-${hex.substring(20)}',
    );
  }

  static const length = 16;
  static final _uuid = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  );

  final String uuid;

  Uint8List get bytes {
    final hex = uuid.replaceAll('-', '');
    return Uint8List.fromList([
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ]);
  }

  @override
  bool operator ==(Object other) => other is AccountId && other.uuid == uuid;

  @override
  int get hashCode => uuid.hashCode;

  @override
  String toString() => uuid;
}

/// What the inviting owner posts: the workspace's [Invitation], sealed
/// under the invite code's key and found by the code's lookup.
///
/// Wire: `kind(1) | lookup(6) | salt(16) | sealedInvitation(blob)`.
@immutable
final class InviteOffer {
  const InviteOffer({
    required this.lookup,
    required this.salt,
    required this.sealedInvitation,
  });

  factory InviteOffer.parse(List<int> wire) {
    final reader = WireReader(wire);
    if (reader.uint8() != _kind) {
      throw const MalformedSyncDataException('not an invite offer');
    }
    final lookup = _readLookup(reader);
    final salt = Salt.fromBytes(reader.bytes(Salt.length));
    final sealed = _envelope(reader.blob(), Invitation.length);
    reader.finish();
    return InviteOffer(lookup: lookup, salt: salt, sealedInvitation: sealed);
  }

  static const _kind = 3;

  final String lookup;
  final Salt salt;
  final EncryptedEnvelope sealedInvitation;

  static AssociatedData associatedData(String lookup) =>
      AssociatedData.forContext('modusnote.invite.offer.v1', lookup);

  Uint8List toBytes() =>
      (WireWriter()
            ..uint8(_kind)
            ..bytes(Uint8List.fromList(lookup.codeUnits))
            ..bytes(salt.bytes)
            ..blob(sealedInvitation.toBytes()))
          .take();

  @override
  bool operator ==(Object other) =>
      other is InviteOffer &&
      other.lookup == lookup &&
      other.salt == salt &&
      other.sealedInvitation == sealedInvitation;

  @override
  int get hashCode => Object.hash(lookup, salt, sealedInvitation);
}

/// What the invited device posts back: its [PublicIdentity] and the account
/// it signs in with, sealed under the same key, so the owner admits only
/// the code's holder and lets in only the account that device named.
///
/// Wire: `kind(1) | lookup(6) | sealed(identity | account)(blob)`.
@immutable
final class InviteAnswer {
  const InviteAnswer({required this.lookup, required this.sealedJoiner});

  factory InviteAnswer.parse(List<int> wire) {
    final reader = WireReader(wire);
    if (reader.uint8() != _kind) {
      throw const MalformedSyncDataException('not an invite answer');
    }
    final lookup = _readLookup(reader);
    final sealed = _envelope(reader.blob(), joinerLength);
    reader.finish();
    return InviteAnswer(lookup: lookup, sealedJoiner: sealed);
  }

  static const _kind = 4;
  static const joinerLength = PublicIdentity.length + AccountId.length;

  final String lookup;
  final EncryptedEnvelope sealedJoiner;

  static AssociatedData associatedData(String lookup) =>
      AssociatedData.forContext('modusnote.invite.answer.v1', lookup);

  /// The plaintext an invited device seals.
  static Uint8List joiner(PublicIdentity identity, AccountId account) =>
      Uint8List.fromList([...identity.toBytes(), ...account.bytes]);

  /// Reads what [joiner] wrote.
  static (PublicIdentity, AccountId) readJoiner(Uint8List bytes) {
    if (bytes.length != joinerLength) {
      throw const MalformedSyncDataException('joiner of the wrong size');
    }
    return (
      PublicIdentity.parse(
        Uint8List.sublistView(bytes, 0, PublicIdentity.length),
      ),
      AccountId._fromBytes(Uint8List.sublistView(bytes, PublicIdentity.length)),
    );
  }

  Uint8List toBytes() =>
      (WireWriter()
            ..uint8(_kind)
            ..bytes(Uint8List.fromList(lookup.codeUnits))
            ..blob(sealedJoiner.toBytes()))
          .take();

  @override
  bool operator ==(Object other) =>
      other is InviteAnswer &&
      other.lookup == lookup &&
      other.sealedJoiner == sealedJoiner;

  @override
  int get hashCode => Object.hash(lookup, sealedJoiner);
}

String _readLookup(WireReader reader) {
  final lookup = String.fromCharCodes(reader.bytes(InviteCode.lookupLength));
  if (InviteCode.tryParse('${lookup}0000000000')?.lookup != lookup) {
    throw const MalformedSyncDataException('malformed invite lookup');
  }
  return lookup;
}
