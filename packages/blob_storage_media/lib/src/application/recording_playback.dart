import 'dart:async';
import 'dart:typed_data';

import 'package:identity_cryptography/identity_cryptography.dart';

import '../core/audio_format.dart';
import '../core/blob_exception.dart';
import '../core/blob_metadata.dart';
import '../core/decoded_audio.dart';
import 'encrypted_blob_storage.dart';

/// Port: turns an encoded recording into PCM, in memory.
abstract interface class AudioDecoder {
  bool canDecode(AudioFormat format);

  /// Throws [MalformedBlobException] for a stream it cannot parse.
  Future<DecodedAudio> decode(Stream<Uint8List> encoded);
}

/// Use case: a recording from its encrypted blob to samples ready to play.
///
/// Decryption authenticates every chunk before the decoder sees it, so a
/// tampered or swapped blob fails here and is never played.
final class RecordingPlayback {
  RecordingPlayback({
    required this._storage,
    required List<AudioDecoder> decoders,
  }) : _decoders = List.unmodifiable(decoders);

  final EncryptedBlobStorage _storage;
  final List<AudioDecoder> _decoders;

  bool canPlay(AudioFormat format) => _decoders.any((d) => d.canDecode(format));

  /// [contentKey] is the GroupKey of the epoch the recording was sealed
  /// under; it stays owned by the caller.
  Future<DecodedAudio> open(
    BlobMetadata recording, {
    required SymmetricKey contentKey,
  }) {
    for (final decoder in _decoders) {
      if (decoder.canDecode(recording.format)) {
        return decoder.decode(
          _storage.read(recording.blob, contentKey: contentKey),
        );
      }
    }
    return Future.error(const UnsupportedAudioFormatException());
  }
}
