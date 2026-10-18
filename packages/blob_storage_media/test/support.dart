import 'dart:async';
import 'dart:typed_data';

import 'package:blob_storage_media/blob_storage_media.dart';
import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:identity_cryptography_adapters/identity_cryptography_adapters.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';
import 'package:sodium/sodium_sumo.dart';

late SodiumSumo sodium;

Future<void> initSodium() async => sodium = await SodiumSumoInit.init();

EnvelopeEncryptor newEncryptor() => SodiumEnvelopeEncryptor(sodium);

SubkeyDerivationService newSubkeys() => SodiumSubkeyDerivationService(sodium);

/// Deterministic, recognisable plaintext: byte i is `i * 31 + 7`, so a
/// leak of any run of it into storage is easy to search for.
Uint8List audio(int length) =>
    Uint8List.fromList([for (var i = 0; i < length; i++) (i * 31 + 7) & 0xFF]);

/// Emits [bytes] in pieces of the given sizes (cycled), the way a recorder
/// delivers buffers of whatever size the platform likes.
Stream<List<int>> piecewise(Uint8List bytes, List<int> sizes) async* {
  var offset = 0;
  var i = 0;
  while (offset < bytes.length) {
    final size = sizes[i++ % sizes.length].clamp(1, bytes.length - offset);
    yield Uint8List.sublistView(bytes, offset, offset + size);
    offset += size;
  }
}

Future<Uint8List> collect(Stream<List<int>> stream) async {
  final builder = BytesBuilder(copy: false);
  await for (final piece in stream) {
    builder.add(piece);
  }
  return builder.takeBytes();
}

/// Test double for the persistence port: keeps committed ciphertext and
/// in-flight writes apart, so tests can prove nothing partial survives.
final class InMemoryBlobStore implements CiphertextBlobStore {
  final committed = <BlobId, Uint8List>{};
  final pending = <BlobId, BytesBuilder>{};

  /// Every byte any writer was ever handed, committed or not.
  final everWritten = BytesBuilder(copy: true);

  /// How many bytes [read] hands back at a time.
  int readPiece = 5000;

  @override
  Future<CiphertextBlobWriter> create(BlobId id) async {
    if (committed.containsKey(id) || pending.containsKey(id)) {
      throw BlobAlreadyExistsException(id);
    }
    pending[id] = BytesBuilder(copy: true);
    return _Writer(this, id);
  }

  @override
  Stream<Uint8List> read(BlobId id) async* {
    final bytes = committed[id];
    if (bytes == null) throw BlobNotFoundException(id);
    for (var offset = 0; offset < bytes.length; offset += readPiece) {
      final end = offset + readPiece < bytes.length
          ? offset + readPiece
          : bytes.length;
      yield Uint8List.sublistView(bytes, offset, end);
    }
  }

  @override
  Future<bool> contains(BlobId id) async => committed.containsKey(id);

  @override
  Future<void> delete(BlobId id) async => committed.remove(id);

  @override
  Future<void> discardIncomplete() async => pending.clear();
}

final class _Writer implements CiphertextBlobWriter {
  _Writer(this._store, this._id);

  final InMemoryBlobStore _store;
  final BlobId _id;

  @override
  Future<void> add(Uint8List ciphertext) async {
    _store.pending[_id]!.add(ciphertext);
    _store.everWritten.add(ciphertext);
  }

  @override
  Future<void> commit() async =>
      _store.committed[_id] = _store.pending.remove(_id)!.takeBytes();

  @override
  Future<void> abort() async => _store.pending.remove(_id);
}

/// True if any [window]-byte run of [needle] appears in [haystack].
bool leaks(Uint8List haystack, Uint8List needle, {int window = 16}) {
  if (needle.length < window) return false;
  final probe = needle.sublist(0, window);
  outer:
  for (var i = 0; i + window <= haystack.length; i++) {
    for (var j = 0; j < window; j++) {
      if (haystack[i + j] != probe[j]) continue outer;
    }
    return true;
  }
  return false;
}
