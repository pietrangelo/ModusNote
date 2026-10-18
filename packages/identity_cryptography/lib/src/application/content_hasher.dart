import 'dart:typed_data';

import '../core/content_digest.dart';

/// Port: digests bytes that arrive in pieces (`crypto_generichash`).
abstract interface class ContentHasher {
  DigestSink start();
}

/// One digest in progress: [add] the pieces in order, then [close].
abstract interface class DigestSink {
  void add(Uint8List piece);

  Future<ContentDigest> close();
}
