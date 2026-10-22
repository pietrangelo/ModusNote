import 'dart:convert';
import 'dart:typed_data';

import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:meta/meta.dart';

import 'sync_exception.dart';
import 'wire.dart';

/// What a device signs to call the sync server. The server admits a
/// request only if a member of the workspace's verified log signed exactly
/// this method, path, time, nonce and body, so there is no session or
/// password to steal, and a captured request cannot be replayed elsewhere
/// or with another body.
///
/// Wire: `label | method length | method | path length | path | millis |
/// nonce | body digest` (BLAKE2b-256 of the body, of nothing for a GET).
@immutable
final class SignedRequest {
  SignedRequest({
    required this.method,
    required this.path,
    required this.millis,
    required List<int> nonce,
    required this.body,
  }) : nonce = Uint8List.fromList(nonce) {
    if (!_method.hasMatch(method)) {
      throw const MalformedSyncDataException('bad request method');
    }
    if (!path.startsWith('/api/') ||
        path.length > maxPathLength ||
        !_path.hasMatch(path)) {
      throw const MalformedSyncDataException('bad request path');
    }
    if (millis < 0 || millis > _maxMillis) {
      throw const MalformedSyncDataException('bad request time');
    }
    if (this.nonce.length != nonceLength) {
      throw const MalformedSyncDataException('bad request nonce');
    }
  }

  static const label = 'modusnote.request.v1';
  static const nonceLength = 16;
  static const maxPathLength = 2048;
  static const _maxMillis = 0x1fffffffffffff;
  static final _method = RegExp(r'^[A-Z]{1,16}$');
  static final _path = RegExp(r'^[\x21-\x7e]+$');

  final String method;

  /// With the query, exactly as sent.
  final String path;

  /// Unix time in milliseconds by the device's clock, corrected by what the
  /// server last said its own was.
  final int millis;
  final Uint8List nonce;
  final ContentDigest body;

  Uint8List get signable {
    final writer = WireWriter()
      ..bytes(ascii.encode(label))
      ..uint8(method.length)
      ..bytes(ascii.encode(method))
      ..uint16(path.length)
      ..bytes(ascii.encode(path))
      ..int64(millis)
      ..bytes(nonce)
      ..bytes(body.bytes);
    return writer.take();
  }
}

/// The `Authorization` header of a [SignedRequest]: `MN1 key.millis.nonce.
/// signature`, the binary parts in base64url without padding.
@immutable
final class RequestCredential {
  RequestCredential({
    required this.key,
    required this.millis,
    required List<int> nonce,
    required this.signature,
  }) : nonce = Uint8List.fromList(nonce);

  /// Null for anything that is not exactly such a header.
  static RequestCredential? parse(String header) {
    if (!header.startsWith(_scheme)) return null;
    final parts = header.substring(_scheme.length).split('.');
    if (parts.length != 4 || !_millis.hasMatch(parts[1])) return null;
    final key = _decode(parts[0], PublicSigningKey.length);
    final millis = int.tryParse(parts[1]);
    final nonce = _decode(parts[2], SignedRequest.nonceLength);
    final signature = _decode(parts[3], Signature.length);
    if (key == null ||
        millis == null ||
        millis > SignedRequest._maxMillis ||
        nonce == null ||
        signature == null) {
      return null;
    }
    return RequestCredential(
      key: PublicSigningKey.fromBytes(key),
      millis: millis,
      nonce: nonce,
      signature: Signature.fromBytes(signature),
    );
  }

  static const _scheme = 'MN1 ';
  static final _millis = RegExp(r'^(0|[1-9][0-9]{0,15})$');
  static final _base64Url = RegExp(r'^[A-Za-z0-9_-]+$');

  final PublicSigningKey key;
  final int millis;
  final Uint8List nonce;
  final Signature signature;

  String get header =>
      '$_scheme${_encode(key.bytes)}.$millis.${_encode(nonce)}.'
      '${_encode(signature.bytes)}';

  static String _encode(List<int> bytes) =>
      base64Url.encode(bytes).replaceAll('=', '');

  /// Only the canonical encoding of exactly [length] bytes: no padding, no
  /// other alphabet, no stray bits in the last symbol.
  static Uint8List? _decode(String text, int length) {
    if (text.length != (length * 4 + 2) ~/ 3 || !_base64Url.hasMatch(text)) {
      return null;
    }
    final bytes = base64Url.decode(base64Url.normalize(text));
    return bytes.length == length && _encode(bytes) == text ? bytes : null;
  }

  @override
  bool operator ==(Object other) =>
      other is RequestCredential &&
      other.key == key &&
      other.millis == millis &&
      other.signature == signature &&
      _sameBytes(other.nonce, nonce);

  @override
  int get hashCode =>
      Object.hash(key, millis, signature, Object.hashAll(nonce));

  static bool _sameBytes(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
