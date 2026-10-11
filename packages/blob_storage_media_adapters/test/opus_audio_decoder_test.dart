import 'dart:math';
import 'dart:typed_data';

import 'package:blob_storage_media/blob_storage_media.dart';
import 'package:blob_storage_media_adapters/blob_storage_media_adapters.dart';
import 'package:test/test.dart';

import 'ogg_opus_demuxer_test.dart' show mux, packet, pieces, resealed;
import 'opus_stream_encoder_test.dart' show correlation, sliced, tone;

Future<Uint8List> encoded(Uint8List pcm) async {
  final out = BytesBuilder();
  await for (final piece in OpusStreamEncoder().encode(sliced(pcm, 4096))) {
    out.add(piece);
  }
  return out.takeBytes();
}

Future<DecodedAudio> decode(Uint8List ogg, {int pieceSize = 1 << 16}) =>
    const OpusAudioDecoder().decode(pieces(ogg, pieceSize));

void main() {
  test('decodes Ogg Opus only', () {
    const decoder = OpusAudioDecoder();

    expect(decoder.canDecode(AudioFormat.opusOgg), isTrue);
    expect(decoder.canDecode(AudioFormat.pcm16Wav), isFalse);
    expect(decoder.canDecode(AudioFormat.aacMp4), isFalse);
  });

  test('gives back exactly the recorded samples, at 48 kHz', () async {
    final pcm = tone(1.234);

    final audio = await decode(await encoded(pcm), pieceSize: 333);

    expect(audio.sampleRate, 48000);
    expect(audio.samples, hasLength(pcm.length ~/ 2));
    expect(
      correlation(Int16List.sublistView(pcm), audio.samples),
      greaterThan(0.9),
    );
  });

  test('an empty take decodes to silence of no length', () async {
    final audio = await decode(await encoded(Uint8List(0)));

    expect(audio.samples, isEmpty);
    expect(audio.duration, Duration.zero);
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
        final ogg = await encoded(tone(0.1));
        final last = _lastPage(ogg);
        final view = ByteData.sublistView(ogg);
        view.setInt64(
          last + 6,
          view.getInt64(last + 6, Endian.little) + 48000,
          Endian.little,
        );
        await refuses(resealed(ogg, last), 'claims a second it does not hold');
      },
    );

    test('a granule claiming hours is refused before any decoding', () async {
      final ogg = mux([packet(10)], originalSamples: 0);
      final last = _lastPage(ogg);
      ByteData.sublistView(ogg).setInt64(
        last + 6,
        312 + DecodedAudio.maxSamplesAt(48000) + 1,
        Endian.little,
      );
      await expectLater(
        decode(resealed(ogg, last)),
        throwsA(isA<RecordingTooLongException>()),
      );
    });

    test('a corrupted container is a malformed blob, never a crash', () async {
      final ogg = await encoded(tone(0.3));
      final random = Random(7);
      for (var i = 0; i < 200; i++) {
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

int _lastPage(Uint8List stream) {
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
