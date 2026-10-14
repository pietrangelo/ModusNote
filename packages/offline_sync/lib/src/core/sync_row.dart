import 'package:collaboration_access_control/collaboration_access_control.dart';
import 'package:meta/meta.dart';

import 'record_revision.dart';
import 'sync_exception.dart';

/// A record as the sync server and the local database hold it: the id in
/// clear, everything else sealed under the GroupKey.
@immutable
final class SealedRow {
  SealedRow({
    required this.record,
    required this.ciphertext,
    this.supersedes = 0,
  }) {
    if (supersedes < 0) {
      throw const MalformedSyncDataException('negative supersedes');
    }
  }

  final RecordId record;
  final WorkspaceCiphertext ciphertext;

  /// On a row this device pushes: the server position up to which every
  /// row of [record] is superseded by this one, so the server may drop
  /// them. Its writer had merged them all into the version this revision
  /// builds on, except rows it could not open, which it stops before. Zero
  /// supersedes nothing. In clear, like the record id and the position.
  final int supersedes;

  @override
  bool operator ==(Object other) =>
      other is SealedRow &&
      other.record == record &&
      other.ciphertext == ciphertext &&
      other.supersedes == supersedes;

  @override
  int get hashCode => Object.hash(record, ciphertext, supersedes);
}

/// A row as pulled from the server's append-only log, with its position.
@immutable
final class PulledRow {
  const PulledRow({required this.cursor, required this.row});

  final int cursor;
  final SealedRow row;
}
