import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'record_revision.dart';
import 'version_vector.dart';
import 'wire.dart';

/// What a device keeps for a record: the winning revision and every version
/// it has seen. Stored sealed under the device-local key, never in clear.
/// Wire: `signedRevision (length-prefixed) | seen`.
@immutable
final class LocalRecord {
  const LocalRecord({required this.current, required this.seen});

  factory LocalRecord.parse(List<int> wire) {
    final reader = WireReader(wire);
    final current = SignedRevision.parse(reader.blob());
    final seen = VersionVector.read(reader);
    reader.finish();
    return LocalRecord(current: current, seen: seen);
  }

  final SignedRevision current;
  final VersionVector seen;

  Uint8List toBytes() {
    final writer = WireWriter()..blob(current.toBytes());
    seen.write(writer);
    return writer.take();
  }
}
