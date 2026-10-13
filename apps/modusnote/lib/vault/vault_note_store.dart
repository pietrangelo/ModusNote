import 'package:blob_storage_media/blob_storage_media.dart';
import 'package:flutter/foundation.dart';
import 'package:offline_sync/offline_sync.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import '../audio/note_playback.dart';
import '../audio/note_recorder.dart';
import '../notes/note_store.dart';

/// [NoteStore] on the unlocked vault: each note is a [RecordedNoteCodec]
/// document (the entry plus its recordings' metadata) signed and sealed by
/// the [SyncEngine], one record per note. Recordings themselves are
/// encrypted blobs beside it, deleted when no note references them.
///
/// Decrypted notes live only in this object's memory while the vault is
/// open; the screens never see a record that fails to decode or validate.
final class VaultNoteStore extends ChangeNotifier implements NoteStore {
  VaultNoteStore._(this._engine, this._catalog, this.recorder, this.playback);

  static Future<VaultNoteStore> open(
    SyncEngine engine, {
    required SchemaCatalog catalog,
    NoteRecorder? recorder,
    NotePlayback? playback,
  }) async {
    final store = VaultNoteStore._(engine, catalog, recorder, playback);
    await store._load();
    return store;
  }

  final SyncEngine _engine;
  final SchemaCatalog _catalog;
  final _notes = <EntryId, RecordedNote>{};

  @override
  final NoteRecorder? recorder;

  @override
  final NotePlayback? playback;
  var _unreadable = 0;

  /// Called after each saved edit, once it is queued for the server.
  VoidCallback? onWrite;

  /// Records that are not a valid note of a known schema: kept in the vault
  /// (a newer app may read them) but not shown. A note of an older version
  /// of its type is shown as the current version, and written as such only
  /// when it is next saved.
  int get unreadable => _unreadable;

  @override
  List<DynamicEntry> get entries =>
      [for (final note in _notes.values) note.entry]
        ..sort((a, b) => b.audit.updatedAt.compareTo(a.audit.updatedAt));

  @override
  KeyedRecording? recordingOf(BlobId id) {
    for (final note in _notes.values) {
      if (note.recordings[id] case final take?) return take;
    }
    return null;
  }

  @override
  Future<void> save(
    DynamicEntry entry, {
    Iterable<KeyedRecording> takes = const [],
  }) async {
    final record = _recordOf(entry.id);
    final before = _notes[entry.id];
    final after = before == null
        ? RecordedNote.compose(entry, known: takes)
        : before.edited(entry, takes: takes);
    await _engine.write(
      record,
      RevisionContents(RecordedNoteCodec.encode(after)),
    );
    _notes[entry.id] = after;
    notifyListeners();
    onWrite?.call();
    // Only once the note no longer points at them.
    await _delete({
      if (before != null)
        ...RecordedNote.released(before: before, after: after),
      for (final take in takes)
        if (!after.recordings.containsKey(take.id)) take.id,
    });
  }

  @override
  Future<void> discardTakes(Iterable<KeyedRecording> takes) =>
      _delete({for (final take in takes) take.id});

  Future<void> _delete(Set<BlobId> ids) async {
    final blobs = recorder?.blobs;
    if (blobs == null) return;
    for (final id in ids) {
      await blobs.delete(id);
    }
  }

  /// Reads every note again: a sync merged edits from the server.
  Future<void> reload() async {
    final records = await _engine.records();
    _notes.clear();
    _unreadable = 0;
    _take(records);
    notifyListeners();
  }

  Future<void> _load() async => _take(await _engine.records());

  void _take(Map<RecordId, RevisionContents> records) {
    for (final MapEntry(key: record, value: contents) in records.entries) {
      final note = _decode(contents.bytes);
      // The id inside the note must name the record it is stored in, so a
      // note's bytes copied onto another record cannot surface twice.
      if (note == null || note.entry.id.value != record.hex) {
        _unreadable++;
      } else {
        _notes[note.entry.id] = note;
      }
    }
  }

  RecordedNote? _decode(List<int> bytes) {
    try {
      final note = switch (RecordedNoteCodec.decode(
        bytes,
        schemas: _catalog.schemaFor,
      )) {
        Valid(:final value) => value,
        Invalid() => null,
      };
      if (note == null) return null;
      final current = _catalog.upgrade(note.entry);
      if (current == null) return null;
      return identical(current, note.entry) ? note : note.edited(current);
    } on MalformedBlobException {
      return null;
    }
  }

  static RecordId _recordOf(EntryId id) {
    try {
      return RecordId.parse(id.value);
    } on MalformedSyncDataException {
      throw ArgumentError.value(id.value, 'id', 'not a record id');
    }
  }
}
