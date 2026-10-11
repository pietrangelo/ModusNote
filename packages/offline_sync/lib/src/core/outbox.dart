import 'package:meta/meta.dart';

import 'sync_row.dart';

/// Rows written locally and not yet acknowledged by the server.
///
/// Offline edits pile up here already signed and sealed, so the local
/// database never holds them in clear, and are pushed in the order they were
/// written once the server is reachable.
@immutable
final class Outbox {
  Outbox._(List<SealedRow> pending) : pending = List.unmodifiable(pending);

  static final empty = Outbox._(const []);

  final List<SealedRow> pending;

  /// Only the latest revision of a record needs pushing: it carries the
  /// version of everything before it.
  Outbox enqueue(SealedRow row) {
    final index = pending.indexWhere((queued) => queued.record == row.record);
    if (index == -1) return Outbox._([...pending, row]);
    return Outbox._([...pending]..[index] = row);
  }

  Outbox acknowledge(Iterable<SealedRow> pushed) {
    final done = pushed.toSet();
    return Outbox._([
      for (final row in pending)
        if (!done.contains(row)) row,
    ]);
  }
}
