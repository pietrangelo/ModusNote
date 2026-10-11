import 'dart:typed_data';

import 'package:collaboration_access_control/collaboration_access_control.dart';
import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:meta/meta.dart';

import 'sync_exception.dart';
import 'wire.dart';

enum Causality { before, equal, after, concurrent }

/// How many edits each device had made to a record when a revision was
/// written: tells "one replaces the other" apart from "written without
/// knowing about each other".
@immutable
final class VersionVector {
  VersionVector._(Map<MemberId, int> counters)
    : _counters = Map.unmodifiable(counters);

  factory VersionVector.parse(List<int> wire) {
    final reader = WireReader(wire);
    final version = read(reader);
    reader.finish();
    return version;
  }

  /// Reads one vector from [reader]; entries must be in canonical order
  /// with positive counters, so a vector has exactly one encoding.
  static VersionVector read(WireReader reader) {
    final count = reader.uint16();
    final counters = <MemberId, int>{};
    String? previous;
    for (var i = 0; i < count; i++) {
      final member = MemberId(
        PublicSigningKey.fromBytes(reader.bytes(PublicSigningKey.length)),
      );
      final counter = reader.uint32();
      if (counter == 0 ||
          (previous != null && member.hex.compareTo(previous) <= 0)) {
        throw const MalformedSyncDataException('non-canonical version');
      }
      previous = member.hex;
      counters[member] = counter;
    }
    return VersionVector._(counters);
  }

  static final empty = VersionVector._(const {});

  final Map<MemberId, int> _counters;

  int counterOf(MemberId member) => _counters[member] ?? 0;

  VersionVector increment(MemberId member) =>
      VersionVector._({..._counters, member: counterOf(member) + 1});

  VersionVector merge(VersionVector other) => VersionVector._({
    for (final member in {..._counters.keys, ...other._counters.keys})
      member: _max(counterOf(member), other.counterOf(member)),
  });

  Causality compareTo(VersionVector other) {
    var behind = false;
    var ahead = false;
    for (final member in {..._counters.keys, ...other._counters.keys}) {
      final mine = counterOf(member);
      final theirs = other.counterOf(member);
      if (mine < theirs) behind = true;
      if (mine > theirs) ahead = true;
    }
    return switch ((behind, ahead)) {
      (false, false) => Causality.equal,
      (true, false) => Causality.before,
      (false, true) => Causality.after,
      (true, true) => Causality.concurrent,
    };
  }

  void write(WireWriter writer) {
    final members = _counters.keys.toList()
      ..sort((x, y) => x.hex.compareTo(y.hex));
    writer.uint16(members.length);
    for (final member in members) {
      writer
        ..bytes(member.signingKey.bytes)
        ..uint32(_counters[member]!);
    }
  }

  Uint8List toBytes() {
    final writer = WireWriter();
    write(writer);
    return writer.take();
  }

  static int _max(int a, int b) => a > b ? a : b;

  @override
  bool operator ==(Object other) =>
      other is VersionVector && compareTo(other) == Causality.equal;

  @override
  int get hashCode => Object.hashAllUnordered(
    _counters.entries.map((entry) => Object.hash(entry.key, entry.value)),
  );
}
