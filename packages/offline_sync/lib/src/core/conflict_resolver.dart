import 'package:meta/meta.dart';

import 'record_revision.dart';
import 'version_vector.dart';

@immutable
final class Resolution {
  const Resolution({
    required this.winner,
    required this.seen,
    required this.concurrent,
    required this.changed,
  });

  final SignedRevision winner;

  /// Every edit known for the record; the next local edit builds on it, so
  /// it replaces both sides of a conflict rather than racing them again.
  final VersionVector seen;

  /// The two revisions were written without knowing about each other.
  final bool concurrent;

  /// The winner is the incoming revision, so the local copy must change.
  final bool changed;
}

/// Last-writer-wins on version vectors.
///
/// A revision that causally follows another replaces it. Concurrent ones
/// are ordered by `writtenAt`, then by author key, which every device sees
/// identically inside the signed revision, so all devices converge on the
/// same winner without talking to each other.
abstract final class ConflictResolver {
  static Resolution resolve(SignedRevision local, SignedRevision incoming) {
    final mine = local.revision;
    final theirs = incoming.revision;
    final causality = mine.version.compareTo(theirs.version);
    final takeIncoming = switch (causality) {
      Causality.before => true,
      Causality.after || Causality.equal => false,
      Causality.concurrent => _laterWins(theirs, mine),
    };
    return Resolution(
      winner: takeIncoming ? incoming : local,
      seen: mine.version.merge(theirs.version),
      concurrent: causality == Causality.concurrent,
      changed: takeIncoming,
    );
  }

  static bool _laterWins(RecordRevision a, RecordRevision b) {
    final byTime = a.writtenAt.compareTo(b.writtenAt);
    if (byTime != 0) return byTime > 0;
    return a.author.hex.compareTo(b.author.hex) > 0;
  }
}
