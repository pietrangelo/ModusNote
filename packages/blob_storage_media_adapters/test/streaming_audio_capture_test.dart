import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:blob_storage_media/blob_storage_media.dart';
import 'package:blob_storage_media_adapters/blob_storage_media_adapters.dart';
import 'package:test/test.dart';

final class FakeMicrophone implements PcmMicrophone {
  FakeMicrophone({this.granted = true});

  final bool granted;
  final pcm = StreamController<Uint8List>();
  int? startedAt;
  int? startedChannels;
  var stopped = false;

  @override
  Future<bool> requestPermission() async => granted;

  @override
  Future<Stream<Uint8List>> start({
    required int sampleRate,
    required int channels,
  }) async {
    startedAt = sampleRate;
    startedChannels = channels;
    return pcm.stream;
  }

  @override
  Future<void> stop() async {
    stopped = true;
    // Like a real recorder: stopping does not wait for a consumer to drain.
    unawaited(pcm.close());
  }
}

Future<Uint8List> collect(Stream<List<int>> stream) async {
  final out = BytesBuilder();
  await for (final piece in stream) {
    out.add(piece);
  }
  return out.takeBytes();
}

void main() {
  group('StreamingAudioCapture', () {
    test(
      'starts the microphone at 48 kHz mono and reports the encoder format',
      () async {
        final mic = FakeMicrophone();
        final capture = StreamingAudioCapture(
          microphone: mic,
          encoder: const WavStreamEncoder(sampleRate: 48000),
        );
        final captured = await capture.start();

        expect(mic.startedAt, 48000);
        expect(mic.startedChannels, 1);
        expect(captured.format, AudioFormat.pcm16Wav);
        await capture.stop();
      },
    );

    test('delivers encoded bytes and closes after stop()', () async {
      final mic = FakeMicrophone();
      final capture = StreamingAudioCapture(
        microphone: mic,
        encoder: const WavStreamEncoder(sampleRate: 48000),
      );
      final captured = await capture.start();
      final bytes = collect(captured.bytes);
      mic.pcm
        ..add(Uint8List.fromList([1, 2, 3]))
        ..add(Uint8List.fromList([4]));
      await capture.stop();

      expect((await bytes).sublist(WavStreamEncoder.headerBytes), [1, 2, 3, 4]);
      expect(mic.stopped, isTrue);
    });

    test('a refused permission throws before the microphone starts', () async {
      final mic = FakeMicrophone(granted: false);
      final capture = StreamingAudioCapture(
        microphone: mic,
        encoder: const WavStreamEncoder(sampleRate: 48000),
      );

      await expectLater(
        capture.start(),
        throwsA(isA<MicrophonePermissionDeniedException>()),
      );
      expect(mic.startedAt, isNull);
    });
  });

  group('WavStreamEncoder', () {
    test('writes a 44-byte PCM16 mono header with unknown length', () async {
      final wav = await collect(
        const WavStreamEncoder(sampleRate: 16000).encode(const Stream.empty()),
      );
      final view = ByteData.sublistView(wav);

      expect(wav, hasLength(WavStreamEncoder.headerBytes));
      expect(ascii.decode(wav.sublist(0, 4)), 'RIFF');
      expect(ascii.decode(wav.sublist(8, 16)), 'WAVEfmt ');
      expect(view.getUint16(20, Endian.little), 1, reason: 'PCM');
      expect(view.getUint16(22, Endian.little), 1, reason: 'mono');
      expect(view.getUint32(24, Endian.little), 16000);
      expect(view.getUint32(28, Endian.little), 32000, reason: 'byte rate');
      expect(view.getUint16(32, Endian.little), 2, reason: 'block align');
      expect(view.getUint16(34, Endian.little), 16);
      expect(ascii.decode(wav.sublist(36, 40)), 'data');
      // Streaming: the length is not known when the header is written.
      expect(view.getUint32(40, Endian.little), 0xFFFFFFFF);
    });

    test('reports the PCM16 WAV format', () {
      expect(
        const WavStreamEncoder(sampleRate: 48000).format,
        AudioFormat.pcm16Wav,
      );
    });

    test(
      'passes samples through unchanged, including a split sample',
      () async {
        final wav = await collect(
          const WavStreamEncoder(sampleRate: 48000).encode(
            Stream.fromIterable([
              Uint8List.fromList([1]),
              Uint8List.fromList([2, 3, 4]),
            ]),
          ),
        );

        expect(wav.sublist(WavStreamEncoder.headerBytes), [1, 2, 3, 4]);
      },
    );
  });
}
