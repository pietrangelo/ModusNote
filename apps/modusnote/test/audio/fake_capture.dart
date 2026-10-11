import 'dart:async';
import 'dart:typed_data';

import 'package:blob_storage_media/blob_storage_media.dart';
import 'package:blob_storage_media_adapters/blob_storage_media_adapters.dart';
import 'package:file/memory.dart';
import 'package:identity_cryptography_adapters/identity_cryptography_adapters.dart';
import 'package:modusnote/audio/note_playback.dart';

import '../vault/support.dart';

/// A microphone that "hears" [audio] as soon as it starts, then waits for
/// stop like a real one.
final class FakeCapture implements AudioCapture {
  FakeCapture(this.audio, {this.denied = false});

  final Uint8List audio;
  final bool denied;
  StreamController<Uint8List>? _bytes;

  @override
  Future<CapturedAudio> start() async {
    if (denied) throw const MicrophonePermissionDeniedException();
    final bytes = _bytes = StreamController<Uint8List>()..add(audio);
    return CapturedAudio(format: AudioFormat.opusOgg, bytes: bytes.stream);
  }

  @override
  Future<void> stop() async => _bytes?.close();
}

/// Recognisable plaintext, easy to search for in storage.
Uint8List voice([int length = 3000]) =>
    Uint8List.fromList([for (var i = 0; i < length; i++) 0x41 + i % 26]);

/// Encrypted blobs on an in-memory file system, as on a device.
({EncryptedBlobStorage blobs, MemoryFileSystem files}) memoryBlobs() {
  final files = MemoryFileSystem();
  return (
    blobs: EncryptedBlobStorage(
      store: FileSystemCiphertextBlobStore(files.directory('/blobs')),
      encryptor: SodiumEnvelopeEncryptor(sodium),
      subkeys: SodiumSubkeyDerivationService(sodium),
    ),
    files: files,
  );
}

/// Reads any "Opus" take as raw 16-bit samples at 8 kHz, and remembers
/// the plaintext it was handed.
final class FakeDecoder implements AudioDecoder {
  final heard = <List<int>>[];

  @override
  bool canDecode(AudioFormat format) => format == AudioFormat.opusOgg;

  @override
  Future<DecodedAudio> decode(Stream<Uint8List> encoded) async {
    final bytes = [await for (final chunk in encoded) ...chunk];
    heard.add(bytes);
    return DecodedAudio(
      samples: Int16List.fromList([
        for (var i = 0; i + 1 < bytes.length; i += 2)
          (bytes[i] | bytes[i + 1] << 8).toSigned(16),
      ]),
      sampleRate: 8000,
    );
  }
}

/// A player with a hand-driven clock.
final class FakePlayer implements RecordingPlayer {
  final loaded = <FakeSound>[];

  @override
  Future<LoadedSound> load(DecodedAudio audio) async {
    final sound = FakeSound(audio);
    loaded.add(sound);
    return sound;
  }
}

final class FakeSound implements LoadedSound {
  FakeSound(this.audio);

  final DecodedAudio audio;
  var disposed = false;

  @override
  Duration position = Duration.zero;

  @override
  bool playing = false;

  @override
  Duration get length => audio.duration;

  @override
  Future<void> play() async => playing = true;

  @override
  void pause() => playing = false;

  @override
  void seek(Duration position) => this.position = position;

  @override
  Future<void> dispose() async => disposed = true;
}
