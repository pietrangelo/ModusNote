import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import 'blob_metadata.dart';

/// Links recordings to the audio fields of a [DynamicEntry].
///
/// The entry stores only the [BlobId]; the [BlobMetadata] (format, key id,
/// length) belongs to this context and travels encrypted beside the entry.
abstract final class AudioAttachment {
  /// Validated like any other update, so a recording can only land in a
  /// field the schema declares as audio.
  static Validated<DynamicEntry> attach(
    DynamicEntry entry, {
    required SchemaDefinition schema,
    required FieldKey field,
    required BlobMetadata recording,
    required DateTime at,
  }) => entry.update(
    schema: schema,
    changes: {field: AudioBlobValue(recording.id)},
    at: at,
  );

  static Set<BlobId> referencedBlobs(DynamicEntry entry) => {
    for (final value in entry.attributes.values)
      if (value is AudioBlobValue) value.blob,
  };

  /// Blobs [before] pointed to that [after] no longer does: the ciphertext
  /// to delete once [after] is saved, so replaced takes do not pile up.
  static Set<BlobId> releasedBlobs({
    required DynamicEntry before,
    required DynamicEntry after,
  }) => referencedBlobs(before).difference(referencedBlobs(after));
}
