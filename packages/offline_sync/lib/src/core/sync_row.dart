import 'package:collaboration_access_control/collaboration_access_control.dart';
import 'package:meta/meta.dart';

import 'record_revision.dart';

/// A record as the sync server and the local database hold it: the id in
/// clear, everything else sealed under the GroupKey.
@immutable
final class SealedRow {
  const SealedRow({required this.record, required this.ciphertext});

  final RecordId record;
  final WorkspaceCiphertext ciphertext;

  @override
  bool operator ==(Object other) =>
      other is SealedRow &&
      other.record == record &&
      other.ciphertext == ciphertext;

  @override
  int get hashCode => Object.hash(record, ciphertext);
}

/// A row as pulled from the server's append-only log, with its position.
@immutable
final class PulledRow {
  const PulledRow({required this.cursor, required this.row});

  final int cursor;
  final SealedRow row;
}
