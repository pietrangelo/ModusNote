import 'dart:math';

import 'package:flutter/material.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../theme/golden_ratio.dart';

/// Lets the person pick a length and the symbols a site refuses, and
/// returns a password drawn from the platform's secure random source;
/// null when they close it.
Future<SecretValue?> showPasswordGenerator(BuildContext context) =>
    showModalBottomSheet<SecretValue>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const PasswordGeneratorSheet(),
    );

class PasswordGeneratorSheet extends StatefulWidget {
  const PasswordGeneratorSheet({super.key, this.random});

  /// Uniform integers in `[0, max)`; `Random.secure` unless a test sets it.
  final int Function(int max)? random;

  @override
  State<PasswordGeneratorSheet> createState() => _PasswordGeneratorSheetState();
}

class _PasswordGeneratorSheetState extends State<PasswordGeneratorSheet> {
  late final int Function(int max) _random =
      widget.random ?? Random.secure().nextInt;
  final _excluded = <String>{};
  var _length = PasswordRecipe.defaultLength;
  late PasswordRecipe _recipe = PasswordRecipe(length: _length);
  late SecretValue _password = PasswordGenerator.generate(_recipe, _random);

  int get _minLength => PasswordRecipe.minLengthFor(_excluded);

  void _remake() {
    if (_length < _minLength) _length = _minLength;
    _recipe = PasswordRecipe(length: _length, excluded: _excluded);
    _password = PasswordGenerator.generate(_recipe, _random);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(Spacing.l),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l10n.passwordGenerate, style: theme.textTheme.titleLarge),
            const SizedBox(height: Spacing.m),
            Container(
              padding: const EdgeInsets.all(Spacing.m),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(Radii.card),
              ),
              child: SelectableText(
                _password.text,
                key: const ValueKey('generated-password'),
                style: theme.textTheme.bodyLarge,
              ),
            ),
            const SizedBox(height: Spacing.xs),
            Text(
              l10n.generatorStrength(_recipe.entropyBits.floor()),
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: Spacing.m),
            Text(l10n.generatorLength(_length)),
            Slider(
              key: const ValueKey('generator-length'),
              value: _length.toDouble(),
              min: _minLength.toDouble(),
              max: PasswordRecipe.maxLength.toDouble(),
              divisions: PasswordRecipe.maxLength - _minLength,
              label: '$_length',
              onChanged: (value) => setState(() {
                _length = value.round();
                _remake();
              }),
            ),
            const SizedBox(height: Spacing.s),
            Text(l10n.generatorSymbols, style: theme.textTheme.titleSmall),
            const SizedBox(height: Spacing.xs),
            Text(l10n.generatorSymbolsHint, style: theme.textTheme.bodySmall),
            const SizedBox(height: Spacing.s),
            Wrap(
              spacing: Spacing.xs,
              runSpacing: Spacing.xs,
              children: [
                for (final symbol in PasswordRecipe.symbols.split(''))
                  Tooltip(
                    message: l10n.generatorExclude(symbol),
                    child: FilterChip(
                      key: ValueKey('exclude-$symbol'),
                      label: Text(symbol),
                      selected: _excluded.contains(symbol),
                      showCheckmark: false,
                      onSelected: (exclude) => setState(() {
                        exclude
                            ? _excluded.add(symbol)
                            : _excluded.remove(symbol);
                        _remake();
                      }),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: Spacing.l),
            OverflowBar(
              alignment: MainAxisAlignment.end,
              overflowAlignment: OverflowBarAlignment.end,
              spacing: Spacing.s,
              overflowSpacing: Spacing.s,
              children: [
                TextButton.icon(
                  icon: const Icon(Icons.refresh, size: IconSizes.inline),
                  label: Text(l10n.generatorAgain),
                  onPressed: () => setState(_remake),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(_password),
                  child: Text(l10n.generatorUse),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
