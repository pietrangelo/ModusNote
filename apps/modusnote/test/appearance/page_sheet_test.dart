import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modusnote/appearance/appearance_scope.dart';
import 'package:modusnote/appearance/page_appearance.dart';
import 'package:modusnote/notes/note_editor.dart';
import 'package:modusnote/notes/note_store.dart';
import 'package:modusnote/theme/golden_ratio.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import '../notes/harness.dart';

const desktop = Size(1920, 1080);

void main() {
  late AppearanceSettings appearance;
  late List<PageAppearance> kept;

  setUp(() {
    appearance = AppearanceSettings();
    kept = [];
    appearance.attach(
      const PageAppearance(),
      persist: (bytes) async => kept.add(PageAppearance.fromBytes(bytes)),
    );
  });

  Future<void> openEditor(
    WidgetTester tester, {
    Size size = const Size(360, 780),
    bool scoped = true,
  }) => pumpApp(
    tester,
    NoteEditorScreen(
      schemas: SeedSchemas.all,
      store: InMemoryNoteStore(),
      initialSchema: SeedSchemas.quickNoteV1,
    ),
    appearance: scoped ? appearance : null,
    size: size,
  );

  double pageWidth(WidgetTester tester) =>
      tester.getSize(find.byKey(const ValueKey('note-page'))).width;

  double drawnBodySize(WidgetTester tester) =>
      MediaQuery.textScalerOf(tester.element(textInput('content')))
          .scale(TypeScale.body);

  group('page width', () {
    testWidgets('a wide window shows a medium page at first, not a phone', (
      tester,
    ) async {
      await openEditor(tester, size: desktop);
      expect(pageWidth(tester), Extents.xxxl);
    });

    testWidgets('each width is the page drawn', (tester) async {
      await openEditor(tester, size: desktop);
      for (final (width, expected) in [
        (PageWidth.narrow, Extents.xxl),
        (PageWidth.medium, Extents.xxxl),
        (PageWidth.wide, Extents.xxxxl),
        (PageWidth.full, desktop.width),
      ]) {
        appearance.page = appearance.page.copyWith(width: width);
        await tester.pumpAndSettle();
        expect(pageWidth(tester), expected, reason: '$width');
      }
    });

    testWidgets('a phone keeps the whole screen whatever was chosen', (
      tester,
    ) async {
      appearance.page = const PageAppearance(width: PageWidth.full);
      await openEditor(tester);
      expect(pageWidth(tester), 360);
    });
  });

  group('the «Aa» sheet', () {
    testWidgets('changes the text of the page at once, and keeps it', (
      tester,
    ) async {
      await openEditor(tester);
      expect(drawnBodySize(tester), 16);

      await tester.tap(find.byTooltip('Aspetto della pagina'));
      await tester.pumpAndSettle();
      expect(find.text('Dimensione del testo'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('page-text-size-20')));
      await tester.pumpAndSettle();

      expect(drawnBodySize(tester), 20);
      expect(kept.last, const PageAppearance(textStep: 2));
    });

    testWidgets('offers the width only on a wide window', (tester) async {
      await openEditor(tester);
      await tester.tap(find.byTooltip('Aspetto della pagina'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('page-width')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('sets the width on a wide window', (tester) async {
      await openEditor(tester, size: desktop);
      await tester.tap(find.byTooltip('Aspetto della pagina'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('page-width-wide')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('page-width-wide')));
      await tester.pumpAndSettle();

      expect(pageWidth(tester), Extents.xxxxl);
      expect(kept.last.width, PageWidth.wide);
    });

    testWidgets('is not offered without settings to keep it in', (
      tester,
    ) async {
      await openEditor(tester, scoped: false);
      expect(find.byTooltip('Aspetto della pagina'), findsNothing);
      expect(drawnBodySize(tester), 16);
    });
  });

  group('typeface', () {
    TextStyle drawnStyle(WidgetTester tester, String key) =>
        tester.widget<EditableText>(textInput(key)).style;

    testWidgets('the note is drawn in the typeface chosen, once loaded', (
      tester,
    ) async {
      await openEditor(tester);
      expect(drawnStyle(tester, 'content').fontFamily, 'Inter');

      await tester.tap(find.byTooltip('Aspetto della pagina'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('page-font-literata')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('page-font-literata')));
      await tester.runAsync(() => appearance.fonts.ensure(PageFont.literata));
      await tester.pumpAndSettle();

      expect(drawnStyle(tester, 'content').fontFamily, 'Literata');
      expect(
        drawnStyle(tester, 'content').fontFamilyFallback,
        contains('Inter'),
      );
      expect(kept.last.font, PageFont.literata);
    });

    testWidgets('a Markdown heading keeps the chosen typeface', (tester) async {
      await tester.runAsync(() => appearance.fonts.ensure(PageFont.literata));
      appearance.page = const PageAppearance(font: PageFont.literata);
      await openEditor(tester);
      await tester.enterText(textInput('content'), '# Capitolo');
      await tester.pumpAndSettle();

      final field = tester.widget<EditableText>(textInput('content'));
      final span = field.controller.buildTextSpan(
        context: tester.element(textInput('content')),
        style: field.style,
        withComposing: false,
      );
      final families = <String?>{};
      span.visitChildren((child) {
        if (child is TextSpan && (child.text ?? '').contains('Capitolo')) {
          families.add(child.style?.fontFamily);
        }
        return true;
      });
      expect(families, {'Literata'});
    });
  });

  test('a closed vault keeps nothing more and goes back to the default', () {
    appearance.page = const PageAppearance(textStep: 4);
    expect(kept, hasLength(1));
    appearance.detach();
    expect(appearance.page, const PageAppearance());
    appearance.page = const PageAppearance(textStep: 3);
    expect(kept, hasLength(1));
  });
}
