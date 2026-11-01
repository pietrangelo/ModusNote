import 'dart:math';

import 'package:blob_storage_media/blob_storage_media.dart';
import 'package:flutter/foundation.dart';
import 'package:offline_sync/offline_sync.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import '../attachments/note_images.dart';
import '../audio/note_playback.dart';
import '../audio/note_recorder.dart';
import '../notes/note_store.dart';

/// [NoteStore] on the unlocked vault: each note is a [RecordedNoteCodec]
/// document (the entry plus the metadata of its recordings and pictures)
/// signed and sealed by the [SyncEngine], one record per note. Recordings
/// and pictures themselves are encrypted blobs beside it, deleted when no
/// note references them.
///
/// Categories are records of their own ([CategoryCodec], told apart by
/// their first byte), sealed the same way; which category a note is in
/// travels inside the note.
///
/// Decrypted notes live only in this object's memory while the vault is
/// open; the screens never see a record that fails to decode or validate.
final class VaultNoteStore extends ChangeNotifier implements NoteStore {
  VaultNoteStore._(
    this._engine,
    this._catalog,
    this.recorder,
    this.playback,
    this.images,
    this._clock,
    this._copyTitle,
  );

  static Future<VaultNoteStore> open(
    SyncEngine engine, {
    required SchemaCatalog catalog,
    NoteRecorder? recorder,
    NotePlayback? playback,
    NoteImages? images,
    DateTime Function() clock = DateTime.now,
    String Function(String title) copyTitle = _sameTitle,
  }) async {
    final store = VaultNoteStore._(
      engine,
      catalog,
      recorder,
      playback,
      images,
      clock,
      copyTitle,
    );
    await store._load();
    return store;
  }

  final SyncEngine _engine;
  final SchemaCatalog _catalog;
  final DateTime Function() _clock;

  /// The title of a conflict copy, from the note's own (maybe empty).
  final String Function(String title) _copyTitle;
  final _notes = <EntryId, RecordedNote>{};
  final _categories = <CategoryId, NoteCategory>{};
  CategoryTree? _tree;

  @override
  final NoteRecorder? recorder;

  @override
  final NotePlayback? playback;

  @override
  final NoteImages? images;
  var _unreadable = 0;

  /// Called after each saved change, once it is queued for the server.
  VoidCallback? onWrite;

  /// Called with the recordings and pictures a saved change stopped
  /// referencing (a note deleted for good, a take or picture removed), so
  /// the shared storage can let them go too.
  Future<void> Function(Set<BlobId> ids)? onRelease;

  /// Records that are not a valid note of a known schema: kept in the vault
  /// (a newer app may read them) but not shown. A note of an older version
  /// of its type is shown as the current version, and written as such only
  /// when it is next saved.
  int get unreadable => _unreadable;

  // Read many times per frame (once per link in the open note): kept until
  // the notes change.
  List<DynamicEntry>? _entries;
  Map<BlobId, KeyedImage>? _images;
  Map<BlobId, KeyedVideo>? _videos;

  void _notesChanged() {
    _entries = null;
    _images = null;
    _videos = null;
  }

  @override
  List<DynamicEntry> get entries =>
      _entries ??= List.unmodifiable(NoteOrder.library(_notes.values));

  @override
  DynamicEntry? entryOf(EntryId id) => NoteOrder.entryOf(_notes[id]);

  @override
  List<RecordedNote> get trash => NoteOrder.trash(_notes.values);

  /// Every blob the notes reference, recordings and pictures, in the
  /// trash or not.
  Iterable<KeyedBlob> get blobs => [
    for (final note in _notes.values) ...note.blobs,
  ];

  @override
  KeyedRecording? recordingOf(BlobId id) {
    for (final note in _notes.values) {
      if (note.recordings[id] case final take?) return take;
    }
    return null;
  }

  @override
  KeyedImage? imageOf(BlobId id) {
    if (_images == null) {
      final images = _images = {};
      for (final note in _notes.values) {
        for (final MapEntry(:key, :value) in note.images.entries) {
          images.putIfAbsent(key, () => value);
        }
      }
    }
    return _images![id];
  }

  @override
  KeyedVideo? videoOf(BlobId id) {
    if (_videos == null) {
      final videos = _videos = {};
      for (final note in _notes.values) {
        for (final MapEntry(:key, :value) in note.videos.entries) {
          videos.putIfAbsent(key, () => value);
        }
      }
    }
    return _videos![id];
  }

  @override
  CategoryTree get categories => _tree ??= CategoryTree(_categories.values);

  @override
  CategoryId? categoryOf(EntryId id) =>
      categories.resolve(_notes[id]?.category);

  @override
  Future<void> save(
    DynamicEntry entry, {
    Iterable<KeyedRecording> takes = const [],
    Iterable<KeyedImage> pictures = const [],
    Iterable<KeyedVideo> clips = const [],
    CategoryId? newIn,
  }) async {
    final before = _notes[entry.id];
    // Saving is keeping: an edit of a note another device has since put in
    // the trash brings it back.
    final after = before == null
        ? RecordedNote.compose(
            entry,
            known: takes,
            pictures: pictures,
            clips: clips,
            category: newIn,
          )
        : before
              .edited(entry, takes: takes, pictures: pictures, clips: clips)
              .restored();
    await _put(after);
    // Only once the note no longer points at them, and only what no note
    // points at: a picture pasted from one note's text into another's
    // belongs to both.
    final kept = {for (final blob in blobs) blob.id};
    final released = before == null
        ? const <BlobId>{}
        : RecordedNote.released(before: before, after: after).difference(kept);
    await _delete({
      ...released,
      for (final blob in [...takes, ...pictures, ...clips])
        if (!kept.contains(blob.id)) blob.id,
    });
    await _release(released);
  }

  @override
  Future<EntryId?> keepConflictCopy(EntryId id) async {
    final note = _notes[id];
    return note == null ? null : _keepCopy(note);
  }

  /// Keeps as notes of their own this device's edits that a concurrent
  /// edit from another device replaced, before the notes are read again:
  /// the copy references the same recordings and pictures, so none of
  /// them is deleted meanwhile. Returns how many copies were kept;
  /// categories and records this app cannot read keep none.
  Future<int> keepLost(Iterable<LostEdit> lost) async {
    var kept = 0;
    for (final edit in lost) {
      final note = _decode(edit.contents.bytes);
      if (note == null || note.entry.id.value != edit.record.hex) continue;
      if (note.isTrashed) continue;
      await _keepCopy(note);
      kept++;
    }
    return kept;
  }

  /// [note] under a new id, with a title that says it is a copy, filed
  /// where it was and referencing the same blobs.
  Future<EntryId> _keepCopy(RecordedNote note) async {
    final id = newNoteId(Random.secure());
    final schema = _catalog.schemaFor(note.entry.schemaId);
    final primary = schema?.primaryTextField;
    final attributes = {...note.entry.attributes};
    if (primary != null && primary.type is! MarkdownFieldType) {
      final title = switch (attributes[primary.key]) {
        TextValue(:final text) => text,
        _ => '',
      };
      attributes[primary.key] = TextValue(_copyTitle(title.trim()));
    }
    DynamicEntry copy(Map<FieldKey, FieldValue> values) =>
        switch (schema == null
        ? null
        : DynamicEntry.create(
            schema: schema,
            id: id,
            attributes: values,
            at: _clock().toUtc(),
          )) {
          Valid(:final value) => value,
          _ => throw StateError('a note that decoded cannot be copied'),
        };
    DynamicEntry entry;
    try {
      entry = copy(attributes);
    } on StateError {
      // A title too long for its field stays as it was.
      entry = copy(note.entry.attributes);
    }
    await _put(
      RecordedNote.compose(
        entry,
        known: note.recordings.values,
        pictures: note.images.values,
        clips: note.videos.values,
        category: note.category,
      ),
    );
    return id;
  }

  /// A note's id: 128 random bits as 32 hex digits, the shape of the
  /// record it is stored under.
  static EntryId newNoteId(Random random) => EntryId(
    List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join(),
  );

  static String _sameTitle(String title) => title;

  @override
  Future<void> discardTakes(Iterable<KeyedBlob> takes) =>
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
    _notesChanged();
    notifyListeners();
    onWrite?.call();
    final orphaned = _orphaned([note]);
    await _delete(orphaned);
    await _release(orphaned);
  }

  @override
  Future<void> emptyTrash() async {
    for (final note in trash) {
      await deleteForever(note.entry.id);
    }
  }

  @override
  Future<void> file(EntryId id, CategoryId? category) async {
    if (_notes[id] case final note? when note.category != category) {
      await _put(note.filedIn(category));
    }
  }

  @override
  Future<void> saveCategory(NoteCategory category) async {
    Filing.checkPlacement(categories, category);
    await _writeCategory(category);
  }

  Future<void> _writeCategory(NoteCategory category) async {
    await _engine.write(
      _recordOfCategory(category.id),
      RevisionContents(CategoryCodec.encode(category)),
    );
    _categories[category.id] = category;
    _tree = null;
    notifyListeners();
    onWrite?.call();
  }

  @override
  Future<void> deleteCategory(CategoryId id) async {
    final tree = categories;
    if (tree[id] == null) return;
    final up = tree.parentOf(id);
    // Everything moves out first, so an interrupted deletion leaves at
    // worst an empty category, never notes filed in a missing one.
    for (final child in Filing.inside(tree, _categories.values, id)) {
      await _writeCategory(child.movedTo(up));
    }
    for (final note in [..._notes.values]) {
      if (note.category == id) await _put(note.filedIn(up));
    }
    await _engine.write(_recordOfCategory(id), const RevisionDeleted());
    _categories.remove(id);
    _tree = null;
    notifyListeners();
    onWrite?.call();
  }

  Future<void> _put(RecordedNote note) async {
    await _engine.write(
      _recordOf(note.entry.id),
      RevisionContents(RecordedNoteCodec.encode(note)),
    );
    _notes[note.entry.id] = note;
    _notesChanged();
    notifyListeners();
    onWrite?.call();
  }

  /// Recordings and pictures of [gone] that no remaining note references.
  Set<BlobId> _orphaned(Iterable<RecordedNote> gone) {
    final kept = {for (final blob in blobs) blob.id};
    return {
      for (final note in gone)
        for (final blob in note.blobs)
          if (!kept.contains(blob.id)) blob.id,
    };
  }

  /// Takes never saved in a note were never uploaded: only what a saved
  /// note let go of is released.
  Future<void> _release(Set<BlobId> ids) async {
    if (ids.isEmpty) return;
    try {
      await onRelease?.call(ids);
    } on Object {
      // The note is saved either way; a blob left on the server is found
      // by the next sweep.
    }
  }

  Future<void> _delete(Set<BlobId> ids) async {
    // Recordings and pictures share one store.
    final blobs = recorder?.blobs ?? images?.blobs;
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
    _categories.clear();
    _tree = null;
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
      if (CategoryCodec.isCategory(contents.bytes)) {
        final category = _decodeCategory(contents.bytes);
        // As for notes: the id inside must name the record it is in.
        if (category == null || category.id.value != record.hex) {
          _unreadable++;
        } else {
          _categories[category.id] = category;
        }
        continue;
      }
      final note = _decode(contents.bytes);
      // The id inside the note must name the record it is stored in, so a
      // note's bytes copied onto another record cannot surface twice.
      if (note == null || note.entry.id.value != record.hex) {
        _unreadable++;
      } else {
        _notes[note.entry.id] = note;
      }
    }
    _notesChanged();
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

  static NoteCategory? _decodeCategory(List<int> bytes) {
    try {
      return CategoryCodec.decode(bytes);
    } on CategoryFormatException {
      return null;
    }
  }

  static RecordId _recordOfCategory(CategoryId id) {
    try {
      return RecordId.parse(id.value);
    } on MalformedSyncDataException {
      throw ArgumentError.value(id.value, 'id', 'not a record id');
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
