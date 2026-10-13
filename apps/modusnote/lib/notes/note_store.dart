import 'package:blob_storage_media/blob_storage_media.dart';
import 'package:flutter/foundation.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import '../audio/note_playback.dart';
import '../audio/note_recorder.dart';

/// Where the UI reads and writes notes. The screens see only decrypted
/// entries and the metadata of their recordings.
abstract interface class NoteStore implements Listenable {
  /// Notes outside the trash, most recently changed first.
  List<DynamicEntry> get entries;

  /// Notes in the trash, most recently trashed first. They keep their
  /// recordings until they are deleted for good.
  List<RecordedNote> get trash;

  KeyedRecording? recordingOf(BlobId id);

  /// Records takes for audio fields; null where there is nowhere to keep
  /// them (the web preview), which turns the record button off.
  NoteRecorder? get recorder;

  /// Opens recordings for listening; null where there is nothing to play
  /// them with, which hides the player.
  NotePlayback? get playback;

  /// Saves [entry] with the [takes] recorded while editing it. Takes it
  /// does not reference, and recordings it no longer references, are
  /// deleted.
  Future<void> save(
    DynamicEntry entry, {
    Iterable<KeyedRecording> takes = const [],
  });

  /// Deletes takes recorded in an edit that was abandoned.
  Future<void> discardTakes(Iterable<KeyedRecording> takes);

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
  List<RecordedNote> get trash => NoteOrder.trash(_notes.values);

  @override
  KeyedRecording? recordingOf(BlobId id) {
    for (final note in _notes.values) {
      if (note.recordings[id] case final take?) return take;
    }
    return null;
  }

  @override
  NoteRecorder? get recorder => null;

  @override
  NotePlayback? get playback => null;

  @override
  Future<void> save(
    DynamicEntry entry, {
    Iterable<KeyedRecording> takes = const [],
  }) async {
    _notes[entry.id] = switch (_notes[entry.id]) {
      null => RecordedNote.compose(entry, known: takes),
      final before => before.edited(entry, takes: takes).restored(),
    };
    notifyListeners();
  }

  @override
  Future<void> discardTakes(Iterable<KeyedRecording> takes) async {}

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

  /// Notes in the trash, most recently trashed first.
  static List<RecordedNote> trash(Iterable<RecordedNote> notes) => [
    for (final note in notes)
      if (note.isTrashed) note,
  ]..sort((a, b) => b.trashedAt!.compareTo(a.trashedAt!));
}
