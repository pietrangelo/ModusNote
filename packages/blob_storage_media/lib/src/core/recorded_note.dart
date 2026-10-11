import 'dart:convert';
import 'dart:typed_data';

import 'package:collaboration_access_control/collaboration_access_control.dart';
import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:meta/meta.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import 'audio_attachment.dart';
import 'audio_format.dart';
import 'blob_exception.dart';
import 'blob_metadata.dart';

/// A recording with the GroupKey epoch whose key it was sealed under: the
/// note is re-sealed under newer epochs as it is edited, the blob is not,
/// so a reader must know which content key to derive the BlobKey from.
@immutable
final class KeyedRecording {
  const KeyedRecording({required this.epoch, required this.metadata});

  final KeyEpoch epoch;
  final BlobMetadata metadata;

  BlobId get id => metadata.id;

  @override
  bool operator ==(Object other) =>
      other is KeyedRecording &&
      other.epoch == epoch &&
      other.metadata == metadata;

  @override
  int get hashCode => Object.hash(epoch, metadata);
}

/// A note together with the metadata of every recording it references,
/// the plaintext the vault seals as one record. Holding them together is
/// what keeps format, length and key id out of the server's sight.
///
/// Invariant: [recordings] has exactly the blobs the entry references.
@immutable
final class RecordedNote {
  RecordedNote._(this.entry, Map<BlobId, KeyedRecording> recordings)
    : recordings = Map.unmodifiable(recordings);

  /// Pairs [entry] with the metadata of the blobs it references, picked
  /// from [known]; known takes it no longer references are left out. Every
  /// referenced blob must be known, or the note could never be decoded.
  factory RecordedNote.compose(
    DynamicEntry entry, {
    Iterable<KeyedRecording> known = const [],
  }) {
    final byId = {for (final take in known) take.id: take};
    final recordings = <BlobId, KeyedRecording>{};
    for (final id in AudioAttachment.referencedBlobs(entry)) {
      recordings[id] =
          byId[id] ??
          (throw ArgumentError.value(id.value, 'entry', 'unknown recording'));
    }
    return RecordedNote._(entry, recordings);
  }

  factory RecordedNote.of(DynamicEntry entry) => RecordedNote.compose(entry);

  final DynamicEntry entry;
  final Map<BlobId, KeyedRecording> recordings;

  /// Puts [take] in the audio [field]; a take it replaces is dropped.
  Validated<RecordedNote> attach(
    KeyedRecording take, {
    required FieldKey field,
    required SchemaDefinition schema,
    required DateTime at,
  }) {
    if (schema.fieldFor(field)?.type is! AudioBlobFieldType) {
      return Invalid([Violation(ViolationCode.typeMismatch, field)]);
    }
    return switch (AudioAttachment.attach(
      entry,
      schema: schema,
      field: field,
      recording: take.metadata,
      at: at,
    )) {
      Valid(:final value) => Valid(
        RecordedNote.compose(value, known: [...recordings.values, take]),
      ),
      Invalid(:final violations) => Invalid(violations),
    };
  }

  /// The same note after an edit of its fields, with [takes] recorded
  /// during the edit: recordings whose field was cleared or replaced go.
  RecordedNote edited(
    DynamicEntry next, {
    Iterable<KeyedRecording> takes = const [],
  }) => RecordedNote.compose(next, known: [...recordings.values, ...takes]);

  /// Blobs [before] held that [after] does not: ciphertext to delete once
  /// [after] is saved.
  static Set<BlobId> released({
    required RecordedNote before,
    required RecordedNote after,
  }) =>
      before.recordings.keys.toSet().difference(after.recordings.keys.toSet());
}

/// Bytes form of a [RecordedNote]: `version(1) | entry (EntryCodec, u32
/// length) | count(u16) | recordings`. Decoding treats its input as
/// hostile and throws only [MalformedBlobException].
abstract final class RecordedNoteCodec {
  static const _version = 1;
  static const _maxRecordings = 64;

  static Uint8List encode(RecordedNote note) =>
      encodeUnchecked(note.entry, note.recordings);

  /// Writes any pairing, even one [decode] refuses; for adversary tests.
  @visibleForTesting
  static Uint8List encodeUnchecked(
    DynamicEntry entry,
    Map<BlobId, KeyedRecording> recordings,
  ) {
    final out = BytesBuilder(copy: false)..addByte(_version);
    _blob(out, EntryCodec.encode(entry));
    out.add(_uint(2, recordings.length));
    for (final take in recordings.values) {
      final metadata = take.metadata;
      _blob(out, utf8.encode(metadata.id.value));
      out
        ..add(_uint(4, take.epoch.value))
        ..add(metadata.blob.keyId.bytes)
        ..add(_uint(8, metadata.blob.plaintextLength));
      _blob(out, utf8.encode(metadata.format.wireName));
      out
        ..add(_uint(8, metadata.duration.inMicroseconds))
        ..add(_uint(8, metadata.recordedAt.microsecondsSinceEpoch));
    }
    return out.takeBytes();
  }

  static Validated<RecordedNote> decode(
    List<int> bytes, {
    required SchemaDefinition? Function(SchemaId) schemas,
  }) {
    try {
      final reader = _Reader(bytes);
      if (reader.uint(1) != _version) {
        throw const MalformedBlobException('unknown note version');
      }
      final entryBytes = reader.blob();
      final count = reader.uint(2);
      if (count > _maxRecordings) {
        throw const MalformedBlobException('too many recordings');
      }
      final recordings = <BlobId, KeyedRecording>{};
      for (var i = 0; i < count; i++) {
        final take = _readRecording(reader);
        if (recordings.containsKey(take.id)) {
          throw const MalformedBlobException('duplicate recording');
        }
        recordings[take.id] = take;
      }
      reader.finish();
      return switch (EntryCodec.decode(entryBytes, schemas: schemas)) {
        Valid(value: final entry) => Valid(_paired(entry, recordings)),
        Invalid(:final violations) => Invalid(violations),
      };
    } on EntryFormatException {
      throw const MalformedBlobException('malformed entry');
    } on InvalidBlobMetadataException {
      throw const MalformedBlobException('malformed recording');
    } on InvalidSchemaException {
      throw const MalformedBlobException('malformed recording id');
    } on CollaborationException {
      throw const MalformedBlobException('malformed recording epoch');
    } on FormatException {
      throw const MalformedBlobException('malformed recording text');
    }
  }

  static RecordedNote _paired(
    DynamicEntry entry,
    Map<BlobId, KeyedRecording> recordings,
  ) {
    final referenced = AudioAttachment.referencedBlobs(entry);
    if (referenced.length != recordings.length ||
        !referenced.containsAll(recordings.keys)) {
      throw const MalformedBlobException('recordings do not match the note');
    }
    return RecordedNote._(entry, recordings);
  }

  static KeyedRecording _readRecording(_Reader reader) {
    final id = BlobId(utf8.decode(reader.blob()));
    final epoch = KeyEpoch(reader.uint(4));
    final keyId = SubkeyId.fromBytes(reader.bytes(SubkeyId.length));
    final length = reader.uint(8);
    final format = AudioFormat.fromWireName(utf8.decode(reader.blob()));
    final duration = Duration(microseconds: reader.uint(8));
    final micros = reader.uint(8);
    if (micros > _maxMicros) {
      throw const MalformedBlobException('recordedAt out of range');
    }
    return KeyedRecording(
      epoch: epoch,
      metadata: BlobMetadata(
        blob: SealedBlob(id: id, keyId: keyId, plaintextLength: length),
        format: format,
        duration: duration,
        recordedAt: DateTime.fromMicrosecondsSinceEpoch(micros, isUtc: true),
      ),
    );
  }

  /// DateTime's own limit, so construction can never throw past the checks.
  static const _maxMicros = 8640000000000000000;

  static void _blob(BytesBuilder out, List<int> bytes) {
    out
      ..add(_uint(4, bytes.length))
      ..add(bytes);
  }

  static Uint8List _uint(int width, int value) {
    final bytes = Uint8List(width);
    final data = ByteData.sublistView(bytes);
    switch (width) {
      case 2:
        data.setUint16(0, value);
      case 4:
        data.setUint32(0, value);
      default:
        data.setInt64(0, value);
    }
    return bytes;
  }
}

final class _Reader {
  _Reader(List<int> bytes) : _bytes = Uint8List.fromList(bytes);

  final Uint8List _bytes;
  var _offset = 0;

  Uint8List bytes(int length) {
    if (length < 0 || length > _bytes.length - _offset) {
      throw const MalformedBlobException('truncated note');
    }
    final view = Uint8List.sublistView(_bytes, _offset, _offset + length);
    _offset += length;
    return view;
  }

  /// Unsigned; 8-byte values above 2^63 read as negative and are refused.
  int uint(int width) {
    final data = ByteData.sublistView(bytes(width));
    final value = switch (width) {
      1 => data.getUint8(0),
      2 => data.getUint16(0),
      4 => data.getUint32(0),
      _ => data.getInt64(0),
    };
    if (value < 0) throw const MalformedBlobException('negative value');
    return value;
  }

  Uint8List blob() => bytes(uint(4));

  void finish() {
    if (_offset != _bytes.length) {
      throw const MalformedBlobException('trailing bytes');
    }
  }
}
