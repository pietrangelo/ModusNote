import 'blob_exception.dart';

/// Container and codec of a recording, negotiated per platform: Opus where
/// the platform can encode it, AAC on browsers that cannot (Safari).
enum AudioFormat {
  opusOgg('opus_ogg', 'audio/ogg; codecs=opus'),
  opusWebm('opus_webm', 'audio/webm; codecs=opus'),
  aacMp4('aac_mp4', 'audio/mp4; codecs=mp4a.40.2'),
  pcm16Wav('pcm16_wav', 'audio/wav');

  const AudioFormat(this.wireName, this.mimeType);

  /// Stable name for persisted metadata; independent of enum order.
  final String wireName;
  final String mimeType;

  /// The longest take the app records in this format. Playback decodes at
  /// most thirty minutes (`DecodedAudio.maxDuration`), so a compressed
  /// take stops a minute short of it; uncompressed 48 kHz mono WAV grows
  /// by 96 kB a second and stops at about 83 MiB, under the server's
  /// largest blob (95 MiB).
  Duration get longestTake => switch (this) {
    pcm16Wav => const Duration(minutes: 15),
    _ => const Duration(minutes: 29),
  };

  static AudioFormat fromWireName(String wireName) {
    for (final format in values) {
      if (format.wireName == wireName) return format;
    }
    throw const InvalidBlobMetadataException('unknown audio format');
  }
}
