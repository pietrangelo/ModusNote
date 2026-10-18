import 'dart:math';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'blob_exception.dart';

/// A recording decrypted and decoded to 16-bit mono PCM, held only in
/// memory while it plays: it is never written anywhere.
@immutable
final class DecodedAudio {
  DecodedAudio({required this.samples, required this.sampleRate}) {
    if (sampleRate < minSampleRate || sampleRate > maxSampleRate) {
      throw const InvalidBlobMetadataException('unsupported sample rate');
    }
    if (samples.length > maxSamplesAt(sampleRate)) {
      throw const RecordingTooLongException();
    }
  }

  static const minSampleRate = 8000;

  /// Every recorder of the app writes 48 kHz, and the memory budget below
  /// holds only up to it: a hostile 192 kHz take would be four times as
  /// large for the same thirty minutes.
  static const maxSampleRate = 48000;

  /// Playback decodes the whole recording into memory: thirty minutes at
  /// 48 kHz is about 170 MB of samples, and the cap also stops a few bytes
  /// of hostile container from claiming hours of audio.
  static const maxDuration = Duration(minutes: 30);

  /// The most samples a recording at [sampleRate] may decode to.
  static int maxSamplesAt(int sampleRate) => maxDuration.inSeconds * sampleRate;

  final Int16List samples;
  final int sampleRate;

  Duration get duration => Duration(
    microseconds: samples.length * Duration.microsecondsPerSecond ~/ sampleRate,
  );

  /// The samples behind a canonical 44-byte RIFF header, the one format
  /// every player loads from a memory buffer.
  Uint8List toWav() {
    final dataBytes = samples.length * 2;
    final wav = Uint8List(44 + dataBytes);
    final header = ByteData.sublistView(wav);
    void ascii(int offset, String text) => wav.setAll(offset, text.codeUnits);
    ascii(0, 'RIFF');
    header.setUint32(4, 36 + dataBytes, Endian.little);
    ascii(8, 'WAVEfmt ');
    header
      ..setUint32(16, 16, Endian.little)
      ..setUint16(20, 1, Endian.little)
      ..setUint16(22, 1, Endian.little)
      ..setUint32(24, sampleRate, Endian.little)
      ..setUint32(28, sampleRate * 2, Endian.little)
      ..setUint16(32, 2, Endian.little)
      ..setUint16(34, 16, Endian.little);
    ascii(36, 'data');
    header.setUint32(40, dataBytes, Endian.little);
    final body = ByteData.sublistView(wav, 44);
    for (var i = 0; i < samples.length; i++) {
      body.setInt16(i * 2, samples[i], Endian.little);
    }
    return wav;
  }
}

/// The outline of a recording: the loudest sample of each of [peaks]'
/// equal slices, from 0 (silence) to 1 (full scale).
@immutable
final class Waveform {
  Waveform._(List<double> peaks) : peaks = List.unmodifiable(peaks);

  factory Waveform.of(DecodedAudio audio, {required int buckets}) {
    if (buckets < 1) throw ArgumentError.value(buckets, 'buckets');
    final samples = audio.samples;
    return Waveform._([
      for (var bucket = 0; bucket < buckets; bucket++)
        _peak(
          samples,
          samples.length * bucket ~/ buckets,
          samples.length * (bucket + 1) ~/ buckets,
        ),
    ]);
  }

  final List<double> peaks;

  static double _peak(Int16List samples, int from, int to) {
    var loudest = 0;
    for (var i = from; i < to; i++) {
      loudest = max(loudest, samples[i].abs());
    }
    return loudest / 32768;
  }
}
