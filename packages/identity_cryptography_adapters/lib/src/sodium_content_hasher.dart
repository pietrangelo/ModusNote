import 'dart:typed_data';

import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:sodium/sodium_sumo.dart';

/// [ContentHasher] on `crypto_generichash` (BLAKE2b, 32 bytes).
final class SodiumContentHasher implements ContentHasher {
  SodiumContentHasher(this._sodium);

  final Sodium _sodium;

  @override
  DigestSink start() => _Sink(
    _sodium.crypto.genericHash.createConsumer(outLen: ContentDigest.length),
  );
}

final class _Sink implements DigestSink {
  _Sink(this._consumer);

  final GenericHashConsumer _consumer;

  @override
  void add(Uint8List piece) => _consumer.add(piece);

  @override
  Future<ContentDigest> close() async =>
      ContentDigest.fromBytes(await _consumer.close());
}
