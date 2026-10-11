import 'dart:typed_data';

import 'package:blob_storage_media/blob_storage_media.dart';
import 'package:blob_storage_media_adapters/blob_storage_media_adapters.dart';
import 'package:glados/glados.dart';

import 'ogg_opus_demuxer_test.dart' show pieces;

Uint8List pcmOf(List<int> samples) {
  final data = ByteData(samples.length * 2);
  for (var i = 0; i < samples.length; i++) {
    data.setInt16(i * 2, samples[i], Endian.little);
  }
  return data.buffer.asUint8List();
}

Future<Uint8List> recorded(Uint8List pcm, {int rate = 48000}) async {
  final out = BytesBuilder();
  await for (final piece in WavStreamEncoder(
    sampleRate: rate,
  ).encode(Stream.value(pcm))) {
    out.add(piece);
  }
  return out.takeBytes();
}

Future<DecodedAudio> decode(Uint8List wav, {int pieceSize = 1 << 16}) =>
    const WavAudioDecoder().decode(pieces(wav, pieceSize));

void main() {
  test('decodes 16-bit WAV only', () {
    const decoder = WavAudioDecoder();

    expect(decoder.canDecode(AudioFormat.pcm16Wav), isTrue);
    expect(decoder.canDecode(AudioFormat.opusOgg), isFalse);
  });

  test('reads what the web recorder writes, of unknown length', () async {
    final samples = [0, 1, -1, 32767, -32768, 1234];

    final audio = await decode(
      await recorded(pcmOf(samples), rate: 16000),
      pieceSize: 3,
    );

    expect(audio.sampleRate, 16000);
    expect(audio.samples, samples);
  });

  test('reads a canonical WAV with its real length', () async {
    final source = DecodedAudio(
      samples: Int16List.fromList([5, -5, 300]),
      sampleRate: 44100,
    );

    final audio = await decode(source.toWav());

    expect(audio.sampleRate, 44100);
    expect(audio.samples, source.samples);
  });

  group('adversary', () {
    Future<void> refuses(Uint8List wav, String reason) => expectLater(
      decode(wav),
      throwsA(isA<MalformedBlobException>()),
      reason: reason,
    );

    Uint8List canonical() => DecodedAudio(
      samples: Int16List.fromList([1, 2, 3, 4]),
      sampleRate: 48000,
    ).toWav();

    Uint8List edited(void Function(ByteData header) edit) {
      final wav = canonical();
      edit(ByteData.sublistView(wav));
      return wav;
    }

    test('a header that is not 16-bit mono PCM is refused', () async {
      await refuses(edited((h) => h.setUint8(0, 0x58)), 'RIFF');
      await refuses(edited((h) => h.setUint8(8, 0x58)), 'WAVE');
      await refuses(edited((h) => h.setUint32(16, 18, Endian.little)), 'fmt');
      await refuses(edited((h) => h.setUint16(20, 3, Endian.little)), 'float');
      await refuses(edited((h) => h.setUint16(22, 2, Endian.little)), 'stereo');
      await refuses(edited((h) => h.setUint32(24, 0, Endian.little)), 'rate');
      await refuses(
        edited((h) => h.setUint32(24, 1 << 31, Endian.little)),
        'huge rate',
      );
      await refuses(edited((h) => h.setUint32(28, 1, Endian.little)), 'bytes');
      await refuses(edited((h) => h.setUint16(32, 4, Endian.little)), 'align');
      await refuses(edited((h) => h.setUint16(34, 8, Endian.little)), 'bits');
      await refuses(edited((h) => h.setUint8(36, 0x58)), 'data');
    });

    test('lengths that disagree with the bytes are refused', () async {
      await refuses(
        edited((h) => h.setUint32(40, 6, Endian.little)),
        'data shorter than declared',
      );
      await refuses(
        edited((h) => h.setUint32(40, 10, Endian.little)),
        'data longer than declared',
      );
      await refuses(
        edited((h) => h.setUint32(4, 99, Endian.little)),
        'RIFF size',
      );
      await refuses(Uint8List.sublistView(canonical(), 0, 43), 'cut header');
      await refuses(Uint8List(0), 'empty');
    });

    test('a dangling half sample is dropped, not played as noise', () async {
      final audio = await decode(await recorded(Uint8List.fromList([1, 2, 3])));

      expect(audio.samples, [0x0201]);
      await refuses(
        edited((h) => h.setUint32(40, 7, Endian.little)),
        'declared odd length',
      );
    });

    test('a stream longer than playback holds is refused early', () async {
      Stream<Uint8List> endless() async* {
        yield (await recorded(Uint8List(0), rate: 8000));
        while (true) {
          yield Uint8List(1 << 20);
        }
      }

      await expectLater(
        const WavAudioDecoder().decode(endless()),
        throwsA(isA<RecordingTooLongException>()),
      );
    });

    Glados(any.list(any.uint8))
        .test('random bytes never crash it', (bytes) async {
          try {
            await decode(Uint8List.fromList(bytes));
          } on MalformedBlobException {
            // Refused.
          }
        });
  });
}
