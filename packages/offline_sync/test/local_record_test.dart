import 'package:offline_sync/offline_sync.dart';
import 'package:offline_sync/src/core/wire.dart';
import 'package:test/test.dart';

import 'revision_test.dart' show revision;
import 'support.dart';

void main() {
  final signed = SignedRevision(
    revision: revision(writtenAt: DateTime.utc(2026, 10, 11, 9)),
    signature: signatureOf(9),
  );
  final seen = VersionVector.empty.increment(memberOf(1));

  test('round-trips the latest time any merged revision was written', () {
    final latest = DateTime.utc(2026, 10, 11, 12, 0, 0, 0, 7);
    final parsed = LocalRecord.parse(
      LocalRecord(current: signed, seen: seen, latest: latest).toBytes(),
    );

    expect(parsed.current, signed);
    expect(parsed.seen, seen);
    expect(parsed.latest, latest);
    expect(parsed.latest.isUtc, isTrue);
  });

  test('a record stored before the latest time existed starts from its '
      'current revision', () {
    final writer = WireWriter()..blob(signed.toBytes());
    seen.write(writer);

    final parsed = LocalRecord.parse(writer.take());

    expect(parsed.latest, signed.revision.writtenAt);
  });

  test('merging keeps the later of two times', () {
    final record = LocalRecord(current: signed, seen: seen);
    final later = DateTime.utc(2026, 10, 11, 10);

    expect(record.latestWith(later), later);
    expect(record.latestWith(DateTime.utc(2026, 10, 11, 8)), record.latest);
  });

  test('trailing bytes after the latest time are refused', () {
    final bytes = [...LocalRecord(current: signed, seen: seen).toBytes(), 0];

    expect(
      () => LocalRecord.parse(bytes),
      throwsA(isA<MalformedSyncDataException>()),
    );
  });
}
