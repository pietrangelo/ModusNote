import 'dart:math';

import 'package:offline_sync/offline_sync.dart';
import 'package:test/test.dart';

void main() {
  final random = Random(7);

  test('a device starts with its first vault, unnamed', () {
    final shelf = VaultShelf.initial();

    expect(shelf.entries, [ShelfEntry(id: ShelfId.first, scope: 0)]);
    expect(shelf.current.id, ShelfId.first);
  });

  test('a new vault gets its own id and scope and opens next', () {
    final (shelf, added) = VaultShelf.initial().add(' Condiviso ', random);

    expect(added.label, 'Condiviso');
    expect(added.id, isNot(ShelfId.first));
    expect(added.scope, 1);
    expect(shelf.current, added);
    expect(shelf.entries.first.id, ShelfId.first);
  });

  test('a scope freed by a removed vault is reused, never shared', () {
    var shelf = VaultShelf.initial();
    final ShelfEntry a;
    final ShelfEntry b;
    (shelf, a) = shelf.add('A', random);
    (shelf, b) = shelf.add('B', random);
    shelf = shelf.remove(a.id);
    final (after, c) = shelf.add('C', random);

    expect(c.scope, a.scope);
    expect(after.entries.map((e) => e.scope).toSet(), hasLength(3));
    expect(after.entries.map((e) => e.id), [ShelfId.first, b.id, c.id]);
  });

  test('removing the open vault opens the first one', () {
    final (shelf, added) = VaultShelf.initial().add('A', random);

    expect(shelf.remove(added.id).current.id, ShelfId.first);
  });

  test('the first vault stays', () {
    expect(
      () => VaultShelf.initial().remove(ShelfId.first),
      throwsArgumentError,
    );
  });

  test('renaming keeps id and scope', () {
    final shelf = VaultShelf.initial().rename(ShelfId.first, 'Mie note');

    expect(
      shelf.current,
      ShelfEntry(id: ShelfId.first, label: 'Mie note', scope: 0),
    );
  });

  test('the shelf holds at most maxVaults vaults', () {
    var shelf = VaultShelf.initial();
    for (var i = 1; i < VaultShelf.maxVaults; i++) {
      (shelf, _) = shelf.add('V$i', random);
    }

    expect(
      () => shelf.add('troppo', random),
      throwsA(isA<ShelfFullException>()),
    );
  });

  group('adversary', () {
    test('names that are empty, long or deceptive are refused', () {
      for (final label in ['', '   ', 'a' * 41, 'fdp\u202Eexe', 'a\nb']) {
        expect(
          () => VaultShelf.initial().rename(ShelfId.first, label),
          throwsA(isA<InvalidShelfLabelException>()),
          reason: label,
        );
      }
    });

    test('a stored shelf that does not add up is the first vault alone', () {
      final other = ShelfEntry(
        id: ShelfId.parse('0123456789abcdef'),
        label: 'X',
        scope: 1,
      );
      for (final entries in [
        <ShelfEntry>[],
        [other],
        [ShelfEntry(id: ShelfId.first, scope: 0), other, other],
        [
          ShelfEntry(id: ShelfId.first, scope: 0),
          ShelfEntry(id: ShelfId.parse('fedcba9876543210'), scope: 0),
        ],
      ]) {
        expect(
          VaultShelf.restore(entries, null),
          VaultShelf.initial(),
          reason: '$entries',
        );
      }
    });

    test('a last-opened id not on the shelf opens the first vault', () {
      final shelf = VaultShelf.restore([
        ShelfEntry(id: ShelfId.first, scope: 0),
      ], ShelfId.parse('0123456789abcdef'));

      expect(shelf.current.id, ShelfId.first);
    });

    test('ids that could name another file are refused', () {
      for (final id in ['../vault', 'MAIN', '0123456789ABCDEF', '']) {
        expect(
          () => ShelfId.parse(id),
          throwsA(isA<MalformedSyncDataException>()),
          reason: id,
        );
      }
    });
  });
}
