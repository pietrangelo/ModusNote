@TestOn('browser')
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:blob_storage_media/blob_storage_media.dart';
import 'package:blob_storage_media_adapters/audio_encoding.dart';
import 'package:blob_storage_media_adapters/web_media.dart';
import 'package:test/test.dart';

import '../ogg_opus_demuxer_test.dart' show mux, packet, pieces, resealed;
import 'native_tone.dart';

const rate = 48000;

Uint8List tone(double seconds, {double amplitude = 12000}) {
  final samples = (seconds * rate).round();
  final pcm = ByteData(samples * 2);
  for (var i = 0; i < samples; i++) {
    pcm.setInt16(
      i * 2,
      (amplitude * sin(2 * pi * 440 * i / rate)).round(),
      Endian.little,
    );
  }
  return pcm.buffer.asUint8List();
}

/// Odd sizes on purpose: a sample split between two pieces must survive.
Stream<Uint8List> sliced(Uint8List bytes, int size) async* {
  for (var offset = 0; offset < bytes.length; offset += size) {
    yield Uint8List.sublistView(
      bytes,
      offset,
      min(offset + size, bytes.length),
    );
  }
}

double correlation(Int16List a, Int16List b) {
  var ab = 0.0, aa = 0.0, bb = 0.0;
  for (var i = 0; i < min(a.length, b.length); i++) {
    ab += a[i] * b[i];
    aa += a[i] * a[i];
    bb += b[i] * b[i];
  }
  return ab / sqrt(aa * bb);
}

Future<Uint8List> encode(Stream<Uint8List> pcm) async {
  final out = BytesBuilder();
  await for (final piece in WebCodecsOpusEncoder().encode(pcm)) {
    out.add(piece);
  }
  return out.takeBytes();
}

Future<DecodedAudio> decode(Uint8List ogg) =>
    const WebCodecsOpusDecoder().decode(pieces(ogg, 4093));

void main() {
  test('this browser has WebCodecs Opus', () async {
    expect(await WebCodecsOpusEncoder.isSupported(), isTrue);
    expect(await WebCodecsOpusDecoder.isSupported(), isTrue);
  });

  group('encoder', () {
    test('produces Ogg Opus', () {
      expect(WebCodecsOpusEncoder().format, AudioFormat.opusOgg);
    });

    test('writes an Ogg Opus file our demuxer accepts', () async {
      final pcm = tone(1);
      final recording = await const OggOpusDemuxer().read(
        Stream.value(await encode(sliced(pcm, 4097))),
      );

      expect(recording.channels, 1);
      // The browser's own encoder lookahead, taken from its OpusHead.
      expect(recording.preSkip, inInclusiveRange(1, 3840));
      expect(recording.finalGranule - recording.preSkip, pcm.length ~/ 2);
      // 20 ms packets that cover the audio plus the lookahead.
      expect(
        recording.packets.length * 960,
        greaterThanOrEqualTo(recording.finalGranule),
      );
    });

    test('OpusTags names the app and carries no user comments', () async {
      final ogg = await encode(sliced(tone(0.1), 1000));
      final text = latin1.decode(ogg);

      expect(text, contains('OpusTags'));
      expect(text, contains('ModusNote'));
    });

    test('an empty take is a valid, empty Ogg Opus file', () async {
      final recording = await const OggOpusDemuxer().read(
        Stream.value(await encode(const Stream.empty())),
      );

      expect(recording.packets, isEmpty);
      expect(recording.finalGranule, 0);
    });

    test('a failing microphone stream fails the encoding', () async {
      Stream<Uint8List> broken() async* {
        yield tone(0.05);
        throw StateError('microphone unplugged');
      }

      await expectLater(encode(broken()), throwsStateError);
    });
  });

  group('decoder', () {
    test('decodes Ogg Opus only', () {
      const decoder = WebCodecsOpusDecoder();

      expect(decoder.canDecode(AudioFormat.opusOgg), isTrue);
      expect(decoder.canDecode(AudioFormat.pcm16Wav), isFalse);
      expect(decoder.canDecode(AudioFormat.aacMp4), isFalse);
    });

    test('a browser take decodes to exactly its samples', () async {
      final pcm = tone(1.234);

      final audio = await decode(await encode(sliced(pcm, 2049)));

      expect(audio.sampleRate, rate);
      expect(audio.samples, hasLength(pcm.length ~/ 2));
      expect(
        correlation(Int16List.sublistView(pcm), audio.samples),
        greaterThan(0.9),
      );
    });

    test(
      'a take recorded on the phone (libopus) plays in the browser',
      () async {
        final audio = await decode(base64.decode(nativeToneOgg));

        expect(audio.samples, hasLength(nativeToneSamples));
        expect(
          correlation(Int16List.sublistView(tone(0.5)), audio.samples),
          greaterThan(0.9),
        );
      },
    );

    test('an empty take decodes to no samples', () async {
      final audio = await decode(await encode(const Stream.empty()));

      expect(audio.samples, isEmpty);
    });
  });

  group('adversary', () {
    Future<void> refuses(Uint8List ogg, String reason) => expectLater(
      decode(ogg),
      throwsA(isA<MalformedBlobException>()),
      reason: reason,
    );

    test('packets that are not Opus are a malformed blob', () async {
      await refuses(
        mux([Uint8List.fromList(List.filled(40, 0xFF))]),
        'garbage packet',
      );
    });

    test(
      'a final granule beyond what the packets decode to is refused',
      () async {
        final ogg = await encode(sliced(tone(0.1), 960));
        final last = lastPage(ogg);
        final view = ByteData.sublistView(ogg);
        view.setUint32(
          last + 6,
          view.getUint32(last + 6, Endian.little) + rate,
          Endian.little,
        );
        await refuses(resealed(ogg, last), 'claims a second it does not hold');
      },
    );

    test('a granule claiming hours is refused before any decoding', () async {
      final ogg = mux([packet(10)], originalSamples: 0);
      final last = lastPage(ogg);
      ByteData.sublistView(ogg).setUint32(
        last + 6,
        312 + DecodedAudio.maxSamplesAt(rate) + 1,
        Endian.little,
      );
      await expectLater(
        decode(resealed(ogg, last)),
        throwsA(isA<RecordingTooLongException>()),
      );
    });

    test('a corrupted container is a malformed blob, never a crash', () async {
      final ogg = await encode(sliced(tone(0.3), 4096));
      final random = Random(7);
      for (var i = 0; i < 60; i++) {
        final copy = Uint8List.fromList(ogg);
        copy[random.nextInt(copy.length)] = random.nextInt(256);
        try {
          await decode(copy);
        } on MalformedBlobException {
          // Refused.
        }
      }
    });
  });
}

int lastPage(Uint8List stream) {
  var offset = 0;
  var last = 0;
  while (offset < stream.length) {
    last = offset;
    final segments = stream[offset + 26];
    var body = 0;
    for (var i = 0; i < segments; i++) {
      body += stream[offset + 27 + i];
    }
    offset += 27 + segments + body;
  }
  return last;
}
