import 'dart:typed_data';

import 'package:glados/glados.dart';
import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:offline_sync/offline_sync.dart';

import 'support.dart';

final recordId = RecordId.parse('0123456789abcdef0123456789abcdef');

RecordRevision revision({
  RevisionBody body = const RevisionContents([1, 2, 3]),
  VersionVector? version,
  int sequence = 2,
  DateTime? writtenAt,
  int author = 1,
}) => RecordRevision(
  record: recordId,
  workspace: workspaceId,
  version: version ?? VersionVector.empty.increment(memberOf(author)),
  author: memberOf(author),
  writtenAt: writtenAt ?? DateTime.utc(2026, 10, 11, 13, 30),
  ledgerHead: LedgerHead(sequence: sequence, signature: signatureOf(5)),
  body: body,
);

void main() {
  group('RecordId', () {
    test('is 16 random bytes in lower-case hex, like every opaque id', () {
      expect(recordId.hex, '0123456789abcdef0123456789abcdef');
      expect(
        () => RecordId.parse('xyz'),
        throwsA(isA<MalformedSyncDataException>()),
      );
    });
  });

  group('SignedRevision', () {
    test('round-trips contents and tombstones through the wire', () {
      for (final body in [
        const RevisionContents([1, 2, 3]),
        const RevisionContents([]),
        const RevisionDeleted(),
      ]) {
        final signed = SignedRevision(
          revision: revision(body: body),
          signature: signatureOf(9),
        );

        expect(SignedRevision.parse(signed.toBytes()), signed);
      }
    });

    test('keeps the time to the microsecond, in UTC', () {
      final at = DateTime.utc(2026, 10, 11, 13, 30, 15, 123, 456);
      final parsed = SignedRevision.parse(
        SignedRevision(
          revision: revision(writtenAt: at),
          signature: signatureOf(9),
        ).toBytes(),
      );

      expect(parsed.revision.writtenAt, at);
      expect(parsed.revision.writtenAt.isUtc, isTrue);
    });

    test('the signed message is labelled and binds every field', () {
      final base = revision().signable;

      expect(String.fromCharCodes(base.take(21)), 'modusnote.revision.v1');
      for (final variant in [
        revision(body: const RevisionContents([1, 2, 4])),
        revision(body: const RevisionDeleted()),
        revision(
          version: VersionVector.empty
              .increment(memberOf(1))
              .increment(memberOf(1)),
        ),
        revision(sequence: 3),
        revision(writtenAt: DateTime.utc(2026, 10, 11, 13, 31)),
        revision(author: 2),
      ]) {
        expect(variant.signable, isNot(base));
      }
    });

    test('writtenAt must be UTC, so every device encodes the same instant', () {
      expect(
        () => revision(writtenAt: DateTime(2026, 10, 11)),
        throwsA(isA<MalformedSyncDataException>()),
      );
    });

    group('adversary', () {
      test('every truncation and trailing byte is refused', () {
        final wire = SignedRevision(
          revision: revision(),
          signature: signatureOf(9),
        ).toBytes();
        for (var length = 0; length < wire.length; length++) {
          expect(
            () => SignedRevision.parse(Uint8List.sublistView(wire, 0, length)),
            throwsA(isA<MalformedSyncDataException>()),
          );
        }
        expect(
          () => SignedRevision.parse(Uint8List.fromList([...wire, 0])),
          throwsA(isA<MalformedSyncDataException>()),
        );
      });

      test('a timestamp outside what a date can hold is refused', () {
        final wire = SignedRevision(
          revision: revision(body: const RevisionDeleted()),
          signature: signatureOf(9),
        ).toBytes();
        // writtenAt is followed by sequence(4), signature(64), kind(1) and
        // the trailing signature(64).
        final at = wire.length - Signature.length - 1 - 64 - 4 - 8;
        final tampered = Uint8List.fromList(wire)
          ..setRange(at, at + 8, [
            0x7F,
            0xFF,
            0xFF,
            0xFF,
            0xFF,
            0xFF,
            0xFF,
            0xFF,
          ]);

        expect(
          () => SignedRevision.parse(tampered),
          throwsA(isA<MalformedSyncDataException>()),
        );
      });

      test('a contents length beyond the payload is refused', () {
        final wire = SignedRevision(
          revision: revision(),
          signature: signatureOf(9),
        ).toBytes();
        // The contents length prefix sits right before the 3 payload bytes
        // and the 64-byte signature.
        final at = wire.length - Signature.length - 3 - 4;
        final tampered = Uint8List.fromList(wire)
          ..setRange(at, at + 4, [0xFF, 0xFF, 0xFF, 0xFF]);

        expect(
          () => SignedRevision.parse(tampered),
          throwsA(isA<MalformedSyncDataException>()),
        );
      });

      Glados(any.list(any.uint8))
          .test('random bytes never crash the parser', (bytes) {
            try {
              SignedRevision.parse(Uint8List.fromList(bytes));
            } on MalformedSyncDataException {
              // The only acceptable failure.
            }
          });
    });
  });

  group('ConflictResolver', () {
    SignedRevision signed(RecordRevision revision) =>
        SignedRevision(revision: revision, signature: signatureOf(9));

    final base = VersionVector.empty.increment(memberOf(1));

    test('a revision that knows the other one replaces it', () {
      final older = signed(revision(version: base));
      final newer = signed(
        revision(version: base.increment(memberOf(2)), author: 2),
      );

      expect(ConflictResolver.resolve(older, newer).winner, newer);
      expect(ConflictResolver.resolve(newer, older).winner, newer);
      expect(ConflictResolver.resolve(newer, older).concurrent, isFalse);
    });

    test(
      'concurrent revisions: the later one wins, then the author breaks ties',
      () {
        final early = signed(
          revision(
            version: base.increment(memberOf(1)),
            writtenAt: DateTime.utc(2026, 10, 11, 10),
          ),
        );
        final late = signed(
          revision(
            version: base.increment(memberOf(2)),
            writtenAt: DateTime.utc(2026, 10, 11, 11),
            author: 2,
          ),
        );

        expect(ConflictResolver.resolve(early, late).winner, late);
        expect(ConflictResolver.resolve(late, early).winner, late);
        expect(ConflictResolver.resolve(late, early).concurrent, isTrue);

        final sameTimeA = signed(
          revision(version: base.increment(memberOf(1))),
        );
        final sameTimeB = signed(
          revision(version: base.increment(memberOf(2)), author: 2),
        );
        expect(
          ConflictResolver.resolve(sameTimeA, sameTimeB).winner,
          ConflictResolver.resolve(sameTimeB, sameTimeA).winner,
          reason: 'every device must pick the same winner',
        );
      },
    );

    test('the record remembers every version it has seen', () {
      final left = signed(revision(version: base.increment(memberOf(1))));
      final right = signed(
        revision(version: base.increment(memberOf(2)), author: 2),
      );
      final resolved = ConflictResolver.resolve(left, right);

      expect(resolved.seen.counterOf(memberOf(1)), 2);
      expect(resolved.seen.counterOf(memberOf(2)), 1);
    });

    test('a replayed old revision never replaces a newer one', () {
      final older = signed(revision(version: base));
      final newer = signed(revision(version: base.increment(memberOf(1))));

      expect(ConflictResolver.resolve(newer, older).winner, newer);
      expect(ConflictResolver.resolve(newer, older).changed, isFalse);
    });
  });
}
