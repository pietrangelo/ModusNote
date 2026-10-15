import 'dart:math';

import 'package:offline_sync/offline_sync.dart';
import 'package:offline_sync_adapters/offline_sync_adapters.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Database database;

  setUp(() => database = sqlite3.openInMemory());
  tearDown(() => database.close());

  test('an empty database is the first vault alone', () async {
    expect(await SqliteShelfStore(database).load(), VaultShelf.initial());
  });

  test('a shelf reads back as it was saved', () async {
    var (shelf, added) = VaultShelf.initial()
        .rename(ShelfId.first, 'Mie note')
        .add('Condiviso', Random(1));
    shelf = shelf.open(ShelfId.first);
    await SqliteShelfStore(database).save(shelf);

    final read = await SqliteShelfStore(database).load();

    expect(read, shelf);
    expect(read[added.id].label, 'Condiviso');
  });

  test('saving again replaces the shelf', () async {
    final (shelf, added) = VaultShelf.initial().add('A', Random(2));
    final store = SqliteShelfStore(database);
    await store.save(shelf);
    await store.save(shelf.remove(added.id));

    expect(await store.load(), VaultShelf.initial());
  });

  group('adversary', () {
    test('rows edited by hand never stop the first vault opening', () async {
      final store = SqliteShelfStore(database);
      final (shelf, _) = VaultShelf.initial().add('A', Random(3));
      await store.save(shelf);
      for (final edit in [
        "UPDATE shelf SET id = '../../etc' WHERE position = 1",
        "UPDATE shelf SET label = '' WHERE position = 1",
        "UPDATE shelf SET scope = 99 WHERE position = 1",
        "UPDATE shelf_state SET value = 'nope'",
      ]) {
        await store.save(shelf);
        database.execute(edit);

        final read = await store.load();
        expect(read.entries.first.id, ShelfId.first, reason: edit);
        expect(
          read == shelf ||
              read == VaultShelf.initial() ||
              read == VaultShelf.restore(shelf.entries, null),
          isTrue,
          reason: edit,
        );
      }
    });
  });
}
