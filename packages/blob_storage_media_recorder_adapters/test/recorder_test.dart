import 'dart:async';
import 'dart:typed_data';

import 'package:blob_storage_media/blob_storage_media.dart';
import 'package:blob_storage_media_recorder_adapters/blob_storage_media_recorder_adapters.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:record_platform_interface/record_platform_interface.dart';

/// Stands in for the native `record` plugin; anything not overridden
/// throws, so the adapter cannot touch APIs the test does not expect
/// (file recording in particular).
final class FakeRecordPlatform extends Fake
    with MockPlatformInterfaceMixin
    implements RecordPlatform {
  FakeRecordPlatform({this.granted = true});

  final bool granted;
  final pcm = StreamController<Uint8List>();
  RecordConfig? config;
  var stopped = false;
  var disposed = false;

  @override
  Future<void> create(String recorderId) async {}

  @override
  Future<bool> hasPermission(String recorderId, {bool request = true}) async =>
      granted;

  @override
  Future<Stream<Uint8List>> startStream(
    String recorderId,
    RecordConfig config,
  ) async {
    this.config = config;
    return pcm.stream;
  }

  @override
  Future<String?> stop(String recorderId) async {
    stopped = true;
    unawaited(pcm.close());
    return null;
  }

  @override
  Future<void> dispose(String recorderId) async => disposed = true;

  @override
  Stream<RecordState> onStateChanged(String recorderId) => const Stream.empty();
}

void main() {
  late FakeRecordPlatform platform;

  setUp(() => RecordPlatform.instance = platform = FakeRecordPlatform());

  group('RecordPcmMicrophone', () {
    test('streams 16-bit PCM at the requested rate, never to a file', () async {
      final microphone = RecordPcmMicrophone();
      await microphone.start(sampleRate: 48000, channels: 1);

      expect(platform.config!.encoder, AudioEncoder.pcm16bits);
      expect(platform.config!.sampleRate, 48000);
      expect(platform.config!.numChannels, 1);
    });

    test('reports the permission the platform grants', () async {
      expect(await RecordPcmMicrophone().requestPermission(), isTrue);
      RecordPlatform.instance = FakeRecordPlatform(granted: false);
      expect(await RecordPcmMicrophone().requestPermission(), isFalse);
    });

    test('stop() stops and releases the recorder', () async {
      final microphone = RecordPcmMicrophone();
      await microphone.start(sampleRate: 48000, channels: 1);
      await microphone.stop();

      expect(platform.stopped, isTrue);
      expect(platform.disposed, isTrue);
    });
  });

  group('createPlatformAudioCapture', () {
    test('on native platforms records Ogg Opus from the microphone', () async {
      final capture = createPlatformAudioCapture();
      final captured = await capture.start();

      expect(captured.format, AudioFormat.opusOgg);
      expect(platform.config!.sampleRate, 48000);
      await capture.stop();
    });

    test('a refused microphone surfaces as the domain exception', () async {
      RecordPlatform.instance = FakeRecordPlatform(granted: false);

      await expectLater(
        createPlatformAudioCapture().start(),
        throwsA(isA<MicrophonePermissionDeniedException>()),
      );
    });
  });
}
