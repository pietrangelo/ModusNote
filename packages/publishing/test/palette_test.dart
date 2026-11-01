import 'package:publishing/publishing.dart';
import 'package:test/test.dart';

void main() {
  group('Srgb', () {
    test('hex round trip', () {
      expect(Srgb.hex('#EBB448').hex, '#EBB448');
      expect(Srgb.hex('090c15').hex, '#090C15');
      expect(() => Srgb.hex('#12345'), throwsA(isA<InvalidColorException>()));
    });

    test('contrast ratio follows WCAG 2', () {
      final black = Srgb.hex('#000000');
      final white = Srgb.hex('#FFFFFF');
      expect(black.contrastWith(white), closeTo(21, 1e-9));
      expect(white.contrastWith(white), closeTo(1, 1e-9));
      expect(Srgb.hex('#777777').contrastWith(white), closeTo(4.48, 0.01));
    });

    test('OKLCH round trip of the brand colours', () {
      for (final hex in ['#EBB448', '#8B3FD6', '#00A3FF', '#090C15']) {
        final c = Srgb.hex(hex);
        final back = Oklch.of(c).toSrgb();
        expect(back.hex, hex);
      }
    });
  });

  group('SiteTheme and SitePalette', () {
    test(
      'the base themes keep the brand colours when nothing is customised',
      () {
        final modus = SitePalette.of(const SiteTheme(BaseTheme.modus));
        expect(modus.background.hex, '#090C15');
        expect(modus.surface.hex, '#13192B');
        expect(modus.text.hex, '#F8FAFC');
        expect(modus.accent.hex, '#EBB448');
        expect(
          SitePalette.of(const SiteTheme(BaseTheme.paper)).isDark,
          isFalse,
        );
        expect(
          SitePalette.of(const SiteTheme(BaseTheme.restful)).isDark,
          isTrue,
        );
      },
    );

    test('Fresco is a light cream, with an evening version on dark', () {
      final light = SitePalette.of(const SiteTheme(BaseTheme.fresco));
      expect(light.isDark, isFalse);
      expect(light.background.hex, '#FBF8F1');
      expect(light.surface.hex, '#FFFFFF');
      expect(light.text.hex, '#1D1A16');
      expect(light.accent.hex, '#A9461B');
      final dark = SitePalette.of(const SiteTheme(BaseTheme.frescoDark));
      expect(dark.isDark, isTrue);
      expect(dark.background.hex, '#13161D');
      expect(dark.accent.hex, '#E6905A');
      // Livelier than the app's paper theme: the photos come first.
      final paper = SitePalette.of(const SiteTheme(BaseTheme.paper));
      expect(Oklch.of(light.accent).c, greaterThan(Oklch.of(paper.accent).c));
    });

    test('every theme, every accent hue, every background hue is AA', () {
      final hues = [null, for (var h = 0; h < 360; h += 15) h.toDouble()];
      for (final base in BaseTheme.values) {
        for (final accent in hues) {
          for (final ground in hues) {
            final p = SitePalette.of(
              SiteTheme(base, accentHue: accent, backgroundHue: ground),
            );
            final why = '$base accent $accent ground $ground';
            for (final bg in [p.background, p.surface]) {
              expect(
                p.text.contrastWith(bg),
                greaterThanOrEqualTo(7),
                reason: why,
              );
              expect(
                p.secondaryText.contrastWith(bg),
                greaterThanOrEqualTo(4.5),
                reason: why,
              );
              expect(
                p.accent.contrastWith(bg),
                greaterThanOrEqualTo(4.5),
                reason: why,
              );
              expect(
                p.secondAccent.contrastWith(bg),
                greaterThanOrEqualTo(4.5),
                reason: why,
              );
            }
          }
        }
      }
    });

    test('the second accent sits at the golden angle from the first', () {
      final p = SitePalette.of(
        const SiteTheme(BaseTheme.restful, accentHue: 30),
      );
      final first = Oklch.of(p.accent).h;
      final second = Oklch.of(p.secondAccent).h;
      final gap = (second - first) % 360;
      expect(gap, closeTo(Golden.angle, 4));
      expect(Golden.angle, closeTo(137.5, 0.1));
    });

    test(
      'the surface sits one golden step of lightness from the background',
      () {
        for (final base in BaseTheme.values) {
          final p = SitePalette.of(SiteTheme(base, backgroundHue: 200));
          final step = Oklch.of(p.surface).l - Oklch.of(p.background).l;
          expect(
            step.abs(),
            closeTo(Golden.lightnessStep, 0.01),
            reason: '$base',
          );
          expect(
            step > 0,
            p.isDark,
            reason: 'dark surfaces rise, light ones sink',
          );
        }
      },
    );

    test('a hue outside 0..360 is refused', () {
      expect(
        () => SiteTheme.checked(BaseTheme.modus, accentHue: 360),
        throwsA(isA<InvalidColorException>()),
      );
      expect(
        () => SiteTheme.checked(BaseTheme.modus, backgroundHue: -1),
        throwsA(isA<InvalidColorException>()),
      );
      expect(
        () => SiteTheme.checked(BaseTheme.modus, accentHue: double.nan),
        throwsA(isA<InvalidColorException>()),
      );
    });
  });
}
