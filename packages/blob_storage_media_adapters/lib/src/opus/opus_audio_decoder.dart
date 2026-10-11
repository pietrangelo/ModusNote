import 'dart:isolate';
import 'dart:typed_data';

import 'package:blob_storage_media/blob_storage_media.dart';

import '../ogg_opus_demuxer.dart';
import 'opus_stream_encoder.dart';

/// [AudioDecoder] for Ogg Opus on our own libopus, on every native
/// platform alike (iOS cannot be relied on to read Ogg Opus itself).
///
/// The container is checked and its length capped before any decoding;
/// libopus then runs on a background isolate so a long recording does
/// not freeze the interface.
final class OpusAudioDecoder implements AudioDecoder {
  const OpusAudioDecoder({this.demuxer = const OggOpusDemuxer()});

  final OggOpusDemuxer demuxer;

  @override
  bool canDecode(AudioFormat format) => format == AudioFormat.opusOgg;

  @override
  Future<DecodedAudio> decode(Stream<Uint8List> encoded) async {
    final recording = await demuxer.read(encoded);
    const rate = OpusStreamEncoder.sampleRate;
    if (recording.finalGranule - recording.preSkip >
        DecodedAudio.maxSamplesAt(rate)) {
      throw const RecordingTooLongException();
    }
    final samples = await Isolate.run(() => _decode(recording));
    return DecodedAudio(samples: samples, sampleRate: rate);
  }

  /// Decodes until the final granule is reached and keeps the samples
  /// between pre-skip and granule; what lies past it is encoder padding.
  static Int16List _decode(OggOpusRecording recording) {
    // The demuxer only lets a stream without packets end at granule 0.
    if (recording.packets.isEmpty) return Int16List(0);
    final wanted = recording.finalGranule;
    final decoded = Int16List(wanted);
    var filled = 0;
    final decoder = OpusPacketDecoder();
    try {
      for (final packet in recording.packets) {
        if (filled == wanted) break;
        final Int16List frame;
        try {
          frame = decoder.decode(packet);
        } on FormatException {
          throw const MalformedBlobException('not an Opus packet');
        }
        final take = frame.length < wanted - filled
            ? frame.length
            : wanted - filled;
        decoded.setRange(filled, filled + take, frame);
        filled += take;
      }
    } finally {
      decoder.dispose();
    }
    if (filled < wanted) {
      throw const MalformedBlobException(
        'Opus stream shorter than its granule',
      );
    }
    return Int16List.sublistView(decoded, recording.preSkip);
  }
}
