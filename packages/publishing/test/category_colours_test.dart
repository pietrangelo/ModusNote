import 'package:publishing/publishing.dart';
import 'package:test/test.dart';

void main() {
  final light = SitePalette.of(const SiteTheme(BaseTheme.fresco));
  final dark = SitePalette.of(const SiteTheme(BaseTheme.frescoDark));

  test('the colours serv.pub gives the same categories', () {
    // From `colour::category` on the two Fresco themes.
    const expected = {
      false: [
        ('#A9461B', '#FEE9E2'),
        ('#117A6A', '#D6F7EF'),
        ('#884B9E', '#F8E8FF'),
        ('#7D6701', '#F6EED5'),
        ('#0F7298', '#DEF2FC'),
        ('#A93E58', '#FEE8EB'),
      ],
      true: [
        ('#E6905A', '#2D1A0F'),
        ('#0AC1B9', '#072523'),
        ('#D28BD1', '#281928'),
        ('#B5AC43', '#22200B'),
        ('#57B1F0', '#0F212E'),
        ('#ED8688', '#2E1819'),
      ],
    };
    for (final MapEntry(key: isDark, value: rows) in expected.entries) {
      final palette = isDark ? dark : light;
      for (final (order, (accent, tint)) in rows.indexed) {
        expect(
          CategoryColours.of(palette, order),
          CategoryColours(Srgb.hex(accent), Srgb.hex(tint)),
          reason: '$isDark $order',
        );
      }
    }
  });

  test('every category reads, on both Frescos', () {
    for (final palette in [light, dark]) {
      for (var order = 0; order < 34; order++) {
        final c = CategoryColours.of(palette, order);
        expect(
          c.accent.contrastWith(palette.background),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          c.accent.contrastWith(palette.surface),
          greaterThanOrEqualTo(4.5),
        );
        expect(c.accent.contrastWith(c.tint), greaterThanOrEqualTo(4.5));
        expect(palette.text.contrastWith(c.tint), greaterThanOrEqualTo(7));
      }
    }
  });
}
