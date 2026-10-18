import 'dart:typed_data';

import 'package:blob_storage_media/blob_storage_media.dart';
import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';
import 'package:test/test.dart';

import 'support.dart';

/// Treats the blob as raw little-endian PCM16 at 48 kHz.
final class RawPcmDecoder implements AudioDecoder {
  var calls = 0;

  @override
  bool canDecode(AudioFormat format) => format == AudioFormat.pcm16Wav;

  @override
  Future<DecodedAudio> decode(Stream<Uint8List> encoded) async {
    calls++;
    final bytes = await collect(encoded);
    return DecodedAudio(
      samples: Int16List.fromList(Int16List.sublistView(bytes)),
      sampleRate: 48000,
    );
  }
}

void main() {
  setUpAll(initSodium);

  late InMemoryBlobStore store;
  late EncryptedBlobStorage storage;
  late SymmetricKey contentKey;
  late RawPcmDecoder decoder;
  late RecordingPlayback playback;

  setUp(() {
    store = InMemoryBlobStore();
    storage = EncryptedBlobStorage(
      store: store,
      encryptor: newEncryptor(),
      subkeys: newSubkeys(),
      hasher: newHasher(),
    );
    contentKey = newEncryptor().generateKey();
    addTearDown(contentKey.dispose);
    decoder = RawPcmDecoder();
    playback = RecordingPlayback(storage: storage, decoders: [decoder]);
  });

  Future<BlobMetadata> recorded(
    List<int> samples, {
    AudioFormat format = AudioFormat.pcm16Wav,
  }) async {
    final pcm = Int16List.fromList(samples).buffer.asUint8List();
    final blob = await storage.write(
      Stream.value(pcm),
      id: BlobId('take'),
      contentKey: contentKey,
    );
    return BlobMetadata(
      blob: blob,
      format: format,
      duration: Duration.zero,
      recordedAt: DateTime.utc(2026, 10, 11),
    );
  }

  test('a recording is decrypted and decoded into memory', () async {
    final metadata = await recorded([1, 2, -3]);

    final audio = await playback.open(metadata, contentKey: contentKey);

    expect(audio.samples, [1, 2, -3]);
    expect(audio.sampleRate, 48000);
  });

  test('a format no decoder handles is reported, not guessed', () async {
    final metadata = await recorded([1], format: AudioFormat.aacMp4);

    await expectLater(
      playback.open(metadata, contentKey: contentKey),
      throwsA(isA<UnsupportedAudioFormatException>()),
    );
    expect(decoder.calls, 0);
  });

  group('adversary', () {
    test('a tampered blob fails before any sample is played', () async {
      final metadata = await recorded(List.filled(100, 7));
      store.committed[metadata.id]![30] ^= 1;

      await expectLater(
        playback.open(metadata, contentKey: contentKey),
        throwsA(isA<AuthenticationTagMismatchException>()),
      );
    });

    test('a truncated blob is reported as incomplete', () async {
      final metadata = await recorded(List.filled(40000, 7));
      final full = store.committed[metadata.id]!;
      store.committed[metadata.id] = Uint8List.sublistView(
        full,
        0,
        full.length ~/ 2,
      );

      await expectLater(
        playback.open(metadata, contentKey: contentKey),
        throwsA(isA<BlobException>()),
      );
    });

    test('the wrong content key opens nothing', () async {
      final metadata = await recorded([1, 2]);
      final other = newEncryptor().generateKey();
      addTearDown(other.dispose);

      await expectLater(
        playback.open(metadata, contentKey: other),
        throwsA(isA<AuthenticationTagMismatchException>()),
      );
    });
  });
}
