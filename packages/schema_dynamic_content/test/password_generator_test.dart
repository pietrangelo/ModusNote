import 'dart:math';

import 'package:schema_dynamic_content/schema_dynamic_content.dart';
import 'package:test/test.dart';

const lower = 'abcdefghijklmnopqrstuvwxyz';
const upper = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
const digits = '0123456789';

void main() {
  final random = Random(7);
  int next(int max) => random.nextInt(max);

  String generate(PasswordRecipe recipe) =>
      PasswordGenerator.generate(recipe, next).text;

  test('the default recipe is long and strong', () {
    final recipe = PasswordRecipe();
    expect(recipe.length, PasswordRecipe.defaultLength);
    expect(recipe.entropyBits, greaterThanOrEqualTo(PasswordRecipe.minBits));
    expect(generate(recipe), hasLength(PasswordRecipe.defaultLength));
  });

  test('every password has a lower, an upper, a digit and a symbol', () {
    for (var i = 0; i < 500; i++) {
      final password = generate(PasswordRecipe(length: 14));
      expect(password.split('').any(lower.contains), isTrue);
      expect(password.split('').any(upper.contains), isTrue);
      expect(password.split('').any(digits.contains), isTrue);
      expect(password.split('').any(PasswordRecipe.symbols.contains), isTrue);
    }
  });

  test('excluded symbols never appear, the others still do', () {
    final excluded = {r'"', "'", r'\', '`', '<', '>'};
    final recipe = PasswordRecipe(length: 64, excluded: excluded);
    final seen = <String>{};
    for (var i = 0; i < 300; i++) {
      final password = generate(recipe);
      expect(password.split('').where(excluded.contains), isEmpty);
      seen.addAll(password.split(''));
    }
    expect(
      seen,
      containsAll(
        PasswordRecipe.symbols.split('').where((c) => !excluded.contains(c)),
      ),
    );
  });

  test('without any symbol it is letters and digits, and longer', () {
    final all = PasswordRecipe.symbols.split('').toSet();
    expect(
      PasswordRecipe.minLengthFor(all),
      greaterThan(PasswordRecipe.minLengthFor({})),
    );
    final recipe = PasswordRecipe(length: 20, excluded: all);
    final password = generate(recipe);
    expect(password, matches(RegExp(r'^[A-Za-z0-9]{20}$')));
  });

  test('refuses a recipe too weak to be safe', () {
    expect(
      () => PasswordRecipe(length: 8),
      throwsA(isA<InvalidValueException>()),
    );
    final all = PasswordRecipe.symbols.split('').toSet();
    expect(
      () => PasswordRecipe(
        length: PasswordRecipe.minLengthFor(all) - 1,
        excluded: all,
      ),
      throwsA(isA<InvalidValueException>()),
    );
    expect(
      PasswordRecipe(
        length: PasswordRecipe.minLengthFor(all),
        excluded: all,
      ).entropyBits,
      greaterThanOrEqualTo(PasswordRecipe.minBits),
    );
    expect(
      PasswordRecipe(length: PasswordRecipe.minLengthFor({})).entropyBits,
      greaterThanOrEqualTo(PasswordRecipe.minBits),
    );
  });

  test(
    'refuses lengths past the field and exclusions that are not symbols',
    () {
      expect(
        () => PasswordRecipe(length: PasswordRecipe.maxLength + 1),
        throwsA(isA<InvalidValueException>()),
      );
      expect(
        () => PasswordRecipe(excluded: {'a'}),
        throwsA(isA<InvalidValueException>()),
      );
    },
  );

  test('a generated password fits the password field', () {
    final password = PasswordGenerator.generate(
      PasswordRecipe(length: PasswordRecipe.maxLength),
      next,
    );
    expect(PasswordFieldType().check(password), isEmpty);
  });

  test('each character is drawn uniformly', () {
    // Rough χ² check on the free positions: no symbol is starved.
    final counts = <String, int>{};
    for (var i = 0; i < 2000; i++) {
      for (final c in generate(PasswordRecipe(length: 32)).split('')) {
        counts[c] = (counts[c] ?? 0) + 1;
      }
    }
    final expected = 2000 * 32 / PasswordRecipe().alphabet.length;
    for (final count in counts.values) {
      expect(count, inInclusiveRange(expected * 0.8, expected * 1.4));
    }
    expect(counts, hasLength(PasswordRecipe().alphabet.length));
  });
}
