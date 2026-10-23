import 'dart:math';
import 'dart:typed_data';

import 'package:identity_cryptography/identity_cryptography.dart';

import '../core/signed_request.dart';
import '../core/sync_exception.dart';
import 'ports.dart';

/// Use case: signs every request to the sync server as one device, with
/// its own identity: the server admits a request only if a member of the
/// workspace's verified log signed it, so there is no account, session or
/// token to steal.
///
/// The identity stays owned by whoever opened it (the vault, or a device
/// waiting to be admitted); once it is released, signing throws
/// [VaultLockedException].
final class RequestSigner {
  RequestSigner({
    required this._identities,
    required this._hasher,
    required this._device,
    required this._clock,
    required this._random,
  });

  final IdentityService _identities;
  final ContentHasher _hasher;
  final IdentityKeyPair _device;
  final Clock _clock;
  final Random _random;

  /// The server's clock minus this device's, as the server last told it.
  var _offset = Duration.zero;

  PublicSigningKey get key => _device.publicIdentity.signingKey;

  /// The `Authorization` header for [method] on [path] (with its query,
  /// exactly as sent) carrying [body].
  Future<String> authorize(String method, String path, Uint8List body) async {
    final sink = _hasher.start()..add(body);
    final digest = await sink.close();
    if (_device.isDisposed) throw const VaultLockedException();
    final request = SignedRequest(
      method: method,
      path: path,
      millis: _clock.now().add(_offset).millisecondsSinceEpoch,
      nonce: [
        for (var i = 0; i < SignedRequest.nonceLength; i++)
          _random.nextInt(256),
      ],
      body: digest,
    );
    final signature = _identities.sign(request.signable, signer: _device);
    return RequestCredential(
      key: key,
      millis: request.millis,
      nonce: request.nonce,
      signature: signature,
    ).header;
  }

  /// Takes the server's time, from a request it refused as too far from
  /// its own, so the next one is signed by the server's clock.
  void adjustClock(DateTime server) {
    _offset = server.difference(_clock.now());
  }
}
