import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'sync_exception.dart';
import 'wire.dart';

/// How many records of the membership log the person has seen among the
/// notices of a vault; the records after it are new. A device setting,
/// sealed in the vault and never synced.
///
/// Wire: `version(1) | seen(u32)`.
@immutable
final class NoticeMark {
  NoticeMark(this.seen) {
    if (seen < 0 || seen > 0xffffffff) {
      throw const MalformedSyncDataException('notice mark out of range');
    }
  }

  /// Throws [MalformedSyncDataException] for anything but one mark.
  factory NoticeMark.parse(List<int> wire) {
    final reader = WireReader(wire);
    if (reader.uint8() != _version) {
      throw const MalformedSyncDataException('unknown notice mark version');
    }
    final seen = reader.uint32();
    reader.finish();
    return NoticeMark(seen);
  }

  static const _version = 1;

  final int seen;

  Uint8List toBytes() =>
      (WireWriter()
            ..uint8(_version)
            ..uint32(seen))
          .take();

  @override
  bool operator ==(Object other) => other is NoticeMark && other.seen == seen;

  @override
  int get hashCode => seen.hashCode;
}

/// The serials of the service notices the person closed in a vault, so a
/// server that hands one out again gets nothing. A device setting, sealed
/// in the vault and never synced.
///
/// Wire: `version(1) | count(u16) | serial(u32)*`, serials in ascending
/// order.
abstract final class DismissedNotices {
  /// How many serials are kept: the highest, since a notice lasts at most
  /// ninety days and the operator raises the serial for each new one.
  static const maxSerials = 89;
  static const _version = 1;

  /// Throws [MalformedSyncDataException] for a serial out of range.
  static Uint8List encode(Set<int> serials) {
    final sorted = serials.toList()..sort();
    if (sorted.isNotEmpty && (sorted.first < 0 || sorted.last > 0xffffffff)) {
      throw const MalformedSyncDataException('notice serial out of range');
    }
    final kept = sorted.length > maxSerials
        ? sorted.sublist(sorted.length - maxSerials)
        : sorted;
    final writer = WireWriter()
      ..uint8(_version)
      ..uint16(kept.length);
    for (final serial in kept) {
      writer.uint32(serial);
    }
    return writer.take();
  }

  /// Throws [MalformedSyncDataException] for anything [encode] would not
  /// write.
  static Set<int> parse(List<int> wire) {
    final reader = WireReader(wire);
    if (reader.uint8() != _version) {
      throw const MalformedSyncDataException('unknown dismissed version');
    }
    final count = reader.uint16();
    if (count > maxSerials) {
      throw const MalformedSyncDataException('too many dismissed notices');
    }
    final serials = <int>{};
    var last = -1;
    for (var i = 0; i < count; i++) {
      final serial = reader.uint32();
      if (serial <= last) {
        throw const MalformedSyncDataException('dismissed serials not sorted');
      }
      serials.add(serial);
      last = serial;
    }
    reader.finish();
    return serials;
  }
}
