import 'dart:typed_data';

import 'package:blob_storage_media/blob_storage_media.dart';
import 'package:glados/glados.dart';

DecodedAudio audio(List<int> samples, {int rate = 48000}) =>
    DecodedAudio(samples: Int16List.fromList(samples), sampleRate: rate);

void main() {
  group('DecodedAudio', () {
    test('its duration follows from samples and rate', () {
      expect(
        audio(List.filled(24000, 0)).duration,
        const Duration(milliseconds: 500),
      );
    });

    test('rejects a rate no recording uses', () {
      expect(
        () => audio([0], rate: 0),
        throwsA(isA<InvalidBlobMetadataException>()),
      );
      expect(
        () => audio([0], rate: 1000000),
        throwsA(isA<InvalidBlobMetadataException>()),
      );
    });

    test('is capped at the longest recording it will hold in memory', () {
      expect(DecodedAudio.maxSamplesAt(8000), 30 * 60 * 8000);
      expect(
        () => DecodedAudio(
          samples: Int16List(DecodedAudio.maxSamplesAt(8000) + 1),
          sampleRate: 8000,
        ),
        throwsA(isA<RecordingTooLongException>()),
      );
    });

    test('wraps as a canonical 16-bit mono WAV in memory', () {
      final wav = audio([1, -2, 32767]).toWav();
      final header = ByteData.sublistView(wav);

      expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
      expect(header.getUint32(4, Endian.little), 36 + 6);
      expect(String.fromCharCodes(wav.sublist(8, 16)), 'WAVEfmt ');
      expect(header.getUint16(20, Endian.little), 1, reason: 'PCM');
      expect(header.getUint16(22, Endian.little), 1, reason: 'mono');
      expect(header.getUint32(24, Endian.little), 48000);
      expect(header.getUint16(34, Endian.little), 16);
      expect(String.fromCharCodes(wav.sublist(36, 40)), 'data');
      expect(header.getUint32(40, Endian.little), 6);
      expect(Int16List.sublistView(wav, 44), [1, -2, 32767]);
    });
  });

  group('Waveform', () {
    test('one peak per bucket, scaled to 0..1', () {
      final waveform = Waveform.of(
        audio([0, 16384, 0, 0, -32768, 0, 8192, 0]),
        buckets: 4,
      );

      expect(waveform.peaks, [0.5, 0.0, 1.0, 0.25]);
    });

    test('silence is flat and nothing is shorter than its buckets', () {
      expect(Waveform.of(audio([]), buckets: 3).peaks, [0.0, 0.0, 0.0]);
      expect(Waveform.of(audio([32767]), buckets: 3).peaks, hasLength(3));
    });

    test('needs at least one bucket', () {
      expect(() => Waveform.of(audio([1]), buckets: 0), throwsArgumentError);
    });

    group('adversary', () {
      Glados2(
        any.list(any.intInRange(-32768, 32768)),
        any.intInRange(1, 200),
      ).test('peaks are always within 0..1, one per bucket', (samples, n) {
        final peaks = Waveform.of(audio(samples), buckets: n).peaks;

        expect(peaks, hasLength(n));
        expect(peaks.every((p) => p >= 0 && p <= 1), isTrue);
      });
    });
  });
}
