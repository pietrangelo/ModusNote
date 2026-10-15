import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:modusnote/bootstrap/vault_wiring.dart';
import 'package:offline_sync/offline_sync.dart';

void main() {
  test('the first vault keeps the storage the app always used', () {
    final names = vaultStorageNames(ShelfId.first);
    expect(names.database, 'vault.sqlite');
    expect(names.blobs, 'blobs');
  });

  test('every other vault has storage of its own', () {
    final id = ShelfId.random(Random(7));
    final names = vaultStorageNames(id);
    expect(names.database, 'vault-$id.sqlite');
    expect(names.blobs, 'blobs-$id');
    expect(names.database, isNot(shelfDatabaseName));
  });
}
