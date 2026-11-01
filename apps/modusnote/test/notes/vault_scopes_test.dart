import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modusnote/notes/note_editor.dart';
import 'package:modusnote/notes/note_library.dart';
import 'package:modusnote/notes/note_store.dart';
import 'package:modusnote/publishing/publish_sheet.dart';
import 'package:publishing/publishing.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import 'harness.dart';

/// Nothing is published here: the editor only has to know it may.
final class _Unused
    implements SiteGateway, SiteKeys, SiteBookStore, PublicationMedia {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

void main() {
  late InMemoryNoteStore store;
  final unused = _Unused();
  final access = PublishingAccess(
    publisher: Publisher(
      gateway: unused,
      keys: unused,
      books: unused,
      media: unused,
      isConfirmed: () => false,
    ),
    confirm: () async => false,
  );

  setUp(() async {
    store = InMemoryNoteStore();
    await store.save(switch (DynamicEntry.create(
      schema: SeedSchemas.quickNoteV1,
      id: EntryId('n'),
      attributes: {FieldKey('content'): const TextValue('Idea per un riff')},
      at: DateTime.utc(2026, 11, 1, 9),
    )) {
      Valid(:final value) => value,
      Invalid(:final violations) => throw StateError('$violations'),
    });
  });

  Future<void> open(WidgetTester tester, {Size? size}) => pumpApp(
    tester,
    PublishingScope(
      access: access,
      child: NoteLibraryScreen(schemas: SeedSchemas.all, store: store),
    ),
    size: size ?? const Size(360, 780),
  );

  testWidgets('on a phone, a note opened from the list can be published', (
    tester,
  ) async {
    await open(tester);

    await tester.tap(find.text('Idea per un riff'));
    await tester.pumpAndSettle();

    expect(find.byType(NoteEditorScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('publish-note')), findsOneWidget);
  });

  testWidgets('beside the list too', (tester) async {
    await open(tester, size: const Size(1440, 900));

    await tester.tap(find.text('Idea per un riff'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('publish-note')), findsOneWidget);
  });
}
