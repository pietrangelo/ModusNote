import 'dart:math' as math;

import 'package:meta/meta.dart';

import 'field_value.dart';
import 'schema_exception.dart';

/// How a password is generated: its length and the symbols left out (a
/// site may refuse quotes or backslashes). Lower and upper case letters
/// and digits are always in, and every recipe that can be built is
/// strong: at least [minBits] of entropy, counted conservatively.
@immutable
final class PasswordRecipe {
  PasswordRecipe({this.length = defaultLength, Set<String> excluded = const {}})
    : excluded = Set.unmodifiable(excluded) {
    if (!excluded.every((c) => c.length == 1 && symbols.contains(c))) {
      throw const InvalidValueException('only symbols can be left out');
    }
    if (length > maxLength) {
      throw const InvalidValueException('password too long');
    }
    if (length < minLengthFor(excluded)) {
      throw const InvalidValueException('password too weak');
    }
  }

  static const lower = 'abcdefghijklmnopqrstuvwxyz';
  static const upper = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
  static const digits = '0123456789';

  /// The printable ASCII symbols, which every keyboard can type.
  static const symbols = r'''!"#$%&'()*+,-./:;<=>?@[\]^_`{|}~''';

  static const minBits = 80;
  static const minLength = 12;
  static const maxLength = 128;
  static const defaultLength = 20;

  final int length;
  final Set<String> excluded;

  /// The symbols this recipe draws from.
  String get allowedSymbols =>
      symbols.split('').where((c) => !excluded.contains(c)).join();

  /// Every character a password can hold.
  String get alphabet => '$lower$upper$digits$allowedSymbols';

  /// The classes a password always has one of each.
  List<String> get _classes => [
    lower,
    upper,
    digits,
    if (allowedSymbols.isNotEmpty) allowedSymbols,
  ];

  double get entropyBits => _bits(length, _classes, alphabet.length);

  /// The shortest strong password without the [excluded] symbols.
  static int minLengthFor(Set<String> excluded) {
    final recipe = PasswordRecipe._probe(excluded);
    var length = minLength;
    while (_bits(length, recipe._classes, recipe.alphabet.length) < minBits) {
      length++;
    }
    return length;
  }

  PasswordRecipe._probe(this.excluded) : length = 0;

  /// A lower bound: one character drawn from each class, the rest from the
  /// whole alphabet, the order not counted.
  static double _bits(int length, List<String> classes, int alphabet) {
    final free = length - classes.length;
    if (free < 0) return 0;
    var bits = free * _log2(alphabet);
    for (final c in classes) {
      bits += _log2(c.length);
    }
    return bits;
  }

  static double _log2(int n) => math.log(n) / math.ln2;
}

abstract final class PasswordGenerator {
  /// A password for [recipe]. [random] must return a uniform integer in
  /// `[0, max)` from a cryptographically secure source (the app passes
  /// `Random.secure().nextInt`).
  static SecretValue generate(
    PasswordRecipe recipe,
    int Function(int max) random,
  ) {
    final alphabet = recipe.alphabet;
    final chars = [
      for (final c in recipe._classes) c[random(c.length)],
      for (var i = recipe._classes.length; i < recipe.length; i++)
        alphabet[random(alphabet.length)],
    ];
    // Fisher–Yates: the guaranteed characters can end up anywhere.
    for (var i = chars.length - 1; i > 0; i--) {
      final j = random(i + 1);
      final swap = chars[i];
      chars[i] = chars[j];
      chars[j] = swap;
    }
    return SecretValue(chars.join());
  }
}
