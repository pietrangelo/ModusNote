import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modusnote/appearance/appearance_scope.dart';
import 'package:modusnote/main.dart';
import 'package:modusnote/notes/note_library.dart';
import 'package:modusnote/notes/note_store.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

Widget preview() =>
    NoteLibraryScreen(schemas: SeedSchemas.all, store: InMemoryNoteStore());

void main() {
  testWidgets('ships at least Italian and English', (tester) async {
    await tester.pumpWidget(
      ModusNoteApp(home: preview(), appearance: AppearanceSettings()),
    );

    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    final languages = app.supportedLocales.map((l) => l.languageCode);
    expect(languages, containsAll(<String>['it', 'en']));
  });

  testWidgets('renders Italian strings for an Italian device', (tester) async {
    tester.platformDispatcher.localesTestValue = const [Locale('it')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);

    await tester.pumpWidget(
      ModusNoteApp(home: preview(), appearance: AppearanceSettings()),
    );
    await tester.pumpAndSettle();

    expect(find.text('Cerca nelle note'), findsOneWidget);
  });

  testWidgets('falls back to English for an unsupported locale', (
    tester,
  ) async {
    tester.platformDispatcher.localesTestValue = const [Locale('ja')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);

    await tester.pumpWidget(
      ModusNoteApp(home: preview(), appearance: AppearanceSettings()),
    );
    await tester.pumpAndSettle();

    expect(find.text('Search notes'), findsOneWidget);
  });

  testWidgets('the visible app name is the brand, Modus Notes', (tester) async {
    await tester.pumpWidget(
      ModusNoteApp(home: preview(), appearance: AppearanceSettings()),
    );
    await tester.pumpAndSettle();

    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    final context = tester.element(find.byType(Scaffold));
    expect(app.onGenerateTitle!(context), 'Modus Notes');
  });
}
