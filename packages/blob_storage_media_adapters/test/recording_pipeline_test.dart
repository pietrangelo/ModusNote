import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:blob_storage_media/blob_storage_media.dart';
import 'package:blob_storage_media_adapters/blob_storage_media_adapters.dart';
import 'package:file/file.dart';
import 'package:file/memory.dart';
import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:identity_cryptography_adapters/identity_cryptography_adapters.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:test/test.dart';

import 'support/ogg_reader.dart';

final class FakeMicrophone implements PcmMicrophone {
  final pcm = StreamController<Uint8List>();

  @override
  Future<bool> requestPermission() async => true;

  @override
  Future<Stream<Uint8List>> start({
    required int sampleRate,
    required int channels,
  }) async => pcm.stream;

  @override
  Future<void> stop() async => unawaited(pcm.close());
}

/// Microphone → Opus → chunked encryption → file system, end to end.
void main() {
  late SodiumSumo sodium;
  late MemoryFileSystem fs;
  late EncryptedBlobStorage storage;
  late SymmetricKey contentKey;

  setUpAll(() async => sodium = await SodiumSumoInit.init());
  setUp(() {
    fs = MemoryFileSystem.test();
    storage = EncryptedBlobStorage(
      store: FileSystemCiphertextBlobStore(fs.directory('/cache/blobs')),
      encryptor: SodiumEnvelopeEncryptor(sodium),
      subkeys: SodiumSubkeyDerivationService(sodium),
    );
    contentKey = SodiumEnvelopeEncryptor(sodium).generateKey();
  });
  tearDown(() => contentKey.dispose());

  Uint8List speech(int samples) {
    final pcm = ByteData(samples * 2);
    for (var i = 0; i < samples; i++) {
      pcm.setInt16(i * 2, (9000 * sin(i / 7)).round(), Endian.little);
    }
    return pcm.buffer.asUint8List();
  }

  Uint8List everythingOnDisk() => Uint8List.fromList([
    for (final entity in fs.directory('/').listSync(recursive: true))
      if (entity is File) ...entity.readAsBytesSync(),
  ]);

  bool contains(Uint8List haystack, List<int> needle) {
    outer:
    for (var i = 0; i + needle.length <= haystack.length; i++) {
      for (var j = 0; j < needle.length; j++) {
        if (haystack[i + j] != needle[j]) continue outer;
      }
      return true;
    }
    return false;
  }

  test(
    'a take decrypts to a playable Ogg Opus file of the right length',
    () async {
      final microphone = FakeMicrophone();
      final session = AudioRecordingSession(
        capture: StreamingAudioCapture(
          microphone: microphone,
          encoder: OpusStreamEncoder(),
        ),
        storage: storage,
        clock: () => DateTime.utc(2026, 10, 11),
      );
      await session.start(id: BlobId('take-1'), contentKey: contentKey);
      final pcm = speech(48000 * 2);
      for (var offset = 0; offset < pcm.length; offset += 3000) {
        microphone.pcm.add(
          Uint8List.sublistView(pcm, offset, min(offset + 3000, pcm.length)),
        );
      }
      final metadata = await session.stop();

      final file = Uint8List.fromList([
        await for (final chunk in storage.read(
          metadata.blob,
          contentKey: contentKey,
        ))
          ...chunk,
      ]);
      final pages = parsePages(file);
      final preSkip = ByteData.sublistView(pages.first.packets.single)
          .getUint16(10, Endian.little);

      expect(metadata.format, AudioFormat.opusOgg);
      expect(pages.last.granule - preSkip, pcm.length ~/ 2);
    },
  );

  group('adversary', () {
    test('neither PCM nor the Ogg container ever reaches the disk', () async {
      final microphone = FakeMicrophone();
      final session = AudioRecordingSession(
        capture: StreamingAudioCapture(
          microphone: microphone,
          encoder: OpusStreamEncoder(),
        ),
        storage: storage,
        clock: () => DateTime.utc(2026, 10, 11),
      );
      await session.start(id: BlobId('take-2'), contentKey: contentKey);
      final pcm = speech(48000 * 3);
      final snapshots = <Uint8List>[];
      for (var offset = 0; offset < pcm.length; offset += 9600) {
        microphone.pcm.add(
          Uint8List.sublistView(pcm, offset, min(offset + 9600, pcm.length)),
        );
        await Future<void>.delayed(Duration.zero);
        snapshots.add(everythingOnDisk());
      }
      await session.stop();
      snapshots.add(everythingOnDisk());

      for (final disk in snapshots) {
        expect(contains(disk, ascii.encode('OggS')), isFalse);
        expect(contains(disk, ascii.encode('OpusHead')), isFalse);
        expect(contains(disk, pcm.sublist(20000, 20032)), isFalse);
      }
    });
  });
}
