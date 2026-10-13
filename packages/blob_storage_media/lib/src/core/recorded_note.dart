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
import 'image_format.dart';
import 'portable_int64.dart';

/// A blob a note references, with the GroupKey epoch whose key sealed it:
/// what replicating, downloading or deleting it needs, whatever it holds.
abstract interface class KeyedBlob {
  KeyEpoch get epoch;

  SealedBlob get blob;

  BlobId get id;
}

/// A recording with the GroupKey epoch whose key it was sealed under: the
/// note is re-sealed under newer epochs as it is edited, the blob is not,
/// so a reader must know which content key to derive the BlobKey from.
@immutable
final class KeyedRecording implements KeyedBlob {
  const KeyedRecording({required this.epoch, required this.metadata});

  @override
  final KeyEpoch epoch;
  final BlobMetadata metadata;

  @override
  SealedBlob get blob => metadata.blob;

  @override
  BlobId get id => metadata.id;

  @override
  bool operator ==(Object other) =>
      other is KeyedRecording &&
      other.epoch == epoch &&
      other.metadata == metadata;

  @override
  int get hashCode => Object.hash(epoch, metadata);
}

/// A picture with the GroupKey epoch whose key sealed it, like
/// [KeyedRecording].
@immutable
final class KeyedImage implements KeyedBlob {
  const KeyedImage({required this.epoch, required this.metadata});

  @override
  final KeyEpoch epoch;
  final ImageMetadata metadata;

  @override
  SealedBlob get blob => metadata.blob;

  @override
  BlobId get id => metadata.id;

  @override
  bool operator ==(Object other) =>
      other is KeyedImage && other.epoch == epoch && other.metadata == metadata;

  @override
  int get hashCode => Object.hash(epoch, metadata);
}

/// A note together with the metadata of every recording it references,
/// the plaintext the vault seals as one record. Holding them together is
/// what keeps format, length and key id out of the server's sight.
///
/// Invariant: [recordings] has exactly the recordings the entry
/// references, and [images] exactly its pictures.
///
/// A note in the trash is still whole, recordings included, so restoring
/// it brings everything back; only deleting it for good (a tombstone in the
/// sync layer) lets its recordings go.
///
/// The category a note is filed in travels here too, sealed with it: the
/// server cannot tell which notes share one.
@immutable
final class RecordedNote {
  RecordedNote._(
    this.entry,
    Map<BlobId, KeyedRecording> recordings, {
    Map<BlobId, KeyedImage> images = const {},
    DateTime? trashedAt,
    this.category,
  }) : recordings = Map.unmodifiable(recordings),
       images = Map.unmodifiable(images),
       trashedAt = trashedAt?.toUtc();

  /// Pairs [entry] with the metadata of the blobs it references, picked
  /// from [known]; known takes it no longer references are left out. Every
  /// referenced blob must be known, or the note could never be decoded.
  factory RecordedNote.compose(
    DynamicEntry entry, {
    Iterable<KeyedRecording> known = const [],
    Iterable<KeyedImage> pictures = const [],
    CategoryId? category,
  }) {
    final byId = {for (final take in known) take.id: take};
    final recordings = <BlobId, KeyedRecording>{};
    for (final id in AudioAttachment.referencedBlobs(entry)) {
      recordings[id] =
          byId[id] ??
          (throw ArgumentError.value(id.value, 'entry', 'unknown recording'));
    }
    final imagesById = {for (final image in pictures) image.id: image};
    final images = <BlobId, KeyedImage>{};
    for (final id in AttachmentsValue.imagesOf(entry)) {
      images[id] =
          imagesById[id] ??
          (throw ArgumentError.value(id.value, 'entry', 'unknown picture'));
    }
    return RecordedNote._(
      entry,
      recordings,
      images: images,
      category: category,
    );
  }

  factory RecordedNote.of(DynamicEntry entry) => RecordedNote.compose(entry);

  final DynamicEntry entry;
  final Map<BlobId, KeyedRecording> recordings;

  /// The pictures of the note's attachments.
  final Map<BlobId, KeyedImage> images;

  /// Every blob the note needs: its recordings and its pictures.
  Iterable<KeyedBlob> get blobs => [...recordings.values, ...images.values];

  /// When the note was moved to the trash, in UTC; null when it is not.
  final DateTime? trashedAt;

  bool get isTrashed => trashedAt != null;

  /// The category the note is filed in; null for none. It may name one
  /// that is gone: [CategoryTree.resolve] says where the note shows.
  final CategoryId? category;

  /// The same note in the trash since [at].
  RecordedNote trashed({required DateTime at}) => RecordedNote._(
    entry,
    recordings,
    images: images,
    trashedAt: at,
    category: category,
  );

  /// The same note back out of the trash, in the category it had.
  RecordedNote restored() =>
      RecordedNote._(entry, recordings, images: images, category: category);

  /// The same note filed in [category] (null: in none).
  RecordedNote filedIn(CategoryId? category) => RecordedNote._(
    entry,
    recordings,
    images: images,
    trashedAt: trashedAt,
    category: category,
  );

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
      Valid(:final value) => Valid(edited(value, takes: [take])),
      Invalid(:final violations) => Invalid(violations),
    };
  }

  /// The same note after an edit of its fields, with [takes] recorded and
  /// [pictures] added during the edit: recordings and pictures it no
  /// longer references go.
  RecordedNote edited(
    DynamicEntry next, {
    Iterable<KeyedRecording> takes = const [],
    Iterable<KeyedImage> pictures = const [],
  }) {
    final note = RecordedNote.compose(
      next,
      known: [...recordings.values, ...takes],
      pictures: [...images.values, ...pictures],
    );
    return RecordedNote._(
      note.entry,
      note.recordings,
      images: note.images,
      trashedAt: trashedAt,
      category: category,
    );
  }

  /// Blobs [before] held that [after] does not: ciphertext to delete once
  /// [after] is saved.
  static Set<BlobId> released({
    required RecordedNote before,
    required RecordedNote after,
  }) =>
      {for (final blob in before.blobs) blob.id}
          .difference({for (final blob in after.blobs) blob.id});
}

/// Bytes form of a [RecordedNote]: `version(1) | entry (EntryCodec, u32
/// length) | count(u16) | recordings`, then
/// * in version 2, the trash time (u64 microseconds since the epoch, UTC);
/// * in version 3, `flags(1)` (bit 0 in the trash, bit 1 filed, which is
///   always set), the trash time if bit 0, then the category id (u8
///   length, ASCII);
/// * in version 4, the same flags with bit 2 (pictures) always set and
///   bit 1 as needed, then after the category `count(u16) | pictures`.
///
/// Each note is written in the oldest version that holds it: one outside
/// the trash and any category is version 1, byte for byte what apps
/// without a trash read, a trashed one outside any category version 2,
/// and only a note with pictures version 4.
/// Older apps see a note in a later version as unreadable, so it leaves
/// their library until they are updated. Decoding treats its input as
/// hostile and throws only [MalformedBlobException].
abstract final class RecordedNoteCodec {
  static const _version = 1;
  static const _trashedVersion = 2;
  static const _filedVersion = 3;
  static const _picturedVersion = 4;
  static const _trashedFlag = 1;
  static const _filedFlag = 2;
  static const _picturesFlag = 4;
  static const _maxRecordings = 64;
  static const _maxImages = AttachmentsFieldType.maxAllowedItems;

  static Uint8List encode(RecordedNote note) {
    final bytes = _encodeBody(note.entry, note.recordings);
    final trashedAt = note.trashedAt;
    final category = note.category;
    final images = note.images.values;
    if (trashedAt == null && category == null && images.isEmpty) return bytes;
    final version = images.isNotEmpty
        ? _picturedVersion
        : category != null
        ? _filedVersion
        : _trashedVersion;
    final out = BytesBuilder(copy: false)
      ..addByte(version)
      ..add(Uint8List.sublistView(bytes, 1));
    if (version != _trashedVersion) {
      out.addByte(
        (trashedAt == null ? 0 : _trashedFlag) |
            (category == null ? 0 : _filedFlag) |
            (images.isEmpty ? 0 : _picturesFlag),
      );
    }
    if (trashedAt != null) {
      out.add(_uint(8, trashedAt.microsecondsSinceEpoch));
    }
    if (category != null) {
      final id = ascii.encode(category.value);
      out
        ..addByte(id.length)
        ..add(id);
    }
    if (images.isNotEmpty) _writeImages(out, images);
    return out.takeBytes();
  }

  /// Writes any pairing, even one [decode] refuses; for adversary tests.
  /// With [images], the note is written as version 4 with only those.
  @visibleForTesting
  static Uint8List encodeUnchecked(
    DynamicEntry entry,
    Map<BlobId, KeyedRecording> recordings, {
    Map<BlobId, KeyedImage>? images,
  }) {
    final bytes = _encodeBody(entry, recordings);
    if (images == null) return bytes;
    final out = BytesBuilder(copy: false)
      ..addByte(_picturedVersion)
      ..add(Uint8List.sublistView(bytes, 1))
      ..addByte(_picturesFlag);
    _writeImages(out, images.values);
    return out.takeBytes();
  }

  static void _writeImages(BytesBuilder out, Iterable<KeyedImage> images) {
    out.add(_uint(2, images.length));
    for (final image in images) {
      final metadata = image.metadata;
      _blob(out, utf8.encode(metadata.id.value));
      out
        ..add(_uint(4, image.epoch.value))
        ..add(metadata.blob.keyId.bytes)
        ..add(_uint(8, metadata.blob.plaintextLength));
      _blob(out, utf8.encode(metadata.format.wireName));
      out
        ..add(_uint(4, metadata.info.width))
        ..add(_uint(4, metadata.info.height))
        ..add(_uint(8, metadata.addedAt.microsecondsSinceEpoch));
    }
  }

  static Uint8List _encodeBody(
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
      final version = reader.uint(1);
      if (version < _version || version > _picturedVersion) {
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
      final flags = switch (version) {
        _version => 0,
        _trashedVersion => _trashedFlag,
        _ => reader.uint(1),
      };
      // Each version holds exactly what the one before it could not.
      final required = switch (version) {
        _filedVersion => _filedFlag,
        _picturedVersion => _picturesFlag,
        _ => 0,
      };
      final allowed = version == _picturedVersion
          ? _trashedFlag | _filedFlag | _picturesFlag
          : _trashedFlag | _filedFlag;
      if (flags & required != required || flags & ~allowed != 0) {
        throw const MalformedBlobException('unknown note flags');
      }
      final trashedAt = flags & _trashedFlag != 0 ? _time(reader) : null;
      final category = flags & _filedFlag != 0
          ? CategoryId(ascii.decode(reader.bytes(reader.uint(1))))
          : null;
      final images = <BlobId, KeyedImage>{};
      if (flags & _picturesFlag != 0) {
        final count = reader.uint(2);
        if (count > _maxImages) {
          throw const MalformedBlobException('too many pictures');
        }
        for (var i = 0; i < count; i++) {
          final image = _readImage(reader);
          if (images.containsKey(image.id) ||
              recordings.containsKey(image.id)) {
            throw const MalformedBlobException('duplicate picture');
          }
          images[image.id] = image;
        }
      }
      reader.finish();
      return switch (EntryCodec.decode(entryBytes, schemas: schemas)) {
        Valid(value: final entry) => Valid(
          _paired(
            entry,
            recordings,
            images,
            trashedAt: trashedAt,
            category: category,
          ),
        ),
        Invalid(:final violations) => Invalid(violations),
      };
    } on EntryFormatException {
      throw const MalformedBlobException('malformed entry');
    } on InvalidBlobMetadataException {
      throw const MalformedBlobException('malformed recording');
    } on ImageTooLargeException {
      throw const MalformedBlobException('malformed picture');
    } on InvalidSchemaException {
      throw const MalformedBlobException('malformed recording id');
    } on CollaborationException {
      throw const MalformedBlobException('malformed recording epoch');
    } on InvalidValueException {
      throw const MalformedBlobException('malformed category');
    } on FormatException {
      throw const MalformedBlobException('malformed recording text');
    }
  }

  static RecordedNote _paired(
    DynamicEntry entry,
    Map<BlobId, KeyedRecording> recordings,
    Map<BlobId, KeyedImage> images, {
    DateTime? trashedAt,
    CategoryId? category,
  }) {
    final referenced = AudioAttachment.referencedBlobs(entry);
    if (referenced.length != recordings.length ||
        !referenced.containsAll(recordings.keys)) {
      throw const MalformedBlobException('recordings do not match the note');
    }
    final pictured = AttachmentsValue.imagesOf(entry).toSet();
    if (pictured.length != images.length ||
        !pictured.containsAll(images.keys)) {
      throw const MalformedBlobException('pictures do not match the note');
    }
    return RecordedNote._(
      entry,
      recordings,
      images: images,
      trashedAt: trashedAt,
      category: category,
    );
  }

  static KeyedImage _readImage(_Reader reader) {
    final id = BlobId(utf8.decode(reader.blob()));
    final epoch = KeyEpoch(reader.uint(4));
    final keyId = SubkeyId.fromBytes(reader.bytes(SubkeyId.length));
    final length = reader.uint(8);
    final format = ImageFormat.fromWireName(utf8.decode(reader.blob()));
    final width = reader.uint(4);
    final height = reader.uint(4);
    return KeyedImage(
      epoch: epoch,
      metadata: ImageMetadata(
        blob: SealedBlob(id: id, keyId: keyId, plaintextLength: length),
        info: ImageInfo(format, width, height),
        addedAt: _time(reader),
      ),
    );
  }

  static DateTime _time(_Reader reader) {
    final micros = reader.uint(8);
    if (micros > _maxMicros) {
      throw const MalformedBlobException('time out of range');
    }
    return DateTime.fromMicrosecondsSinceEpoch(micros, isUtc: true);
  }

  static KeyedRecording _readRecording(_Reader reader) {
    final id = BlobId(utf8.decode(reader.blob()));
    final epoch = KeyEpoch(reader.uint(4));
    final keyId = SubkeyId.fromBytes(reader.bytes(SubkeyId.length));
    final length = reader.uint(8);
    final format = AudioFormat.fromWireName(utf8.decode(reader.blob()));
    final duration = Duration(microseconds: reader.uint(8));
    final recordedAt = _time(reader);
    return KeyedRecording(
      epoch: epoch,
      metadata: BlobMetadata(
        blob: SealedBlob(id: id, keyId: keyId, plaintextLength: length),
        format: format,
        duration: duration,
        recordedAt: recordedAt,
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
        setPortableInt64(data, 0, value);
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

  /// Unsigned; 8-byte values are refused when negative or beyond 2^53 − 1.
  int uint(int width) {
    final data = ByteData.sublistView(bytes(width));
    final value = switch (width) {
      1 => data.getUint8(0),
      2 => data.getUint16(0),
      4 => data.getUint32(0),
      _ =>
        getPortableInt64(data, 0) ??
            (throw const MalformedBlobException('value out of range')),
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
