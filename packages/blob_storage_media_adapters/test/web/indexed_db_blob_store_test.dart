@TestOn('browser')
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:blob_storage_media/blob_storage_media.dart';
import 'package:blob_storage_media_adapters/web_media.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';
import 'package:test/test.dart';
import 'package:web/web.dart' as web;

Uint8List bytes(int length, [int seed = 7]) => Uint8List.fromList([
  for (var i = 0; i < length; i++) (i * 31 + seed) & 0xFF,
]);

Future<Uint8List> collect(Stream<List<int>> stream) async {
  final builder = BytesBuilder(copy: false);
  await for (final piece in stream) {
    builder.add(piece);
  }
  return builder.takeBytes();
}

void main() {
  var run = 0;
  late String name;
  late IndexedDbCiphertextBlobStore store;
  final id = BlobId('blob-1');

  setUp(() async {
    name = 'modusnote-blobs-test-${run++}';
    store = await IndexedDbCiphertextBlobStore.open(name: name);
  });
  tearDown(() async {
    store.close();
    await IndexedDbCiphertextBlobStore.deleteDatabase(name);
  });

  Future<void> put(BlobId blob, Uint8List content) async {
    final writer = await store.create(blob);
    await writer.add(Uint8List.sublistView(content, 0, content.length ~/ 2));
    await writer.add(Uint8List.sublistView(content, content.length ~/ 2));
    await writer.commit();
  }

  test('a committed blob reads back byte for byte', () async {
    final content = bytes(200000);
    await put(id, content);

    expect(await store.contains(id), isTrue);
    expect(await collect(store.read(id)), content);
  });

  test('a blob survives closing and reopening the database', () async {
    final content = bytes(70000, 3);
    await put(id, content);
    store.close();
    store = await IndexedDbCiphertextBlobStore.open(name: name);

    expect(await collect(store.read(id)), content);
  });

  test('a blob of many small pieces keeps their order', () async {
    final content = bytes(5000, 11);
    final writer = await store.create(id);
    for (var offset = 0; offset < content.length; offset += 7) {
      final end = offset + 7 < content.length ? offset + 7 : content.length;
      await writer.add(Uint8List.sublistView(content, offset, end));
    }
    await writer.commit();

    expect(await collect(store.read(id)), content);
  });

  test('a committed empty blob reads back empty', () async {
    await (await store.create(id)).commit();

    expect(await store.contains(id), isTrue);
    expect(await collect(store.read(id)), isEmpty);
  });

  test('an uncommitted write is invisible to readers', () async {
    final writer = await store.create(id);
    await writer.add(bytes(10));

    expect(await store.contains(id), isFalse);
    await expectLater(
      collect(store.read(id)),
      throwsA(isA<BlobNotFoundException>()),
    );
    await writer.abort();
  });

  test('abort removes everything written so far', () async {
    final writer = await store.create(id);
    await writer.add(bytes(1000));
    await writer.abort();

    expect(await store.storedChunkCount(), 0);
    expect(await store.contains(id), isFalse);
    // The id is free again.
    await put(id, bytes(4));
    expect(await collect(store.read(id)), bytes(4));
  });

  test('a blob id cannot be created twice, committed or in flight', () async {
    final writer = await store.create(id);
    await expectLater(
      store.create(id),
      throwsA(isA<BlobAlreadyExistsException>()),
    );
    await writer.commit();
    await expectLater(
      store.create(id),
      throwsA(isA<BlobAlreadyExistsException>()),
    );
  });

  test('delete removes the blob; deleting twice is harmless', () async {
    await put(id, bytes(10));
    await store.delete(id);
    await store.delete(id);

    expect(await store.contains(id), isFalse);
    expect(await store.storedChunkCount(), 0);
  });

  test('delete leaves other blobs alone', () async {
    await put(BlobId('a'), bytes(10, 1));
    await put(BlobId('a-b'), bytes(10, 2));
    await put(BlobId('b'), bytes(10, 3));
    await store.delete(BlobId('a'));

    expect(await collect(store.read(BlobId('a-b'))), bytes(10, 2));
    expect(await collect(store.read(BlobId('b'))), bytes(10, 3));
  });

  test(
    'discardIncomplete drops crashed writes and keeps committed ones',
    () async {
      await put(BlobId('kept'), bytes(10));
      // A write the tab never finished: closed mid-recording.
      await (await store.create(BlobId('crashed'))).add(bytes(10));
      store.close();
      store = await IndexedDbCiphertextBlobStore.open(name: name);
      await store.discardIncomplete();

      expect(await store.contains(BlobId('kept')), isTrue);
      expect(await store.contains(BlobId('crashed')), isFalse);
      expect(await store.storedChunkCount(), 2, reason: 'the two of kept');
      await put(BlobId('crashed'), bytes(3));
    },
  );

  test('reading a missing blob is BlobNotFound', () async {
    await expectLater(
      collect(store.read(BlobId('missing'))),
      throwsA(isA<BlobNotFoundException>()),
    );
  });

  group('adversary', () {
    /// Writes [state] for [blob] behind the store's back, as another
    /// script on the origin or a damaged profile could.
    Future<void> forgeState(String blob, JSAny state) async {
      store.close();
      final opened = Completer<web.IDBDatabase>();
      final request = web.window.indexedDB.open(name);
      request.onsuccess = ((web.Event _) => opened.complete(
        request.result! as web.IDBDatabase,
      )).toJS;
      final database = await opened.future;
      final transaction = database.transaction('blobs'.toJS, 'readwrite');
      final done = Completer<void>();
      transaction.oncomplete = ((web.Event _) => done.complete()).toJS;
      transaction.objectStore('blobs').put(state, blob.toJS);
      await done.future;
      database.close();
      store = await IndexedDbCiphertextBlobStore.open(name: name);
    }

    test('only the piece is stored, never the rest of its buffer', () async {
      // The ciphertext handed over is a view; the bytes around it in the
      // same buffer could be anything, plaintext included.
      final buffer = Uint8List(4096)..fillRange(0, 4096, 0x5A);
      final piece = Uint8List.sublistView(buffer, 1000, 1100)
        ..fillRange(0, 100, 0xC3);
      final writer = await store.create(id);
      await writer.add(piece);
      await writer.commit();
      store.close();

      final opened = Completer<web.IDBDatabase>();
      final request = web.window.indexedDB.open(name);
      request.onsuccess = ((web.Event _) => opened.complete(
        request.result! as web.IDBDatabase,
      )).toJS;
      final database = await opened.future;
      final read = database
          .transaction('chunks'.toJS)
          .objectStore('chunks')
          .get(['blob-1'.toJS, 0.toJS].toJS);
      final stored = Completer<JSUint8Array>();
      read.onsuccess = ((web.Event _) => stored.complete(
        read.result! as JSUint8Array,
      )).toJS;
      final value = await stored.future;
      database.close();
      store = await IndexedDbCiphertextBlobStore.open(name: name);

      expect(value.toDart, piece);
      expect(value.toDart.buffer.lengthInBytes, 100);
    });

    test('a state the store did not write is never served', () async {
      await put(id, bytes(10));
      await forgeState('blob-1', 'committed'.toJS);

      expect(await store.contains(id), isFalse);
      await expectLater(
        collect(store.read(id)),
        throwsA(isA<BlobNotFoundException>()),
      );
      await store.discardIncomplete();
      expect(await store.storedChunkCount(), 0);
    });

    test('a forged chunk count cannot read past the stored chunks', () async {
      await put(id, bytes(10));
      await forgeState('blob-1', 1000.toJS);

      expect(await collect(store.read(id)), bytes(10));
    });

    test('a writer cannot add after commit or abort', () async {
      final writer = await store.create(id);
      await writer.commit();
      await expectLater(writer.add(bytes(1)), throwsStateError);
      final other = await store.create(BlobId('other'));
      await other.abort();
      await expectLater(other.add(bytes(1)), throwsStateError);
    });

    test('abort after a commit does not delete the committed blob', () async {
      final writer = await store.create(id);
      await writer.add(bytes(5));
      await writer.commit();
      await writer.abort();

      expect(await collect(store.read(id)), bytes(5));
    });

    test('a blob deleted while being read ends early, not wrongly', () async {
      final writer = await store.create(id);
      for (var i = 0; i < 4; i++) {
        await writer.add(bytes(100, i));
      }
      await writer.commit();
      final pieces = <Uint8List>[];
      await for (final piece in store.read(id)) {
        pieces.add(piece);
        if (pieces.length == 1) await store.delete(id);
      }

      // Whatever came out is a prefix of the blob, never someone else's
      // bytes; the decrypting reader then reports truncation.
      expect(pieces.first, bytes(100, 0));
      expect(pieces.length, lessThan(4));
    });
  });
}
