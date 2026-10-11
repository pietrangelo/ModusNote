import 'dart:typed_data';

import 'package:blob_storage_media/blob_storage_media.dart';
import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';
import 'package:test/test.dart';

final at = DateTime.utc(2026, 10, 11, 12);
final schema = SeedSchemas.songSketchV1;
final guideTrack = FieldKey('guide_track');

BlobMetadata recording(String id) => BlobMetadata(
  blob: SealedBlob(
    id: BlobId(id),
    keyId: SubkeyId.fromBytes(Uint8List(8)),
    plaintextLength: 10,
  ),
  format: AudioFormat.opusOgg,
  duration: const Duration(seconds: 1),
  recordedAt: at,
);

T valid<T>(Validated<T> result) => switch (result) {
  Valid(:final value) => value,
  Invalid(:final violations) => throw StateError('$violations'),
};

void main() {
  late DynamicEntry entry;

  setUp(() {
    entry = valid(
      DynamicEntry.create(
        schema: schema,
        id: EntryId('e1'),
        attributes: {FieldKey('title'): const TextValue('Demo')},
        at: at,
      ),
    );
  });

  test('attaching a recording points the audio field at its blob', () {
    final attached = valid(
      AudioAttachment.attach(
        entry,
        schema: schema,
        field: guideTrack,
        recording: recording('b1'),
        at: at,
      ),
    );

    expect(attached.valueOf(guideTrack), AudioBlobValue(BlobId('b1')));
    expect(attached.audit.revision, 2);
  });

  test('a recording cannot go into a field that is not audio', () {
    final result = AudioAttachment.attach(
      entry,
      schema: schema,
      field: FieldKey('title'),
      recording: recording('b1'),
      at: at,
    );

    expect(result, isA<Invalid<DynamicEntry>>());
    expect(
      (result as Invalid<DynamicEntry>).violations.single.code,
      ViolationCode.typeMismatch,
    );
  });

  test('a recording cannot go into a field the schema does not have', () {
    final result = AudioAttachment.attach(
      entry,
      schema: schema,
      field: FieldKey('ghost_track'),
      recording: recording('b1'),
      at: at,
    );

    expect(
      (result as Invalid<DynamicEntry>).violations.single.code,
      ViolationCode.unknownField,
    );
  });

  test('referencedBlobs lists every audio blob an entry points to', () {
    final attached = valid(
      AudioAttachment.attach(
        entry,
        schema: schema,
        field: guideTrack,
        recording: recording('b1'),
        at: at,
      ),
    );

    expect(AudioAttachment.referencedBlobs(entry), isEmpty);
    expect(AudioAttachment.referencedBlobs(attached), {BlobId('b1')});
  });

  test('replacing a take releases the old blob for deletion', () {
    final first = valid(
      AudioAttachment.attach(
        entry,
        schema: schema,
        field: guideTrack,
        recording: recording('b1'),
        at: at,
      ),
    );
    final second = valid(
      AudioAttachment.attach(
        first,
        schema: schema,
        field: guideTrack,
        recording: recording('b2'),
        at: at,
      ),
    );

    expect(AudioAttachment.releasedBlobs(before: first, after: second), {
      BlobId('b1'),
    });
    expect(
      AudioAttachment.releasedBlobs(before: second, after: second),
      isEmpty,
    );
  });
}
