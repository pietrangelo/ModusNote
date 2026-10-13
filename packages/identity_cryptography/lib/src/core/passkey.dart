import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'cryptography_exception.dart';
import 'fixed_bytes.dart';

/// Public input to a passkey's PRF (the WebAuthn `prf` extension, CTAP2
/// `hmac-secret`): the same passkey and salt always give the same secret,
/// another salt an unrelated one. Stored in clear next to what it opens.
@immutable
final class PrfSalt {
  PrfSalt.fromBytes(List<int> bytes)
    : _bytes = copyExactly('PrfSalt', bytes, length);

  static const length = 32;

  final Uint8List _bytes;

  Uint8List get bytes => _bytes.asUnmodifiableView();

  @override
  bool operator ==(Object other) =>
      other is PrfSalt && bytesEqual(_bytes, other._bytes);

  @override
  int get hashCode => bytesHash(_bytes);
}

/// The authenticator's opaque id of one passkey (WebAuthn `rawId`), which
/// the browser needs to ask for that passkey and no other.
@immutable
final class PasskeyCredentialId {
  PasskeyCredentialId.fromBytes(List<int> bytes)
    : _bytes = Uint8List.fromList(bytes) {
    if (_bytes.length < minLength || _bytes.length > maxLength) {
      throw const InvalidPasskeyCredentialException();
    }
  }

  /// WebAuthn requires at least 16 bytes of entropy and at most 1023.
  static const minLength = 16;
  static const maxLength = 1023;

  final Uint8List _bytes;

  Uint8List get bytes => _bytes.asUnmodifiableView();

  @override
  bool operator ==(Object other) =>
      other is PasskeyCredentialId && bytesEqual(_bytes, other._bytes);

  @override
  int get hashCode => bytesHash(_bytes);
}
