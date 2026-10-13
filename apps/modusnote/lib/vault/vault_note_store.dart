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
  VaultNoteStore._(
    this._engine,
    this._catalog,
    this.recorder,
    this.playback,
    this._clock,
  );

  static Future<VaultNoteStore> open(
    SyncEngine engine, {
    required SchemaCatalog catalog,
    NoteRecorder? recorder,
    NotePlayback? playback,
    DateTime Function() clock = DateTime.now,
  }) async {
    final store = VaultNoteStore._(engine, catalog, recorder, playback, clock);
    await store._load();
    return store;
  }

  final SyncEngine _engine;
  final SchemaCatalog _catalog;
  final DateTime Function() _clock;
  final _notes = <EntryId, RecordedNote>{};

  @override
  final NoteRecorder? recorder;

  @override
  final NotePlayback? playback;
  var _unreadable = 0;

  /// Called after each saved change, once it is queued for the server.
  VoidCallback? onWrite;

  /// Records that are not a valid note of a known schema: kept in the vault
  /// (a newer app may read them) but not shown. A note of an older version
  /// of its type is shown as the current version, and written as such only
  /// when it is next saved.
  int get unreadable => _unreadable;

  @override
  List<DynamicEntry> get entries => NoteOrder.library(_notes.values);

  @override
  List<RecordedNote> get trash => NoteOrder.trash(_notes.values);

  /// Every recording the notes reference, in the trash or not.
  Iterable<KeyedRecording> get recordings => [
    for (final note in _notes.values) ...note.recordings.values,
  ];

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
    final before = _notes[entry.id];
    // Saving is keeping: an edit of a note another device has since put in
    // the trash brings it back.
    final after = before == null
        ? RecordedNote.compose(entry, known: takes)
        : before.edited(entry, takes: takes).restored();
    await _put(after);
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

  @override
  Future<void> moveToTrash(EntryId id) async {
    if (_notes[id] case final note? when !note.isTrashed) {
      await _put(note.trashed(at: _clock()));
    }
  }

  @override
  Future<void> restore(EntryId id) async {
    if (_notes[id] case final note? when note.isTrashed) {
      await _put(note.restored());
    }
  }

  @override
  Future<void> deleteForever(EntryId id) async {
    final note = _notes[id];
    if (note == null || !note.isTrashed) {
      throw StateError('only a note in the trash can be deleted for good');
    }
    // A deletion is a signed revision like an edit: it reaches the other
    // devices sealed, and no stale copy of the note can bring it back.
    await _engine.write(_recordOf(id), const RevisionDeleted());
    _notes.remove(id);
    notifyListeners();
    onWrite?.call();
    await _delete(_orphaned([note]));
  }

  @override
  Future<void> emptyTrash() async {
    for (final note in trash) {
      await deleteForever(note.entry.id);
    }
  }

  Future<void> _put(RecordedNote note) async {
    await _engine.write(
      _recordOf(note.entry.id),
      RevisionContents(RecordedNoteCodec.encode(note)),
    );
    _notes[note.entry.id] = note;
    notifyListeners();
    onWrite?.call();
  }

  /// Recordings of [gone] that no remaining note references.
  Set<BlobId> _orphaned(Iterable<RecordedNote> gone) {
    final kept = {for (final take in recordings) take.id};
    return {
      for (final note in gone)
        for (final id in note.recordings.keys)
          if (!kept.contains(id)) id,
    };
  }

  Future<void> _delete(Set<BlobId> ids) async {
    final blobs = recorder?.blobs;
    if (blobs == null) return;
    for (final id in ids) {
      await blobs.delete(id);
    }
  }

  /// Reads every note again: a sync merged edits from the server. The
  /// recordings of notes another device deleted for good are deleted here
  /// too; a note that merely stopped decoding (a newer app may have
  /// rewritten it) keeps them.
  Future<void> reload() async {
    final records = await _engine.records();
    final before = Map.of(_notes);
    _notes.clear();
    _unreadable = 0;
    _take(records);
    notifyListeners();
    final deleted = [
      for (final MapEntry(key: id, value: note) in before.entries)
        if (!_notes.containsKey(id) &&
            await _engine.read(_recordOf(id)) is RevisionDeleted)
          note,
    ];
    await _delete(_orphaned(deleted));
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
