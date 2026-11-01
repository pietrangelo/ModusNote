import 'package:blob_storage_media/blob_storage_media.dart';
import 'package:flutter/foundation.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import '../attachments/note_images.dart';
import '../audio/note_playback.dart';
import '../audio/note_recorder.dart';

/// Where the UI reads and writes notes. The screens see only decrypted
/// entries and the metadata of their recordings and pictures.
abstract interface class NoteStore implements Listenable {
  /// Notes outside the trash, most recently changed first.
  List<DynamicEntry> get entries;

  /// The note [id] among [entries]: null for one in the trash or gone.
  DynamicEntry? entryOf(EntryId id);

  /// Notes in the trash, most recently trashed first. They keep their
  /// recordings until they are deleted for good.
  List<RecordedNote> get trash;

  KeyedRecording? recordingOf(BlobId id);

  KeyedImage? imageOf(BlobId id);

  /// The video of a recipe's step, from the note that holds it.
  KeyedVideo? videoOf(BlobId id);

  /// Records takes for audio fields; null where there is nowhere to keep
  /// them (the web preview), which turns the record button off.
  NoteRecorder? get recorder;

  /// Opens recordings for listening; null where there is nothing to play
  /// them with, which hides the player.
  NotePlayback? get playback;

  /// Adds pictures to notes and opens them; null where there is nowhere to
  /// keep them (the web preview), which turns the add button off.
  NoteImages? get images;

  /// Saves [entry] with the [takes] recorded and the [pictures] and
  /// [clips] (the videos of a recipe's steps) added while editing it. Those it does not reference, and recordings and
  /// pictures it no longer references, are deleted. A new note is filed
  /// in [newIn]; an existing one stays where it is.
  Future<void> save(
    DynamicEntry entry, {
    Iterable<KeyedRecording> takes = const [],
    Iterable<KeyedImage> pictures = const [],
    Iterable<KeyedVideo> clips = const [],
    CategoryId? newIn,
  });

  /// The categories notes are filed in, as a tree.
  CategoryTree get categories;

  /// The category note [id] shows in: null for none, or for one that is
  /// gone.
  CategoryId? categoryOf(EntryId id);

  /// Creates or changes a category, on every device of the workspace.
  /// Throws [ArgumentError] for a parent that would make a loop or a level
  /// past [CategoryTree.maxDepth].
  Future<void> saveCategory(NoteCategory category);

  /// Deletes a category. Nothing in it is lost: its notes and the
  /// categories inside it move up to its parent.
  Future<void> deleteCategory(CategoryId id);

  /// Files note [id] in [category] (null: in none), in the trash or not.
  Future<void> file(EntryId id, CategoryId? category);

  /// Deletes takes recorded, and pictures added, in an edit that was
  /// abandoned.
  Future<void> discardTakes(Iterable<KeyedBlob> takes);

  /// Keeps the note as it is stored now as a new note beside it, titled as
  /// a copy: what an edit about to replace it would otherwise lose. The
  /// copy's id, or null when there is no such note.
  Future<EntryId?> keepConflictCopy(EntryId id);

  /// Moves a note to the trash, on every device of the workspace.
  Future<void> moveToTrash(EntryId id);

  /// Takes a note back out of the trash.
  Future<void> restore(EntryId id);

  /// Deletes a note in the trash for good, with its recordings. Throws
  /// [StateError] for a note that is not in the trash.
  Future<void> deleteForever(EntryId id);

  /// Deletes every note in the trash for good.
  Future<void> emptyTrash();
}

/// Notes kept in memory only: the web preview until its vault exists.
final class InMemoryNoteStore extends ChangeNotifier implements NoteStore {
  InMemoryNoteStore({this.clock = DateTime.now});

  /// When notes go to the trash.
  final DateTime Function() clock;
  final _notes = <EntryId, RecordedNote>{};

  @override
  List<DynamicEntry> get entries => NoteOrder.library(_notes.values);

  @override
  DynamicEntry? entryOf(EntryId id) => NoteOrder.entryOf(_notes[id]);

  @override
  List<RecordedNote> get trash => NoteOrder.trash(_notes.values);

  @override
  KeyedRecording? recordingOf(BlobId id) {
    for (final note in _notes.values) {
      if (note.recordings[id] case final take?) return take;
    }
    return null;
  }

  @override
  KeyedImage? imageOf(BlobId id) {
    for (final note in _notes.values) {
      if (note.images[id] case final image?) return image;
    }
    return null;
  }

  @override
  KeyedVideo? videoOf(BlobId id) {
    for (final note in _notes.values) {
      if (note.videos[id] case final video?) return video;
    }
    return null;
  }

  @override
  NoteRecorder? get recorder => null;

  @override
  NotePlayback? get playback => null;

  @override
  NoteImages? get images => null;

  @override
  Future<void> save(
    DynamicEntry entry, {
    Iterable<KeyedRecording> takes = const [],
    Iterable<KeyedImage> pictures = const [],
    Iterable<KeyedVideo> clips = const [],
    CategoryId? newIn,
  }) async {
    _notes[entry.id] = switch (_notes[entry.id]) {
      null => RecordedNote.compose(
        entry,
        known: takes,
        pictures: pictures,
        clips: clips,
        category: newIn,
      ),
      final before =>
        before
            .edited(entry, takes: takes, pictures: pictures, clips: clips)
            .restored(),
    };
    notifyListeners();
  }

  final _categories = <CategoryId, NoteCategory>{};
  CategoryTree? _tree;

  @override
  CategoryTree get categories => _tree ??= CategoryTree(_categories.values);

  @override
  CategoryId? categoryOf(EntryId id) =>
      categories.resolve(_notes[id]?.category);

  @override
  Future<void> saveCategory(NoteCategory category) async {
    Filing.checkPlacement(categories, category);
    _categories[category.id] = category;
    _tree = null;
    notifyListeners();
  }

  @override
  Future<void> deleteCategory(CategoryId id) async {
    final tree = categories;
    final up = tree.parentOf(id);
    for (final child in Filing.inside(tree, _categories.values, id)) {
      _categories[child.id] = child.movedTo(up);
    }
    _notes.updateAll(
      (_, note) => note.category == id ? note.filedIn(up) : note,
    );
    _categories.remove(id);
    _tree = null;
    notifyListeners();
  }

  @override
  Future<void> file(EntryId id, CategoryId? category) async {
    if (_notes[id] case final note?) {
      _notes[id] = note.filedIn(category);
      notifyListeners();
    }
  }

  @override
  Future<void> discardTakes(Iterable<KeyedBlob> takes) async {}

  /// Copies made, by the id they copied.
  final copies = <EntryId, EntryId>{};

  @override
  Future<EntryId?> keepConflictCopy(EntryId id) async {
    final note = _notes[id];
    if (note == null) return null;
    final copy = EntryId(
      '${'c' * 16}${copies.length.toRadixString(16).padLeft(16, '0')}',
    );
    _notes[copy] = RecordedNote.compose(
      switch (DynamicEntry.create(
        schema: SeedSchemas.catalog.schemaFor(note.entry.schemaId)!,
        id: copy,
        attributes: note.entry.attributes,
        at: clock(),
      )) {
        Valid(:final value) => value,
        Invalid(:final violations) => throw StateError('$violations'),
      },
      known: note.recordings.values,
      pictures: note.images.values,
      clips: note.videos.values,
      category: note.category,
    );
    copies[id] = copy;
    notifyListeners();
    return copy;
  }

  @override
  Future<void> moveToTrash(EntryId id) async {
    if (_notes[id] case final note?) {
      _notes[id] = note.trashed(at: clock());
      notifyListeners();
    }
  }

  @override
  Future<void> restore(EntryId id) async {
    if (_notes[id] case final note?) {
      _notes[id] = note.restored();
      notifyListeners();
    }
  }

  @override
  Future<void> deleteForever(EntryId id) async {
    if (_notes[id]?.isTrashed != true) {
      throw StateError('only a note in the trash can be deleted for good');
    }
    _notes.remove(id);
    notifyListeners();
  }

  @override
  Future<void> emptyTrash() async {
    _notes.removeWhere((_, note) => note.isTrashed);
    notifyListeners();
  }
}

/// How the screens list notes.
abstract final class NoteOrder {
  /// Notes outside the trash, most recently changed first.
  static List<DynamicEntry> library(Iterable<RecordedNote> notes) => [
    for (final note in notes)
      if (!note.isTrashed) note.entry,
  ]..sort((a, b) => b.audit.updatedAt.compareTo(a.audit.updatedAt));

  /// The entry of [note] when it is in the library.
  static DynamicEntry? entryOf(RecordedNote? note) =>
      note == null || note.isTrashed ? null : note.entry;

  /// Notes in the trash, most recently trashed first.
  static List<RecordedNote> trash(Iterable<RecordedNote> notes) => [
    for (final note in notes)
      if (note.isTrashed) note,
  ]..sort((a, b) => b.trashedAt!.compareTo(a.trashedAt!));
}

/// Rules both stores apply when categories change.
abstract final class Filing {
  /// Throws [ArgumentError] when [category] cannot go where it says: a
  /// parent that is missing, inside itself, or a level too deep. A
  /// category that stays where it is always can, even in a tree another
  /// device made too deep.
  static void checkPlacement(CategoryTree tree, NoteCategory category) {
    final existing = tree[category.id];
    if (existing != null && existing.parent == category.parent) return;
    if (!tree.canPlace(
      category.parent,
      moving: existing == null ? null : category.id,
    )) {
      throw ArgumentError.value(
        category.parent?.value,
        'parent',
        'a loop or a level too deep',
      );
    }
  }

  /// The categories to move up when [id] is deleted: those the tree shows
  /// inside it, and those whose record names it.
  static List<NoteCategory> inside(
    CategoryTree tree,
    Iterable<NoteCategory> all,
    CategoryId id,
  ) => [
    for (final category in all)
      if (category.id != id &&
          (category.parent == id || tree.parentOf(category.id) == id))
        category,
  ];
}
