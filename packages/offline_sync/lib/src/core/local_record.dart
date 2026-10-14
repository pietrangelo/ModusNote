import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'record_revision.dart';
import 'version_vector.dart';
import 'wire.dart';

/// What a device keeps for a record: the winning revision, every version it
/// has seen and the latest time any of them was written. Stored sealed under
/// the device-local key, never in clear.
/// Wire: `signedRevision (length-prefixed) | seen | latest (µs)`; records
/// written before `latest` existed end after `seen`.
@immutable
final class LocalRecord {
  LocalRecord({required this.current, required this.seen, DateTime? latest})
    : latest = latest ?? current.revision.writtenAt;

  factory LocalRecord.parse(List<int> wire) {
    final reader = WireReader(wire);
    final current = SignedRevision.parse(reader.blob());
    final seen = VersionVector.read(reader);
    final latest = reader.remaining == 0
        ? null
        : DateTime.fromMicrosecondsSinceEpoch(reader.int64(), isUtc: true);
    reader.finish();
    return LocalRecord(current: current, seen: seen, latest: latest);
  }

  final SignedRevision current;
  final VersionVector seen;

  /// The latest `writtenAt` among the revisions merged into [seen]. The
  /// next edit is written after it, so time never runs backwards along a
  /// chain of edits and last-writer-wins becomes one total order that every
  /// device applies the same way, whichever superseded rows it saw.
  final DateTime latest;

  /// [latest] after merging a revision written at [writtenAt].
  DateTime latestWith(DateTime writtenAt) =>
      writtenAt.isAfter(latest) ? writtenAt : latest;

  Uint8List toBytes() {
    final writer = WireWriter()..blob(current.toBytes());
    seen.write(writer);
    writer.int64(latest.microsecondsSinceEpoch);
    return writer.take();
  }
}
