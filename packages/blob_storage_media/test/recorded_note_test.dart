import 'dart:typed_data';

import 'package:blob_storage_media/blob_storage_media.dart';
import 'package:collaboration_access_control/collaboration_access_control.dart';
import 'package:glados/glados.dart';
import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

final at = DateTime.utc(2026, 10, 11, 12);
final later = DateTime.utc(2026, 10, 11, 13);
final schema = SeedSchemas.songSketchV1;
final guideTrack = FieldKey('guide_track');

KeyedRecording take(String id, {int epoch = 0, int seconds = 3}) =>
    KeyedRecording(
      epoch: KeyEpoch(epoch),
      metadata: BlobMetadata(
        blob: SealedBlob(
          id: BlobId(id),
          keyId: SubkeyId.fromBytes(List.filled(SubkeyId.length, 5)),
          plaintextLength: 70000,
        ),
        format: AudioFormat.opusOgg,
        duration: Duration(seconds: seconds),
        recordedAt: at,
      ),
    );

T valid<T>(Validated<T> result) => switch (result) {
  Valid(:final value) => value,
  Invalid(:final violations) => throw StateError('$violations'),
};

DynamicEntry song() => valid(
  DynamicEntry.create(
    schema: schema,
    id: EntryId('0123456789abcdef0123456789abcdef'),
    attributes: {FieldKey('title'): const TextValue('Demo')},
    at: at,
  ),
);

SchemaDefinition? resolve(SchemaId id) => id == schema.id ? schema : null;

void main() {
  test('a note without recordings carries none', () {
    final note = RecordedNote.of(song());

    expect(note.recordings, isEmpty);
  });

  test('attaching a take sets the field and keeps its metadata', () {
    final note = valid(
      RecordedNote.of(song())
          .attach(take('take_1'), field: guideTrack, schema: schema, at: later),
    );

    expect(note.entry.valueOf(guideTrack), AudioBlobValue(BlobId('take_1')));
    expect(note.recordings, {BlobId('take_1'): take('take_1')});
  });

  test('replacing a take releases the old one for deletion', () {
    final first = valid(
      RecordedNote.of(song())
          .attach(take('take_1'), field: guideTrack, schema: schema, at: at),
    );

    final second = valid(
      first.attach(
        take('take_2'),
        field: guideTrack,
        schema: schema,
        at: later,
      ),
    );

    expect(second.recordings.keys, [BlobId('take_2')]);
    expect(RecordedNote.released(before: first, after: second), {
      BlobId('take_1'),
    });
  });

  test('an edit that clears the field drops the recording too', () {
    final recorded = valid(
      RecordedNote.of(song())
          .attach(take('take_1'), field: guideTrack, schema: schema, at: at),
    );
    final cleared = valid(
      recorded.entry.update(
        schema: schema,
        changes: {guideTrack: null},
        at: later,
      ),
    );

    expect(recorded.edited(cleared).recordings, isEmpty);
  });

  test('takes recorded during an edit join the note when referenced', () {
    final edited = valid(
      song().update(
        schema: schema,
        changes: {guideTrack: AudioBlobValue(BlobId('take_1'))},
        at: later,
      ),
    );

    final note = RecordedNote.of(song())
        .edited(edited, takes: [take('take_1'), take('unused')]);

    expect(note.recordings.keys, [BlobId('take_1')]);
  });

  test('an entry pointing at a blob with no known metadata is refused', () {
    final pointing = valid(
      song().update(
        schema: schema,
        changes: {guideTrack: AudioBlobValue(BlobId('ghost'))},
        at: later,
      ),
    );

    expect(() => RecordedNote.of(pointing), throwsArgumentError);
  });

  test('a recording cannot land in a field that is not audio', () {
    expect(
      RecordedNote.of(song()).attach(
        take('take_1'),
        field: FieldKey('title'),
        schema: schema,
        at: later,
      ),
      isA<Invalid<RecordedNote>>(),
    );
  });

  test('note, recordings and epochs round-trip through bytes', () {
    final note = valid(
      RecordedNote.of(song()).attach(
        take('take_1', epoch: 7, seconds: 42),
        field: guideTrack,
        schema: schema,
        at: later,
      ),
    );

    final back = valid(
      RecordedNoteCodec.decode(
        RecordedNoteCodec.encode(note),
        schemas: resolve,
      ),
    );

    expect(back.entry.attributes, note.entry.attributes);
    expect(back.entry.audit, note.entry.audit);
    expect(back.recordings, note.recordings);
  });

  group('adversary', () {
    Uint8List encoded() => RecordedNoteCodec.encode(
      valid(
        RecordedNote.of(
          song(),
        ).attach(take('take_1'), field: guideTrack, schema: schema, at: later),
      ),
    );

    test('every truncation and trailing byte is a format error', () {
      final wire = encoded();
      for (var length = 0; length < wire.length; length++) {
        expect(
          () => RecordedNoteCodec.decode(
            Uint8List.sublistView(wire, 0, length),
            schemas: resolve,
          ),
          throwsA(isA<MalformedBlobException>()),
          reason: '$length bytes',
        );
      }
      expect(
        () => RecordedNoteCodec.decode([...wire, 0], schemas: resolve),
        throwsA(isA<MalformedBlobException>()),
      );
    });

    test('metadata for a blob the note does not reference is refused', () {
      final note = RecordedNote.of(song());
      // A writer smuggling metadata for someone else's blob into a note
      // must not make the app treat that blob as belonging to it.
      final wire = RecordedNoteCodec.encodeUnchecked(note.entry, {
        BlobId('foreign'): take('foreign'),
      });

      expect(
        () => RecordedNoteCodec.decode(wire, schemas: resolve),
        throwsA(isA<MalformedBlobException>()),
      );
    });

    test('a referenced blob without metadata is refused', () {
      final recorded = valid(
        RecordedNote.of(
          song(),
        ).attach(take('take_1'), field: guideTrack, schema: schema, at: later),
      );
      final wire = RecordedNoteCodec.encodeUnchecked(recorded.entry, const {});

      expect(
        () => RecordedNoteCodec.decode(wire, schemas: resolve),
        throwsA(isA<MalformedBlobException>()),
      );
    });

    test('an unknown version is refused', () {
      final wire = encoded()..[0] = 9;

      expect(
        () => RecordedNoteCodec.decode(wire, schemas: resolve),
        throwsA(isA<MalformedBlobException>()),
      );
    });

    test('a broken entry inside is a format error, not a crash', () {
      final wire = RecordedNoteCodec.encodeUnchecked(song(), const {});
      wire[6] ^= 0xFF;

      expect(
        () => RecordedNoteCodec.decode(wire, schemas: resolve),
        throwsA(isA<MalformedBlobException>()),
      );
    });

    Glados(any.list(any.uint8))
        .test('random bytes never crash the decoder', (bytes) {
          try {
            RecordedNoteCodec.decode(bytes, schemas: resolve);
          } on MalformedBlobException {
            // The only acceptable failure.
          }
        });
  });
}
