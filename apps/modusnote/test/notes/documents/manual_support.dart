import 'package:modusnote/notes/note_store.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import '../books/book_support.dart' show note;

final manual = CategoryId('m' * 32);
final setup = CategoryId('s' * 32);
final advanced = CategoryId('v' * 32);

EntryId page(String two) => EntryId(two * 16);

/// A manual: three pages at the top (titled so that only natural order
/// is right), one in "Installazione", one in "Avanzate" inside it, a quick
/// note filed with them, and a page outside the manual.
Future<InMemoryNoteStore> manualStore() async {
  final store = InMemoryNoteStore();
  await store.saveCategory(
    NoteCategory(id: manual, name: CategoryName('Manuale')),
  );
  await store.saveCategory(
    NoteCategory(
      id: setup,
      name: CategoryName('Installazione'),
      parent: manual,
    ),
  );
  await store.saveCategory(
    NoteCategory(id: advanced, name: CategoryName('Avanzate'), parent: setup),
  );
  Future<void> add(String id, String title, CategoryId? where) => store.save(
    note(SeedSchemas.documentV1, id * 16, {'title': TextValue(title)}),
    newIn: where,
  );
  await add('p3', '10. Domande', manual);
  await add('p1', '1. Introduzione', manual);
  await add('p2', '2. Primi passi', manual);
  await add('p4', 'Requisiti', setup);
  await add('p5', 'Proxy', advanced);
  await add('p6', 'Fuori dal manuale', null);
  await store.save(
    note(SeedSchemas.quickNoteV1, 'q1' * 16, {
      'content': const TextValue('Promemoria'),
    }),
    newIn: manual,
  );
  return store;
}
