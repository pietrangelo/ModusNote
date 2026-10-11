import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modusnote/notes/markdown/markdown_document.dart';
import 'package:modusnote/notes/markdown/markdown_view.dart';

import '../harness.dart';

Future<void> show(WidgetTester tester, String source) => pumpApp(
  tester,
  Scaffold(
    body: SingleChildScrollView(
      child: MarkdownView(document: MarkdownDocument.parse(source)),
    ),
  ),
);

String allText(WidgetTester tester) => tester
    .widgetList<RichText>(find.byType(RichText))
    .map((text) => text.text.toPlainText())
    .join('\n');

void main() {
  testWidgets('every kind of block is drawn', (tester) async {
    await show(
      tester,
      '# Titolo\n\n## Sotto\n\ntesto **forte**\n\n'
      '1. uno\n2. due\n\n- [ ] da fare\n- [x] fatto\n\n'
      '> citazione\n\n```\ncodice\n```\n\n---',
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Titolo'), findsOneWidget);
    expect(find.text('1.'), findsOneWidget);
    expect(find.text('2.'), findsOneWidget);
    expect(find.byKey(const ValueKey('task-open')), findsOneWidget);
    expect(find.byKey(const ValueKey('task-done')), findsOneWidget);
    expect(find.text('codice'), findsOneWidget);
    expect(find.byType(Divider), findsOneWidget);
    expect(allText(tester), contains('citazione'));
  });

  testWidgets('strong text is set heavier on the variable font axis', (
    tester,
  ) async {
    await show(tester, 'a **b**');

    // visitChildren skips spans without text of their own, so walk by hand.
    TextSpan? strong;
    void walk(InlineSpan span) {
      if (span is! TextSpan) return;
      final children = span.children ?? const <InlineSpan>[];
      if (children.any((c) => c is TextSpan && c.text == 'b')) strong = span;
      children.forEach(walk);
    }

    walk(tester.widget<RichText>(find.byType(RichText)).text);
    final span = strong!;
    expect(span.style!.fontWeight, FontWeight.w700);
    expect(span.style!.fontVariations, [const FontVariation.weight(700)]);
  });

  group('adversary', () {
    testWidgets('links show their address and cannot be opened', (
      tester,
    ) async {
      await show(tester, '[banca](https://phish.example/login)');

      expect(allText(tester), 'banca (https://phish.example/login)');
      expect(find.byType(InkWell), findsNothing);
      expect(find.byType(GestureDetector).hitTestable(), findsNothing);
    });

    testWidgets('images are never loaded, only named', (tester) async {
      final semantics = tester.ensureSemantics();
      await show(tester, '![traccia](https://tracker.example/pixel.png)');

      expect(find.byType(Image), findsNothing);
      expect(
        find.bySemanticsLabel(RegExp('Immagine non caricata')),
        findsOneWidget,
      );
      expect(allText(tester), contains('traccia'));
      expect(allText(tester), isNot(contains('tracker.example')));
      semantics.dispose();
    });

    testWidgets('the largest note renders on a phone without overflow', (
      tester,
    ) async {
      final chunk = '# T\n- [x] **a** `b` [c](d)\n> e\n\n';
      await show(tester, chunk * (100000 ~/ chunk.length));

      expect(tester.takeException(), isNull);
    });

    testWidgets('a long unbroken code line scrolls instead of overflowing', (
      tester,
    ) async {
      await show(tester, '```\n${'x' * 2000}\n```');

      expect(tester.takeException(), isNull);
    });
  });
}
