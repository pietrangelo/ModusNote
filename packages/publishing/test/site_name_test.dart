import 'package:publishing/publishing.dart';
import 'package:test/test.dart';

void main() {
  group('SiteName', () {
    test('accepts lowercase letters, digits and inner hyphens', () {
      for (final name in ['abc', 'pietrangelo', 'modus-notes-2', 'a1b']) {
        expect(SiteName(name).value, name);
      }
    });

    test('is the address path of the site on serv.pub', () {
      expect(SiteName('pietrangelo').url, 'https://serv.pub/pietrangelo');
    });

    test('refuses names too short or too long', () {
      expect(() => SiteName('ab'), throwsA(isA<InvalidSiteNameException>()));
      expect(SiteName('a' * SiteName.maxLength).value, hasLength(34));
      expect(
        () => SiteName('a' * (SiteName.maxLength + 1)),
        throwsA(isA<InvalidSiteNameException>()),
      );
    });

    test('refuses uppercase, accents, dots, slashes and spaces', () {
      for (final name in [
        'Pietro',
        'perché',
        'a.b.c',
        'a/b/c',
        'a b c',
        'аbc',
      ]) {
        expect(
          () => SiteName(name),
          throwsA(isA<InvalidSiteNameException>()),
          reason: name,
        );
      }
    });

    test('refuses hyphens at either end or doubled', () {
      for (final name in ['-abc', 'abc-', 'ab--c']) {
        expect(
          () => SiteName(name),
          throwsA(isA<InvalidSiteNameException>()),
          reason: name,
        );
      }
    });

    test('refuses names the platform needs or that impersonate it', () {
      for (final name in SiteName.reserved) {
        if (name.length < SiteName.minLength) continue;
        expect(
          () => SiteName(name),
          throwsA(isA<InvalidSiteNameException>()),
          reason: name,
        );
      }
      expect(SiteName.reserved, containsAll(['api', 'www', 'assets', 'modus']));
    });

    test('equal by value', () {
      expect(SiteName('abc'), SiteName('abc'));
      expect(SiteName('abc').hashCode, SiteName('abc').hashCode);
    });
  });

  group('PageSlug', () {
    test('is made from a title: lowercase, accents folded, hyphens', () {
      expect(
        PageSlug.fromTitle('Perché la Luna è così?').value,
        'perche-la-luna-e-cosi',
      );
      expect(
        PageSlug.fromTitle('  Ünïcode — Straße  ').value,
        'unicode-strasse',
      );
      expect(PageSlug.fromTitle("L'età dell'oro").value, 'l-eta-dell-oro');
    });

    test('a title with nothing usable becomes "pagina"', () {
      expect(PageSlug.fromTitle('').value, 'pagina');
      expect(PageSlug.fromTitle('★ ☆ ♪').value, 'pagina');
    });

    test('is at most 89 characters (Fibonacci) and never ends in a hyphen', () {
      final slug = PageSlug.fromTitle('${'parola ' * 40}fine');
      expect(slug.value.length, lessThanOrEqualTo(PageSlug.maxLength));
      expect(PageSlug.maxLength, 89);
      expect(slug.value.endsWith('-'), isFalse);
    });

    test('validates a slug given as is', () {
      expect(PageSlug('una-pagina').value, 'una-pagina');
      for (final bad in ['', 'Una', 'a--b', '-a', 'a-', 'a/b', '..']) {
        expect(
          () => PageSlug(bad),
          throwsA(isA<InvalidPageSlugException>()),
          reason: bad,
        );
      }
    });

    test('a taken slug gets the next free number', () {
      final taken = {PageSlug('diario'), PageSlug('diario-2')};
      expect(PageSlug('diario').freeAmong(taken).value, 'diario-3');
      expect(PageSlug('altro').freeAmong(taken).value, 'altro');
    });
  });
}
