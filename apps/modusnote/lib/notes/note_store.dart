import 'package:blob_storage_media/blob_storage_media.dart';
import 'package:flutter/foundation.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import '../audio/note_playback.dart';
import '../audio/note_recorder.dart';

/// Where the UI reads and writes notes. The screens see only decrypted
/// entries and the metadata of their recordings.
abstract interface class NoteStore implements Listenable {
  /// Most recently changed first.
  List<DynamicEntry> get entries;

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
}

/// Notes kept in memory only: the web preview until its vault exists.
final class InMemoryNoteStore extends ChangeNotifier implements NoteStore {
  final _notes = <EntryId, RecordedNote>{};

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
      final before => before.edited(entry, takes: takes),
    };
    notifyListeners();
  }

  @override
  Future<void> discardTakes(Iterable<KeyedRecording> takes) async {}
}
