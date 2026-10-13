import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'json_reader.dart';
import 'schema_definition.dart';
import 'schema_exception.dart';
import 'unsafe_text.dart';

final _opaqueId = RegExp(r'^[A-Za-z0-9_-]{1,128}$');

/// Identifies a category. Opaque and random, like an entry id: the vault
/// stores each category in a record named by it.
@immutable
final class CategoryId {
  CategoryId(this.value) {
    if (!_opaqueId.hasMatch(value)) {
      throw const InvalidValueException('malformed category id');
    }
  }

  final String value;

  @override
  bool operator ==(Object other) => other is CategoryId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// What the user calls a category: one line, trimmed, without characters
/// that make it render differently from what it holds.
@immutable
final class CategoryName {
  factory CategoryName(String text) {
    final trimmed = text.trim();
    final length = trimmed.runes.length;
    if (length == 0 || length > maxLength) {
      throw const InvalidValueException('category name length');
    }
    if (containsUnsafeCharacters(trimmed)) {
      throw const InvalidValueException('category name characters');
    }
    return CategoryName._(trimmed);
  }

  const CategoryName._(this.value);

  static const maxLength = 80;

  final String value;

  @override
  bool operator ==(Object other) =>
      other is CategoryName && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// A place to file notes in, possibly inside another category. A note is
/// in at most one category; tags stay for groupings across them.
///
/// Name, parent, icon and tint are all inside the sealed record: the
/// server sees neither the tree nor which notes are in it.
@immutable
final class NoteCategory {
  NoteCategory({
    required this.id,
    required this.name,
    this.parent,
    this.icon,
    this.tint,
  }) {
    if (parent == id) {
      throw const InvalidValueException('a category in itself');
    }
  }

  final CategoryId id;
  final CategoryName name;

  /// The category this one is inside; null at the top.
  final CategoryId? parent;
  final NoteIcon? icon;
  final NoteTint? tint;

  NoteCategory renamed(CategoryName name) =>
      NoteCategory(id: id, name: name, parent: parent, icon: icon, tint: tint);

  NoteCategory movedTo(CategoryId? parent) =>
      NoteCategory(id: id, name: name, parent: parent, icon: icon, tint: tint);

  NoteCategory styled({NoteIcon? icon, NoteTint? tint}) =>
      NoteCategory(id: id, name: name, parent: parent, icon: icon, tint: tint);

  @override
  bool operator ==(Object other) =>
      other is NoteCategory &&
      other.id == id &&
      other.name == name &&
      other.parent == parent &&
      other.icon == icon &&
      other.tint == tint;

  @override
  int get hashCode => Object.hash(id, name, parent, icon, tint);
}

/// The categories of a vault as a forest, whatever their records say.
///
/// Each device keeps the tree sound when it edits it, but two devices
/// editing at once can still produce a parent that is gone, a loop (one
/// moves a under b while the other moves b under a) or a chain deeper than
/// [maxDepth]. The tree repairs each the same way on every device: a
/// missing parent makes a root, a loop is cut at its least id, and a
/// category too deep hangs from its deepest ancestor that has room.
/// Nothing is written back: the records stay as they are until edited.
final class CategoryTree {
  factory CategoryTree(Iterable<NoteCategory> categories) {
    final byId = <CategoryId, NoteCategory>{};
    for (final category in categories) {
      byId[category.id] = category;
    }
    final parents = <CategoryId, CategoryId?>{
      for (final category in byId.values)
        category.id: byId.containsKey(category.parent) ? category.parent : null,
    };
    _cutLoops(parents);
    final depths = <CategoryId, int>{};
    final ids = byId.keys.toList()..sort(_byValue);
    for (final id in ids) {
      _settle(id, parents, depths);
    }
    final children = <CategoryId?, List<NoteCategory>>{};
    for (final category in byId.values) {
      (children[parents[category.id]] ??= []).add(category);
    }
    for (final list in children.values) {
      list.sort(_byName);
    }
    return CategoryTree._(byId, parents, depths, children);
  }

  CategoryTree._(this._byId, this._parents, this._depths, this._children);

  static final empty = CategoryTree(const []);

  /// Levels a tree may have: deep enough for a book's parts and chapters
  /// inside a shelf, shallow enough to show on a phone.
  static const maxDepth = 4;

  final Map<CategoryId, NoteCategory> _byId;
  final Map<CategoryId, CategoryId?> _parents;
  final Map<CategoryId, int> _depths;
  final Map<CategoryId?, List<NoteCategory>> _children;

  int get length => _byId.length;

  bool get isEmpty => _byId.isEmpty;

  NoteCategory? operator [](CategoryId id) => _byId[id];

  List<NoteCategory> get roots =>
      List.unmodifiable(_children[null] ?? const []);

  List<NoteCategory> childrenOf(CategoryId id) =>
      List.unmodifiable(_children[id] ?? const []);

  /// The parent as this tree places it, which may differ from the record.
  CategoryId? parentOf(CategoryId id) => _parents[id];

  /// 1 at the top; 0 for a category not in the tree.
  int depthOf(CategoryId id) => _depths[id] ?? 0;

  /// Every category, each followed by its children, siblings by name.
  List<NoteCategory> get ordered {
    final out = <NoteCategory>[];
    void visit(CategoryId? parent) {
      for (final category in _children[parent] ?? const <NoteCategory>[]) {
        out.add(category);
        visit(category.id);
      }
    }

    visit(null);
    return out;
  }

  /// From the top down to [id]; empty for a category not in the tree.
  List<NoteCategory> pathTo(CategoryId id) {
    final path = <NoteCategory>[];
    for (CategoryId? at = id; at != null; at = _parents[at]) {
      final category = _byId[at];
      if (category == null) return const [];
      path.add(category);
    }
    return path.reversed.toList();
  }

  /// [id] and everything inside it; empty for a category not in the tree.
  Set<CategoryId> subtree(CategoryId id) {
    if (!_byId.containsKey(id)) return const {};
    final out = <CategoryId>{};
    void visit(CategoryId at) {
      out.add(at);
      for (final child in _children[at] ?? const <NoteCategory>[]) {
        visit(child.id);
      }
    }

    visit(id);
    return out;
  }

  /// Whether a new category ([moving] null), or [moving] with everything
  /// inside it, can go under [parent] (null: the top): no loop, and no
  /// level past [maxDepth].
  bool canPlace(CategoryId? parent, {CategoryId? moving}) {
    final base = parent == null ? 0 : depthOf(parent);
    if (parent != null && base == 0) return false;
    if (moving == null) return base + 1 <= maxDepth;
    final inside = subtree(moving);
    if (inside.isEmpty || (parent != null && inside.contains(parent))) {
      return false;
    }
    final top = depthOf(moving);
    final height = inside.map(depthOf).reduce((a, b) => a > b ? a : b) - top;
    return base + 1 + height <= maxDepth;
  }

  /// The category a note is filed in, if it still exists.
  CategoryId? resolve(CategoryId? id) =>
      id != null && _byId.containsKey(id) ? id : null;

  static int _byValue(CategoryId a, CategoryId b) => a.value.compareTo(b.value);

  static int _byName(NoteCategory a, NoteCategory b) {
    final byName = a.name.value.toLowerCase().compareTo(
      b.name.value.toLowerCase(),
    );
    return byName != 0 ? byName : _byValue(a.id, b.id);
  }

  /// Every loop is cut at its least id, which becomes a root.
  static void _cutLoops(Map<CategoryId, CategoryId?> parents) {
    final done = <CategoryId>{};
    final ids = parents.keys.toList()..sort(_byValue);
    for (final start in ids) {
      final walk = <CategoryId>[];
      final onWalk = <CategoryId>{};
      CategoryId? at = start;
      while (at != null && !done.contains(at) && onWalk.add(at)) {
        walk.add(at);
        at = parents[at];
      }
      if (at != null && onWalk.contains(at)) {
        final loop = walk.sublist(walk.indexOf(at));
        parents[loop.reduce((a, b) => _byValue(a, b) <= 0 ? a : b)] = null;
      }
      done.addAll(walk);
    }
  }

  /// Settles the depth of [id] and of the unsettled ancestors above it,
  /// from the top down, hanging each higher if it would be too deep. A
  /// loop, not a recursion: another member can write a chain of any
  /// length, and the stack must not be what decides how long.
  static void _settle(
    CategoryId id,
    Map<CategoryId, CategoryId?> parents,
    Map<CategoryId, int> depths,
  ) {
    final chain = <CategoryId>[];
    for (CategoryId? at = id; at != null && !depths.containsKey(at);) {
      chain.add(at);
      at = parents[at];
    }
    for (final at in chain.reversed) {
      final parent = parents[at];
      if (parent == null) {
        depths[at] = 1;
        continue;
      }
      var above = parent;
      while (depths[above]! >= maxDepth) {
        above = parents[above]!;
      }
      parents[at] = above;
      depths[at] = depths[above]! + 1;
    }
  }
}

/// A category record that could not be decoded. The only exception
/// [CategoryCodec.decode] lets escape, whatever the input.
final class CategoryFormatException implements Exception {
  const CategoryFormatException(this.message);

  final String message;

  @override
  String toString() => 'CategoryFormatException: $message';
}

/// Bytes form of a [NoteCategory]: `kind(1) | JSON`. The vault keeps notes and
/// categories in records of one kind, so the first byte tells them apart:
/// [recordKind] is not a version any note was ever written with. Decoding
/// treats its input as hostile; names of icons and tints this app does not
/// know (from a newer one) are dropped, as for schemas.
abstract final class CategoryCodec {
  /// 'C', far from the small versions of the note format.
  static const recordKind = 0x43;
  static const maxLength = 4096;
  static const _format = 1;
  static const _properties = {'format', 'id', 'name', 'parent', 'icon', 'tint'};

  static bool isCategory(List<int> bytes) =>
      bytes.isNotEmpty && bytes.first == recordKind;

  static Uint8List encode(NoteCategory category) => Uint8List.fromList([
    recordKind,
    ...utf8.encode(
      jsonEncode({
        'format': _format,
        'id': category.id.value,
        'name': category.name.value,
        'parent': ?category.parent?.value,
        'icon': ?category.icon?.name,
        'tint': ?category.tint?.name,
      }),
    ),
  ]);

  static NoteCategory decode(List<int> bytes) {
    if (!isCategory(bytes)) {
      throw const CategoryFormatException('not a category');
    }
    if (bytes.length > maxLength) {
      throw const CategoryFormatException('record too large');
    }
    try {
      final json = JsonObject.of(
        parseBoundedJson(
          utf8.decode(Uint8List.fromList(bytes).sublist(1)),
          maxDepth: 1,
        ),
        'category',
      )..allowOnly(_properties);
      if (json.integer('format') != _format) {
        throw const CategoryFormatException('unknown category format');
      }
      String? optional(String key) => json.has(key) ? json.string(key) : null;
      final parent = optional('parent');
      final icon = optional('icon');
      final tint = optional('tint');
      return NoteCategory(
        id: CategoryId(json.string('id')),
        name: CategoryName(json.string('name')),
        parent: parent == null ? null : CategoryId(parent),
        icon: NoteIcon.values.asNameMap()[icon],
        tint: NoteTint.values.asNameMap()[tint],
      );
    } on JsonShapeException catch (e) {
      throw CategoryFormatException(e.message);
    } on InvalidValueException catch (e) {
      throw CategoryFormatException(e.message);
    } on FormatException {
      throw const CategoryFormatException('not UTF-8');
    }
  }
}
