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

KeyedRecording take(
  String id, {
  int epoch = 0,
  int seconds = 3,
  ContentDigest? digest,
}) => KeyedRecording(
  epoch: KeyEpoch(epoch),
  metadata: BlobMetadata(
    blob: SealedBlob(
      id: BlobId(id),
      keyId: SubkeyId.fromBytes(List.filled(SubkeyId.length, 5)),
      plaintextLength: 70000,
      digest: digest,
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

  group('digest', () {
    final digest = ContentDigest.fromBytes(List.filled(32, 0xab));
    RecordedNote recorded(KeyedRecording recording) => valid(
      RecordedNote.of(song())
          .attach(recording, field: guideTrack, schema: schema, at: later),
    );

    test('a recording with a digest round-trips as version 5', () {
      final note = recorded(take('take_1', digest: digest));

      final wire = RecordedNoteCodec.encode(note);
      final back = valid(RecordedNoteCodec.decode(wire, schemas: resolve));

      expect(wire[0], 5);
      expect(back.recordings, note.recordings);
      expect(back.recordings.values.single.blob.digest, digest);
    });

    test('without digests a note keeps its older version', () {
      expect(RecordedNoteCodec.encode(recorded(take('take_1')))[0], 1);
    });

    test(
      'adversary: every truncation, odd flag and digest-less 5 is refused',
      () {
        final wire = RecordedNoteCodec.encode(
          recorded(take('take_1', digest: digest)),
        );
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
        // ... flags | has (1) | digest (32)
        final has = wire.length - 33;
        for (final forged in [
          Uint8List.fromList(wire)..[has] = 2,
          Uint8List.fromList(wire)..[has - 1] = 0,
          // version 5 with every digest absent: should have been version 1.
          Uint8List.fromList([...wire.sublist(0, has), 0]),
        ]) {
          expect(
            () => RecordedNoteCodec.decode(forged, schemas: resolve),
            throwsA(isA<MalformedBlobException>()),
          );
        }
      },
    );
  });

  group('videos', () {
    final recipe = SeedSchemas.recipeV1;
    SchemaDefinition? recipes(SchemaId id) => id == recipe.id ? recipe : null;
    final digest = ContentDigest.fromBytes(List.filled(32, 0xcd));
    KeyedVideo clip(String id, {ContentDigest? digest}) => KeyedVideo(
      epoch: KeyEpoch(2),
      metadata: VideoMetadata(
        blob: SealedBlob(
          id: BlobId(id),
          keyId: SubkeyId.fromBytes(List.filled(SubkeyId.length, 7)),
          plaintextLength: 900000,
          digest: digest,
        ),
        info: VideoHeader(
          VideoFormat.mp4,
          1080,
          1920,
          const Duration(seconds: 42, milliseconds: 500),
        ),
        addedAt: later,
      ),
    );
    DynamicEntry dish(List<String> videos) => valid(
      DynamicEntry.create(
        schema: recipe,
        id: EntryId('fedcba9876543210fedcba9876543210'),
        attributes: {
          FieldKey('title'): const TextValue('Pane'),
          FieldKey('steps'): StepsValue([
            for (final id in videos)
              PreparationStep('Impasta', video: BlobId(id)),
            PreparationStep('Inforna'),
          ]),
        },
        at: at,
      ),
    );

    test('a step\'s video travels with the note, as version 6', () {
      final note = RecordedNote.compose(
        dish(['clip_1']),
        clips: [clip('clip_1', digest: digest)],
      );
      expect(note.videos.keys, [BlobId('clip_1')]);
      expect(note.blobs.map((b) => b.id), [BlobId('clip_1')]);

      final wire = RecordedNoteCodec.encode(note);
      expect(wire[0], 6);
      final back = valid(RecordedNoteCodec.decode(wire, schemas: recipes));
      expect(back.videos, note.videos);
      expect(back.videos.values.single.blob.digest, digest);
      expect(back.entry.attributes, note.entry.attributes);
      // Without a video the note keeps its older version.
      expect(RecordedNoteCodec.encode(RecordedNote.of(dish([])))[0], 1);
    });

    test(
      'a video the note does not name is left out; one it names is needed',
      () {
        final edited = RecordedNote.compose(
          dish(['clip_1']),
          clips: [clip('clip_1')],
        ).edited(dish([]), clips: [clip('clip_2')]);
        expect(edited.videos, isEmpty);
        expect(
          RecordedNote.released(
            before: RecordedNote.compose(
              dish(['clip_1']),
              clips: [clip('clip_1')],
            ),
            after: edited,
          ),
          {BlobId('clip_1')},
        );
        expect(
          () => RecordedNote.compose(dish(['clip_1'])),
          throwsArgumentError,
        );
      },
    );

    test('adversary: truncations, a missing or unnamed video are refused', () {
      final wire = RecordedNoteCodec.encode(
        RecordedNote.compose(dish(['clip_1']), clips: [clip('clip_1')]),
      );
      for (var length = 0; length < wire.length; length++) {
        expect(
          () => RecordedNoteCodec.decode(
            Uint8List.sublistView(wire, 0, length),
            schemas: recipes,
          ),
          throwsA(isA<MalformedBlobException>()),
          reason: '$length bytes',
        );
      }
      expect(
        () => RecordedNoteCodec.decode([...wire, 0], schemas: recipes),
        throwsA(isA<MalformedBlobException>()),
      );
      // The same video section under a note whose steps name another.
      final other = RecordedNoteCodec.encode(
        RecordedNote.compose(dish(['clip_9']), clips: [clip('clip_9')]),
      );
      final swapped = Uint8List.fromList([
        ...other.sublist(0, other.length - (wire.length - _body(wire))),
        ...wire.sublist(_body(wire)),
      ]);
      expect(
        () => RecordedNoteCodec.decode(swapped, schemas: recipes),
        throwsA(isA<MalformedBlobException>()),
      );
    });
  });

  group('trash', () {
    test('a note starts outside the trash', () {
      expect(RecordedNote.of(song()).trashedAt, isNull);
    });

    test('trashing keeps the note and its recordings, restoring undoes it', () {
      final note = valid(
        RecordedNote.of(song())
            .attach(take('take_1'), field: guideTrack, schema: schema, at: at),
      );

      final trashed = note.trashed(at: later);
      final restored = trashed.restored();

      expect(trashed.trashedAt, later);
      expect(trashed.entry, same(note.entry));
      expect(trashed.recordings, note.recordings);
      expect(restored.trashedAt, isNull);
      expect(restored.recordings, note.recordings);
    });

    test('the trash time is kept in UTC', () {
      final trashed = RecordedNote.of(song()).trashed(at: later.toLocal());

      expect(trashed.trashedAt!.isUtc, isTrue);
      expect(trashed.trashedAt, later);
    });

    test('an edit keeps the note where it is', () {
      final trashed = RecordedNote.of(song()).trashed(at: later);

      expect(trashed.edited(song()).trashedAt, later);
    });

    test('a note outside the trash is written as version 1, unchanged', () {
      // Apps that predate the trash read version 1 only: they keep seeing
      // every note that is not in the trash.
      final note = RecordedNote.of(song());

      final wire = RecordedNoteCodec.encode(note);

      expect(wire[0], 1);
      expect(
        wire,
        RecordedNoteCodec.encode(note.trashed(at: later).restored()),
      );
    });

    test('a trashed note round-trips with the time it was trashed', () {
      final note = valid(
        RecordedNote.of(song())
            .attach(take('take_1'), field: guideTrack, schema: schema, at: at),
      ).trashed(at: later);

      final back = valid(
        RecordedNoteCodec.decode(
          RecordedNoteCodec.encode(note),
          schemas: resolve,
        ),
      );

      expect(back.trashedAt, later);
      expect(back.trashedAt!.isUtc, isTrue);
      expect(back.recordings, note.recordings);
      expect(back.entry.attributes, note.entry.attributes);
    });
  });

  group('category', () {
    final shelf = CategoryId('0123456789abcdef0123456789abcdef');

    test('a note starts in no category and can be filed and unfiled', () {
      final note = RecordedNote.of(song());
      expect(note.category, isNull);

      final filed = note.filedIn(shelf);
      expect(filed.category, shelf);
      expect(filed.entry, same(note.entry));
      expect(filed.filedIn(null).category, isNull);
    });

    test('edits, trash and restore keep the category', () {
      final filed = RecordedNote.of(song()).filedIn(shelf);

      expect(filed.edited(song()).category, shelf);
      expect(filed.trashed(at: later).category, shelf);
      expect(filed.trashed(at: later).restored().category, shelf);
      expect(RecordedNote.compose(song(), category: shelf).category, shelf);
    });

    test('a note in no category keeps the older versions byte for byte', () {
      final note = RecordedNote.of(song());

      expect(
        RecordedNoteCodec.encode(note.filedIn(shelf).filedIn(null)),
        RecordedNoteCodec.encode(note),
      );
      expect(RecordedNoteCodec.encode(note.trashed(at: later))[0], 2);
    });

    test('a filed note round-trips, in the trash or not', () {
      final note = valid(
        RecordedNote.of(song())
            .attach(take('take_1'), field: guideTrack, schema: schema, at: at),
      ).filedIn(shelf);

      for (final written in [note, note.trashed(at: later)]) {
        final wire = RecordedNoteCodec.encode(written);
        expect(wire[0], 3);
        final back = valid(RecordedNoteCodec.decode(wire, schemas: resolve));
        expect(back.category, shelf);
        expect(back.trashedAt, written.trashedAt);
        expect(back.recordings, note.recordings);
        expect(back.entry.attributes, note.entry.attributes);
      }
    });

    test('every truncation, trailing byte and unknown flag is refused', () {
      final wire = RecordedNoteCodec.encode(
        RecordedNote.of(song()).filedIn(shelf).trashed(at: later),
      );
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
      // flags | trash time (8) | id length (1) | id (32)
      final flags = wire.length - 1 - 32 - 8 - 1;
      for (final bad in [0, 4, 0x80, 0xFF]) {
        final forged = Uint8List.fromList(wire)..[flags] = bad;
        expect(
          () => RecordedNoteCodec.decode(forged, schemas: resolve),
          throwsA(isA<MalformedBlobException>()),
          reason: 'flags $bad',
        );
      }
      final badId = Uint8List.fromList(wire)..[wire.length - 1] = 0x20;
      expect(
        () => RecordedNoteCodec.decode(badId, schemas: resolve),
        throwsA(isA<MalformedBlobException>()),
      );
    });
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

    test('every truncation of a trashed note is a format error', () {
      final wire = RecordedNoteCodec.encode(
        RecordedNote.of(song()).trashed(at: later),
      );
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

    test('a trash time past 2^53 − 1 microseconds is refused', () {
      final wire = RecordedNoteCodec.encode(
        RecordedNote.of(song()).trashed(at: later),
      );
      // The last 8 bytes are the time; on the web no larger integer is
      // exact, so every platform must refuse it alike.
      final end = wire.length;
      wire.setRange(end - 8, end, [0, 0x20, 0, 0, 0, 0, 0, 0]);

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

/// Where a version-6 note's flags start: after the version, the entry and
/// the recordings' count (none in these tests).
int _body(Uint8List wire) {
  final data = ByteData.sublistView(wire);
  return 1 + 4 + data.getUint32(1) + 2;
}
