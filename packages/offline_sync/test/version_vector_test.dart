import 'package:glados/glados.dart';
import 'package:offline_sync/offline_sync.dart';

import 'support.dart';

void main() {
  final a = memberOf(1);
  final b = memberOf(2);

  test('starts empty and counts each device separately', () {
    final version = VersionVector.empty.increment(a).increment(a).increment(b);

    expect(version.counterOf(a), 2);
    expect(version.counterOf(b), 1);
    expect(version.counterOf(memberOf(3)), 0);
  });

  test('is immutable', () {
    final base = VersionVector.empty.increment(a);
    base.increment(a);

    expect(base.counterOf(a), 1);
  });

  test('compares causally', () {
    final one = VersionVector.empty.increment(a);
    final two = one.increment(a);
    final other = VersionVector.empty.increment(b);

    expect(one.compareTo(one), Causality.equal);
    expect(one.compareTo(two), Causality.before);
    expect(two.compareTo(one), Causality.after);
    expect(one.compareTo(other), Causality.concurrent);
  });

  test('merge is the pointwise maximum and dominates both sides', () {
    final left = VersionVector.empty.increment(a).increment(a);
    final right = VersionVector.empty.increment(a).increment(b);
    final merged = left.merge(right);

    expect(merged.counterOf(a), 2);
    expect(merged.counterOf(b), 1);
    expect(left.compareTo(merged), Causality.before);
    expect(right.compareTo(merged), Causality.before);
  });

  Glados2(any.list(any.intInRange(1, 4)), any.list(any.intInRange(1, 4))).test(
    'merge is commutative and idempotent',
    (left, right) {
      VersionVector build(List<int> seeds) => seeds.fold(
        VersionVector.empty,
        (version, seed) => version.increment(memberOf(seed)),
      );
      final x = build(left);
      final y = build(right);

      expect(x.merge(y), y.merge(x));
      expect(x.merge(x), x);
    },
  );

  test('round-trips through its canonical wire form', () {
    final version = VersionVector.empty.increment(b).increment(a);

    expect(VersionVector.parse(version.toBytes()), version);
    expect(
      version.toBytes(),
      VersionVector.empty.increment(a).increment(b).toBytes(),
      reason: 'canonical: the same vector always has the same bytes',
    );
  });

  group('adversary', () {
    test('malformed wire forms are refused', () {
      final wire = VersionVector.empty.increment(a).increment(b).toBytes();
      for (final bad in [
        wire.sublist(0, wire.length - 1),
        [...wire, 0],
        [0, 3, ...wire.sublist(2)],
        // Entries out of canonical order would let two encodings sign as one.
        [0, 2, ...wire.sublist(2 + 36), ...wire.sublist(2, 2 + 36)],
      ]) {
        expect(
          () => VersionVector.parse(bad),
          throwsA(isA<MalformedSyncDataException>()),
        );
      }
    });

    test('a zero counter is refused, so equal vectors encode equally', () {
      final wire = VersionVector.empty.increment(a).toBytes();
      wire.fillRange(wire.length - 4, wire.length, 0);

      expect(
        () => VersionVector.parse(wire),
        throwsA(isA<MalformedSyncDataException>()),
      );
    });
  });
}
