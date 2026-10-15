import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:modusnote/appearance/page_appearance.dart';
import 'package:modusnote/theme/golden_ratio.dart';

void main() {
  group('page width', () {
    test('each step is a Fibonacci extent, the last the whole window', () {
      expect(PageWidth.narrow.maxWidth, Extents.xxl);
      expect(PageWidth.medium.maxWidth, Extents.xxxl);
      expect(PageWidth.wide.maxWidth, Extents.xxxxl);
      expect(PageWidth.full.maxWidth, double.infinity);
      expect(Extents.xxxxl, 1597);
    });

    test('a full page keeps the largest spacing as its margin', () {
      expect(PageWidth.full.margin, Spacing.xxl);
      for (final width in [
        PageWidth.narrow,
        PageWidth.medium,
        PageWidth.wide,
      ]) {
        expect(width.margin, Spacing.l);
      }
    });
  });

  group('text size', () {
    test('the steps are half golden steps around the body size', () {
      expect(PageAppearance.textSizes, [13, 16, 20, 26, 33]);
      for (final (index, size) in PageAppearance.textSizes.indexed) {
        final exact = TypeScale.body * pow(sqrt(GoldenRatio.phi), index - 1);
        expect((size - exact).abs(), lessThanOrEqualTo(0.5), reason: '$size');
      }
      // Every second step is back on the type scale.
      expect(PageAppearance.textSizes[1], TypeScale.body);
      expect(PageAppearance.textSizes[3], TypeScale.title2);
    });

    test('scales the page by the chosen size over the body size', () {
      const appearance = PageAppearance(textStep: 2);
      expect(appearance.textSize, 20);
      expect(appearance.textFactor, 20 / 16);
    });
  });

  test('starts medium and at the body size', () {
    const appearance = PageAppearance();
    expect(appearance.width, PageWidth.medium);
    expect(appearance.textSize, TypeScale.body);
  });

  test('steps stop at both ends', () {
    var appearance = const PageAppearance();
    for (var i = 0; i < 9; i++) {
      appearance = appearance.wider().larger();
    }
    expect(appearance.width, PageWidth.full);
    expect(appearance.textSize, 33);
    for (var i = 0; i < 9; i++) {
      appearance = appearance.narrower().smaller();
    }
    expect(appearance.width, PageWidth.narrow);
    expect(appearance.textSize, 13);
  });

  group('stored as bytes', () {
    test('round-trips every combination', () {
      for (final width in PageWidth.values) {
        for (var step = 0; step < PageAppearance.textSizes.length; step++) {
          final appearance = PageAppearance(width: width, textStep: step);
          expect(PageAppearance.fromBytes(appearance.toBytes()), appearance);
        }
      }
    });

    test('anything unexpected is the default, never an error', () {
      for (final bytes in <Uint8List?>[
        null,
        Uint8List(0),
        Uint8List.fromList([1, 0]),
        Uint8List.fromList([2, 0, 0]),
        Uint8List.fromList([1, 4, 0]),
        Uint8List.fromList([1, 0, 5]),
        Uint8List.fromList([1, 0, 0, 0]),
      ]) {
        expect(
          PageAppearance.fromBytes(bytes),
          const PageAppearance(),
          reason: '$bytes',
        );
      }
    });
  });
}
