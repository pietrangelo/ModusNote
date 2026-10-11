import 'dart:async';
import 'dart:typed_data';

import 'package:blob_storage_media/blob_storage_media.dart';
import 'package:blob_storage_media_adapters/blob_storage_media_adapters.dart';
import 'package:file/memory.dart';
import 'package:identity_cryptography_adapters/identity_cryptography_adapters.dart';

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
