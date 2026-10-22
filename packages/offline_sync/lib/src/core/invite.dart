import 'dart:math';
import 'dart:typed_data';

import 'package:collaboration_access_control/collaboration_access_control.dart';
import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:meta/meta.dart';

import 'sync_exception.dart';
import 'wire.dart';

/// The one-time code an owner shows to bring a device into the workspace,
/// another of their own (as an owner) or another person's (with the role
/// the owner chose): sixteen symbols of Crockford's base 32. The first six
/// are the offer's lookup, the only part the server learns; the other ten
/// (50 bits) it would have to guess, one Argon2id per guess, within the
/// code's lifetime, to pass off a device or a workspace of its own.
@immutable
final class InviteCode {
  const InviteCode._(this._symbols);

  factory InviteCode.random(Random random) => InviteCode._(
    String.fromCharCodes([
      for (var i = 0; i < length; i++)
        _alphabet.codeUnitAt(random.nextInt(_alphabet.length)),
    ]),
  );

  /// Reads a typed code: case, spaces and dashes are ignored, and the
  /// letters people confuse with digits (O, I, L) read as those digits.
  static InviteCode? tryParse(String input) {
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
    return code.length == length ? InviteCode._(code) : null;
  }

  static const length = 16;
  static const lookupLength = 6;
  static const _alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

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

/// What the invited device posts back: its [PublicIdentity], sealed under
/// the same key, so the owner admits only the code's holder.
///
/// Wire: `kind(1) | lookup(6) | sealed(identity)(blob)`.
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

  static const _kind = 5;
  static const joinerLength = PublicIdentity.length;

  final String lookup;
  final EncryptedEnvelope sealedJoiner;

  static AssociatedData associatedData(String lookup) =>
      AssociatedData.forContext('modusnote.invite.answer.v2', lookup);

  /// The plaintext an invited device seals.
  static Uint8List joiner(PublicIdentity identity) => identity.toBytes();

  /// Reads what [joiner] wrote.
  static PublicIdentity readJoiner(Uint8List bytes) {
    if (bytes.length != joinerLength) {
      throw const MalformedSyncDataException('joiner of the wrong size');
    }
    return PublicIdentity.parse(bytes);
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
