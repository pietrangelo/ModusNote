import 'dart:math';

import 'package:meta/meta.dart';

import 'sync_exception.dart';

/// The vaults kept on this device, each with its own database, passphrase,
/// identity and workspace: one's own notes beside a vault someone else
/// shared, for example.
///
/// The shelf is the only thing about them readable before one is unlocked,
/// so it holds nothing but a local id, the name the person gave each vault
/// and a small number that keeps per-vault system resources (reminders)
/// apart. It never leaves the device.
@immutable
final class VaultShelf {
  VaultShelf._(List<ShelfEntry> entries, this.lastOpened)
    : entries = List.unmodifiable(entries);

  /// A device that has never held more than its first vault: the vault the
  /// app always had, kept under its old storage names.
  factory VaultShelf.initial() =>
      VaultShelf._([ShelfEntry(id: ShelfId.first, scope: 0)], ShelfId.first);

  /// Rebuilds a stored shelf; anything inconsistent means storage was
  /// tampered with or damaged, and the first vault alone is shown.
  factory VaultShelf.restore(List<ShelfEntry> entries, ShelfId? lastOpened) {
    final ids = {for (final entry in entries) entry.id};
    final scopes = {for (final entry in entries) entry.scope};
    final valid =
        entries.isNotEmpty &&
        entries.length <= maxVaults &&
        entries.first.id == ShelfId.first &&
        entries.first.scope == 0 &&
        ids.length == entries.length &&
        scopes.length == entries.length;
    if (!valid) return VaultShelf.initial();
    return VaultShelf._(
      entries,
      ids.contains(lastOpened) ? lastOpened! : ShelfId.first,
    );
  }

  /// Enough for any person's use, and it bounds what a device keeps: each
  /// vault is a database and, on a phone, its own notification range.
  static const maxVaults = 20;

  /// In the order they were added; the first vault is always first.
  final List<ShelfEntry> entries;

  /// The vault the app shows at launch.
  final ShelfId lastOpened;

  ShelfEntry operator [](ShelfId id) =>
      entries.firstWhere((entry) => entry.id == id);

  ShelfEntry get current => this[lastOpened];

  /// A new, empty vault named [label], opened next; its database is made
  /// when the person creates or joins a vault there.
  ///
  /// Throws [ShelfFullException] past [maxVaults].
  (VaultShelf, ShelfEntry) add(String label, Random random) {
    if (entries.length >= maxVaults) throw const ShelfFullException();
    final used = {for (final entry in entries) entry.scope};
    final scope = [for (var s = 1; s < maxVaults; s++) s]
        .firstWhere((s) => !used.contains(s));
    ShelfId id;
    do {
      id = ShelfId.random(random);
    } while (entries.any((entry) => entry.id == id));
    final entry = ShelfEntry(id: id, label: label, scope: scope);
    return (VaultShelf._([...entries, entry], id), entry);
  }

  VaultShelf rename(ShelfId id, String label) => VaultShelf._([
    for (final entry in entries)
      entry.id == id
          ? ShelfEntry(id: id, label: label, scope: entry.scope)
          : entry,
  ], lastOpened);

  /// Forgets a vault's place on the shelf. Its storage is the caller's to
  /// clear; the first vault cannot be removed, since its storage names are
  /// the app's original ones.
  VaultShelf remove(ShelfId id) {
    if (id == ShelfId.first) {
      throw ArgumentError.value(id, 'id', 'the first vault stays');
    }
    final rest = [
      for (final entry in entries)
        if (entry.id != id) entry,
    ];
    return VaultShelf._(rest, lastOpened == id ? ShelfId.first : lastOpened);
  }

  VaultShelf open(ShelfId id) => VaultShelf._(entries, this[id].id);

  @override
  bool operator ==(Object other) =>
      other is VaultShelf &&
      other.lastOpened == lastOpened &&
      _sameList(other.entries, entries);

  @override
  int get hashCode => Object.hash(lastOpened, Object.hashAll(entries));
}

bool _sameList<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// A vault's local id: `main` for the first vault, 16 hex digits for the
/// others. It names the vault's database and blob storage on the device.
@immutable
final class ShelfId {
  const ShelfId._(this.value);

  factory ShelfId.parse(String value) {
    if (value != first.value && !_hex.hasMatch(value)) {
      throw const MalformedSyncDataException('malformed shelf id');
    }
    return ShelfId._(value);
  }

  factory ShelfId.random(Random random) => ShelfId._(
    [
      for (var i = 0; i < 8; i++)
        random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ].join(),
  );

  static const first = ShelfId._('main');
  static final _hex = RegExp(r'^[0-9a-f]{16}$');

  final String value;

  @override
  bool operator ==(Object other) => other is ShelfId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// One vault on the shelf.
@immutable
final class ShelfEntry {
  /// [label] is a single line of at most [maxLabel] characters, without
  /// control or bidirectional characters; null for the first vault until
  /// the person names it, which the app shows as its default name.
  ShelfEntry({required this.id, String? label, required this.scope})
    : label = label == null ? null : _label(label) {
    if (scope < 0 || scope >= VaultShelf.maxVaults) {
      throw const MalformedSyncDataException('shelf scope out of range');
    }
  }

  static const maxLabel = 40;

  final ShelfId id;
  final String? label;

  /// Small, unique on the shelf and never reused while the vault is on it;
  /// 0 for the first vault.
  final int scope;

  static String _label(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty ||
        trimmed.runes.length > maxLabel ||
        _unsafe.hasMatch(trimmed)) {
      throw const InvalidShelfLabelException();
    }
    return trimmed;
  }

  // Control and bidirectional formatting characters would let a name
  // render as something else.
  static final _unsafe = RegExp(
    r'[\x00-\x1F\x7F-\x9F\u061C\u200E\u200F\u202A-\u202E\u2066-\u2069]',
  );

  @override
  bool operator ==(Object other) =>
      other is ShelfEntry &&
      other.id == id &&
      other.label == label &&
      other.scope == scope;

  @override
  int get hashCode => Object.hash(id, label, scope);
}
