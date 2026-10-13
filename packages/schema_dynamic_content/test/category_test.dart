import 'dart:convert';

import 'package:glados/glados.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

CategoryId id(String value) => CategoryId(value);

NoteCategory cat(String value, {String? parent, String? name}) => NoteCategory(
  id: id(value),
  name: CategoryName(name ?? value),
  parent: parent == null ? null : id(parent),
);

void main() {
  group('CategoryName', () {
    test('is trimmed and kept as written', () {
      expect(CategoryName('  Romanzi gialli ').value, 'Romanzi gialli');
    });

    test('refuses empty, too long and unsafe names', () {
      for (final bad in [
        '',
        '   ',
        'x' * (CategoryName.maxLength + 1),
        'riga\nnuova',
        'tab\there',
        'fdp\u202Eexe',
      ]) {
        expect(
          () => CategoryName(bad),
          throwsA(isA<InvalidValueException>()),
          reason: jsonEncode(bad),
        );
      }
      expect(CategoryName('é' * CategoryName.maxLength).value.length, 80);
    });
  });

  group('NoteCategory', () {
    test('cannot be its own parent', () {
      expect(
        () => cat('a', parent: 'a'),
        throwsA(isA<InvalidValueException>()),
      );
    });

    test('renamed and moved keep everything else', () {
      final a = NoteCategory(
        id: id('a'),
        name: CategoryName('A'),
        icon: NoteIcon.book,
        tint: NoteTint.rose,
      );
      final renamed = a.renamed(CategoryName('B'));
      expect(renamed.name.value, 'B');
      expect(renamed.icon, NoteIcon.book);
      expect(renamed.tint, NoteTint.rose);
      final moved = a.movedTo(id('p'));
      expect(moved.parent, id('p'));
      expect(moved.name, a.name);
      expect(moved.movedTo(null).parent, isNull);
    });
  });

  group('CategoryTree', () {
    test('lists roots and children by name, ignoring case', () {
      final tree = CategoryTree([
        cat('1', name: 'zeta'),
        cat('2', name: 'Alfa'),
        cat('3', name: 'beta', parent: '2'),
        cat('4', name: 'Aldo', parent: '2'),
      ]);
      expect(tree.roots.map((c) => c.name.value), ['Alfa', 'zeta']);
      expect(tree.childrenOf(id('2')).map((c) => c.name.value), [
        'Aldo',
        'beta',
      ]);
      expect(tree.ordered.map((c) => (c.name.value, tree.depthOf(c.id))), [
        ('Alfa', 1),
        ('Aldo', 2),
        ('beta', 2),
        ('zeta', 1),
      ]);
    });

    test('gives paths and subtrees', () {
      final tree = CategoryTree([
        cat('a'),
        cat('b', parent: 'a'),
        cat('c', parent: 'b'),
        cat('d', parent: 'a'),
      ]);
      expect(tree.pathTo(id('c')).map((c) => c.id), [
        id('a'),
        id('b'),
        id('c'),
      ]);
      expect(tree.subtree(id('b')), {id('b'), id('c')});
      expect(tree.subtree(id('a')), {id('a'), id('b'), id('c'), id('d')});
      expect(tree.subtree(id('missing')), isEmpty);
      expect(tree.parentOf(id('c')), id('b'));
    });

    test('a category whose parent is gone becomes a root', () {
      final tree = CategoryTree([cat('a', parent: 'deleted')]);
      expect(tree.roots.single.id, id('a'));
      expect(tree.parentOf(id('a')), isNull);
      expect(tree.depthOf(id('a')), 1);
    });

    test('a cycle from two devices moving at once is cut at its least id', () {
      // Device 1 moved a under b while device 2 moved b under a.
      final tree = CategoryTree([cat('b', parent: 'a'), cat('a', parent: 'b')]);
      expect(tree.roots.map((c) => c.id), [id('a')]);
      expect(tree.parentOf(id('b')), id('a'));

      final longer = CategoryTree([
        cat('c', parent: 'b'),
        cat('b', parent: 'a'),
        cat('a', parent: 'c'),
        cat('x', parent: 'c'),
      ]);
      expect(longer.roots.map((c) => c.id), [id('a')]);
      expect(longer.depthOf(id('x')), 4);
    });

    test('never deeper than maxDepth, even after concurrent moves', () {
      // Two chains of four, each allowed alone, joined by another device.
      final tree = CategoryTree([
        cat('a1'),
        cat('a2', parent: 'a1'),
        cat('a3', parent: 'a2'),
        cat('a4', parent: 'a3'),
        cat('b1', parent: 'a4'),
        cat('b2', parent: 'b1'),
      ]);
      for (final category in tree.ordered) {
        expect(tree.depthOf(category.id), lessThanOrEqualTo(4));
      }
      // Hung under the deepest ancestor that still has room.
      expect(tree.parentOf(id('b1')), id('a3'));
      expect(tree.parentOf(id('b2')), id('a3'));
    });

    test('a chain of any length from a hostile member is settled', () {
      const length = 200000;
      final tree = CategoryTree([
        for (var i = 0; i < length; i++)
          cat('c$i', parent: i == 0 ? null : 'c${i - 1}'),
        cat('loop', parent: 'c${length - 1}'),
      ]);
      expect(tree.length, length + 1);
      expect(tree.depthOf(CategoryId('c${length - 1}')), CategoryTree.maxDepth);
      expect(tree.pathTo(CategoryId('loop')), hasLength(CategoryTree.maxDepth));
    });

    test('refuses a parent that would loop or go too deep', () {
      final tree = CategoryTree([
        cat('a'),
        cat('b', parent: 'a'),
        cat('c', parent: 'b'),
        cat('d', parent: 'c'),
        cat('x'),
        cat('y', parent: 'x'),
      ]);
      expect(tree.canPlace(null), isTrue);
      expect(tree.canPlace(id('c')), isTrue);
      expect(tree.canPlace(id('d')), isFalse, reason: 'a fifth level');
      expect(tree.canPlace(id('missing')), isFalse);
      expect(tree.canPlace(id('b'), moving: id('a')), isFalse, reason: 'loop');
      expect(tree.canPlace(id('a'), moving: id('a')), isFalse);
      expect(tree.canPlace(id('b'), moving: id('x')), isTrue);
      expect(tree.canPlace(id('c'), moving: id('x')), isFalse, reason: 'deep');
      expect(tree.canPlace(null, moving: id('b')), isTrue);
    });

    test('resolves a note category only while it exists', () {
      final tree = CategoryTree([cat('a')]);
      expect(tree.resolve(id('a')), id('a'));
      expect(tree.resolve(id('gone')), isNull);
      expect(tree.resolve(null), isNull);
    });

    test('a duplicate id keeps one category', () {
      final tree = CategoryTree([cat('a', name: 'one'), cat('a', name: 'two')]);
      expect(tree.ordered, hasLength(1));
    });

    Glados(
      any.listWithLengthInRange(
        0,
        24,
        any.combine2(any.intInRange(0, 12), any.intInRange(-1, 12), (a, b) {
          return (a, b);
        }),
      ),
    ).test('any parent graph is a forest within maxDepth', (pairs) {
      final tree = CategoryTree([
        for (final (self, parent) in pairs)
          if (self != parent)
            cat('c$self', parent: parent < 0 ? null : 'c$parent'),
      ]);
      final seen = <CategoryId>{};
      for (final category in tree.ordered) {
        expect(seen.add(category.id), isTrue);
        final depth = tree.depthOf(category.id);
        expect(depth, inInclusiveRange(1, CategoryTree.maxDepth));
        expect(tree.pathTo(category.id), hasLength(depth));
      }
      expect(seen, hasLength(tree.length));
    });
  });

  group('CategoryCodec', () {
    final full = NoteCategory(
      id: id('0123456789abcdef0123456789abcdef'),
      name: CategoryName('Manuali «tecnici» ♯'),
      parent: id('fedcba9876543210fedcba9876543210'),
      icon: NoteIcon.book,
      tint: NoteTint.cyan,
    );

    test('round-trips', () {
      expect(CategoryCodec.decode(CategoryCodec.encode(full)), full);
      final bare = cat('a');
      expect(CategoryCodec.decode(CategoryCodec.encode(bare)), bare);
    });

    test('is told apart from other records by its first byte', () {
      final bytes = CategoryCodec.encode(full);
      expect(CategoryCodec.isCategory(bytes), isTrue);
      expect(CategoryCodec.isCategory([1, 0, 0]), isFalse);
      expect(CategoryCodec.isCategory([]), isFalse);
    });

    test('ignores icon and tint names from a newer app', () {
      final bytes = [
        CategoryCodec.recordKind,
        ...utf8.encode(
          jsonEncode({
            'format': 1,
            'id': 'a',
            'name': 'A',
            'icon': 'rocket',
            'tint': 'teal',
          }),
        ),
      ];
      final decoded = CategoryCodec.decode(bytes);
      expect(decoded.icon, isNull);
      expect(decoded.tint, isNull);
    });

    test('throws only CategoryFormatException on hostile input', () {
      List<int> doc(Object json) => [
        CategoryCodec.recordKind,
        ...utf8.encode(jsonEncode(json)),
      ];
      final hostile = <List<int>>[
        [],
        [1],
        [CategoryCodec.recordKind],
        [CategoryCodec.recordKind, 0xFF, 0xFE],
        doc([]),
        doc({'format': 2, 'id': 'a', 'name': 'A'}),
        doc({'format': 1, 'id': 'a'}),
        doc({'format': 1, 'id': 'a', 'name': ''}),
        doc({'format': 1, 'id': 'a', 'name': 'A\u202E'}),
        doc({'format': 1, 'id': 'a b', 'name': 'A'}),
        doc({'format': 1, 'id': 'a', 'name': 'A', 'parent': 'a'}),
        doc({'format': 1, 'id': 'a', 'name': 'A', 'parent': 7}),
        doc({'format': 1, 'id': 'a', 'name': 'A', 'extra': true}),
        doc({'format': 1, 'id': 'a', 'name': 'A', 'icon': 3}),
        [CategoryCodec.recordKind, ...utf8.encode('[' * 100000)],
        [CategoryCodec.recordKind, ...List.filled(CategoryCodec.maxLength, 32)],
      ];
      for (final bytes in hostile) {
        expect(
          () => CategoryCodec.decode(bytes),
          throwsA(isA<CategoryFormatException>()),
          reason: bytes.take(40).toString(),
        );
      }
    });

    Glados(any.list(any.uint8)).test('random bytes never throw anything '
        'but CategoryFormatException', (bytes) {
      try {
        CategoryCodec.decode([CategoryCodec.recordKind, ...bytes]);
      } on CategoryFormatException {
        // expected
      }
    });
  });
}
