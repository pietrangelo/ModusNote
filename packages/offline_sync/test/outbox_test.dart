import 'dart:typed_data';

import 'package:collaboration_access_control/collaboration_access_control.dart';
import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:offline_sync/offline_sync.dart';
import 'package:test/test.dart';

SealedRow row(String id, int marker) => SealedRow(
  record: RecordId.parse(id * 32),
  ciphertext: WorkspaceCiphertext(
    epoch: KeyEpoch.initial,
    envelope: EncryptedEnvelope(
      nonce: Nonce.fromBytes(Uint8List(Nonce.length)),
      ciphertext: List.filled(EncryptedEnvelope.tagLength, marker),
    ),
  ),
);

void main() {
  test('keeps pending rows in the order they were written', () {
    final outbox = Outbox.empty
        .enqueue(row('a', 1))
        .enqueue(row('b', 1))
        .enqueue(row('c', 1));

    expect(outbox.pending, [row('a', 1), row('b', 1), row('c', 1)]);
  });

  test('a newer edit of a queued record replaces it in place', () {
    final outbox = Outbox.empty
        .enqueue(row('a', 1))
        .enqueue(row('b', 1))
        .enqueue(row('a', 2));

    expect(outbox.pending, [row('a', 2), row('b', 1)]);
  });

  test('acknowledging removes only the row that was pushed', () {
    final pushed = row('a', 1);
    final outbox = Outbox.empty.enqueue(pushed).enqueue(row('b', 1));

    expect(outbox.acknowledge([pushed]).pending, [row('b', 1)]);

    // Edited again while the push was in flight: the new edit stays queued.
    final editedMeanwhile = outbox.enqueue(row('a', 2));
    expect(editedMeanwhile.acknowledge([pushed]).pending, [
      row('a', 2),
      row('b', 1),
    ]);
  });

  test('is immutable', () {
    final empty = Outbox.empty;
    empty.enqueue(row('a', 1));

    expect(empty.pending, isEmpty);
    expect(() => empty.pending.add(row('a', 1)), throwsUnsupportedError);
  });
}
