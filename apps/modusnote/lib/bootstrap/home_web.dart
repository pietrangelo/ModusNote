import 'package:flutter/widgets.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import '../notes/note_library.dart';
import '../notes/note_store.dart';

/// No vault in the browser yet: libsodium WASM, SQLite on OPFS and the
/// unlock flow arrive with the web client (Fase 7). Nothing is persisted.
Future<Widget> buildHome() async =>
    NoteLibraryScreen(schemas: SeedSchemas.all, store: InMemoryNoteStore());
