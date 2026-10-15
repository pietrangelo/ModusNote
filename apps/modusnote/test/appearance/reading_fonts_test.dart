import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modusnote/appearance/appearance_scope.dart';
import 'package:modusnote/appearance/page_appearance.dart';
import 'package:modusnote/appearance/reading_fonts.dart';

void main() {
  test('a typeface is loaded once, however often it is asked for', () async {
    final loads = <PageFont>[];
    final fonts = ReadingFonts(load: (font) async => loads.add(font));
    expect(fonts.isReady(PageFont.inter), isTrue);
    expect(fonts.isReady(PageFont.literata), isFalse);

    await Future.wait([
      fonts.ensure(PageFont.literata),
      fonts.ensure(PageFont.literata),
    ]);
    await fonts.ensure(PageFont.literata);

    expect(loads, [PageFont.literata]);
    expect(fonts.isReady(PageFont.literata), isTrue);
  });

  test('a failed load keeps the body font and can be tried again', () async {
    var fail = true;
    final fonts = ReadingFonts(
      load: (font) async {
        if (fail) throw FlutterError('damaged asset');
      },
    );
    await fonts.ensure(PageFont.quattro);
    expect(fonts.isReady(PageFont.quattro), isFalse);

    fail = false;
    await fonts.ensure(PageFont.quattro);
    expect(fonts.isReady(PageFont.quattro), isTrue);
  });

  test('the page shows the body font until the chosen one is loaded', () async {
    final pending = <PageFont, void Function()>{};
    final fonts = ReadingFonts(
      load: (font) {
        final done = Completer<void>();
        pending[font] = done.complete;
        return done.future;
      },
    );
    final settings = AppearanceSettings(fonts: fonts);
    var notified = 0;
    settings.addListener(() => notified++);

    settings.page = const PageAppearance(font: PageFont.atkinson);
    expect(settings.shownFont, PageFont.inter);

    pending[PageFont.atkinson]!();
    await pumpEventQueue();
    expect(settings.shownFont, PageFont.atkinson);
    expect(notified, 2);
  });

  testWidgets('the bundled typefaces load from the app\'s own assets', (
    tester,
  ) async {
    final fonts = ReadingFonts();
    await tester.runAsync(() async {
      for (final font in PageFont.values) {
        await fonts.ensure(font);
      }
    });
    for (final font in PageFont.values) {
      expect(fonts.isReady(font), isTrue, reason: '$font');
    }
  });
}
