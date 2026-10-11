import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:blob_storage_media/blob_storage_media.dart';
import 'package:blob_storage_media_adapters/blob_storage_media_adapters.dart';
import 'package:test/test.dart';

import 'support/ogg_reader.dart';

const rate = 48000;

/// [seconds] of a 440 Hz tone as 16-bit little-endian mono PCM.
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

Stream<Uint8List> sliced(Uint8List bytes, int size) async* {
  for (var offset = 0; offset < bytes.length; offset += size) {
    yield Uint8List.sublistView(
      bytes,
      offset,
      min(offset + size, bytes.length),
    );
  }
}

Future<Uint8List> encode(Stream<Uint8List> pcm) async {
  final out = BytesBuilder();
  await for (final piece in OpusStreamEncoder().encode(pcm)) {
    out.add(piece);
  }
  return out.takeBytes();
}

int preSkipOf(List<Page> pages) =>
    ByteData.sublistView(pages.first.packets.single)
        .getUint16(10, Endian.little);

/// Decodes every audio packet with libopus and drops the pre-skip, which
/// is exactly what a player does with the file.
Int16List decodeAll(List<Page> pages) {
  final decoder = OpusPacketDecoder();
  try {
    final decoded = <int>[
      for (final page in pages.skip(2))
        for (final packet in page.packets) ...decoder.decode(packet),
    ];
    final playable = pages.last.granule;
    return Int16List.fromList(decoded.sublist(preSkipOf(pages), playable));
  } finally {
    decoder.dispose();
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

void main() {
  test('produces Ogg Opus', () {
    expect(OpusStreamEncoder().format, AudioFormat.opusOgg);
  });

  test(
    'the stream is a valid Ogg Opus file with the encoder lookahead',
    () async {
      final pages = parsePages(await encode(sliced(tone(1), 4096)));

      expect(
        ascii.decode(pages.first.packets.single.sublist(0, 8)),
        'OpusHead',
      );
      expect(preSkipOf(pages), inInclusiveRange(1, 960));
      expect(pages.last.isLast, isTrue);
    },
  );

  test('the final granule covers exactly the recorded samples', () async {
    final pcm = tone(1.234);
    final pages = parsePages(await encode(sliced(pcm, 4096)));

    expect(pages.last.granule, preSkipOf(pages) + pcm.length ~/ 2);
  });

  test('decoding gives back the tone', () async {
    final pcm = tone(1);
    final decoded = decodeAll(parsePages(await encode(sliced(pcm, 4096))));
    final original = Int16List.sublistView(pcm);

    expect(decoded.length, original.length);
    expect(correlation(original, decoded), greaterThan(0.9));
  });

  test('buffers split mid-sample encode to the same audio', () async {
    final pcm = tone(0.5);
    final whole = parsePages(await encode(sliced(pcm, pcm.length)));
    final odd = parsePages(await encode(sliced(pcm, 777)));

    expect(odd.last.granule, whole.last.granule);
    expect(decodeAll(odd).length, decodeAll(whole).length);
  });

  test('compresses voice-band audio far below raw PCM', () async {
    final pcm = tone(5);
    final opus = await encode(sliced(pcm, 8192));

    expect(opus.length, lessThan(pcm.length ~/ 10));
  });

  test('an empty take is still a valid, empty Ogg Opus file', () async {
    final pages = parsePages(await encode(const Stream.empty()));

    expect(pages, hasLength(3));
    expect(pages.last.granule, 0);
  });

  group('adversary', () {
    test('a dangling half sample is dropped, not encoded as noise', () async {
      final pcm = Uint8List.fromList([...tone(0.1), 0x7F]);
      final pages = parsePages(await encode(sliced(pcm, 1000)));

      expect(pages.last.granule, preSkipOf(pages) + (pcm.length - 1) ~/ 2);
    });

    test('a failing microphone stream fails the encoding', () async {
      Stream<Uint8List> failing() async* {
        yield tone(0.1);
        throw StateError('microphone lost');
      }

      await expectLater(encode(failing()), throwsStateError);
    });

    test('garbage packets are rejected by the decoder, never crash it', () {
      final random = Random(42);
      final decoder = OpusPacketDecoder();
      addTearDown(decoder.dispose);
      for (var i = 0; i < 2000; i++) {
        final packet = Uint8List.fromList([
          for (var j = 0; j < random.nextInt(1300); j++) random.nextInt(256),
        ]);
        try {
          decoder.decode(packet);
        } on FormatException {
          // Rejected cleanly; some random bytes are valid Opus by chance.
        }
      }
      expect(
        () => decoder.decode(Uint8List(OggOpusMuxer.maxPacketBytes + 1)),
        throwsFormatException,
      );
    });

    test('a disposed decoder refuses further use', () {
      final decoder = OpusPacketDecoder()..dispose();

      expect(() => decoder.decode(Uint8List(3)), throwsStateError);
    });

    test('many encoders in a row do not exhaust native resources', () async {
      for (var i = 0; i < 200; i++) {
        await encode(sliced(tone(0.02), 4096));
      }
    });
  });
}
