/// Browser adapters for the Blob Storage & Media bounded context: blobs in
/// IndexedDB, Opus through WebCodecs. Web builds only (`dart:js_interop`).
library;

export 'src/web/indexed_db_ciphertext_blob_store.dart';
export 'src/web/webcodecs_opus.dart';
