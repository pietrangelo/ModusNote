import 'package:flutter/material.dart';

import '../attachments/open_in_browser.dart';
import '../l10n/generated/app_localizations.dart';
import '../theme/golden_ratio.dart';
import '../theme/modus_palette.dart';

/// Shown wherever a passphrase is chosen (a new vault, a device joining
/// one): nobody can recover a forgotten passphrase, not even the developer,
/// because it never leaves the device. The form stays closed until the
/// person ticks that they understood. It also links the terms of service
/// and the privacy policy, accepted by going on.
class PassphraseWarning extends StatelessWidget {
  const PassphraseWarning({
    required this.acknowledged,
    required this.onChanged,
    required this.enabled,
    super.key,
  });

  final bool acknowledged;
  final ValueChanged<bool> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    // A Material, not a decorated box, so the checkbox's ink shows on it.
    return Material(
      key: const ValueKey('passphrase-warning'),
      color: ModusPalette.of(context).surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.card),
        side: BorderSide(
          color: ModusPalette.of(context).primary,
          width: Spacing.xxs,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          Spacing.m,
          Spacing.m,
          Spacing.m,
          Spacing.xs,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.warning_amber_rounded,
                  size: IconSizes.inline,
                  color: ModusPalette.of(context).primary,
                ),
                const SizedBox(width: Spacing.s),
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text(
                      l10n.passphraseWarningTitle,
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: ModusPalette.of(context).primary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: Spacing.s),
            Text(
              l10n.passphraseWarningBody,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: ModusPalette.of(context).text,
              ),
            ),
            const SizedBox(height: Spacing.xs),
            CheckboxListTile(
              key: const ValueKey('passphrase-acknowledged'),
              value: acknowledged,
              onChanged: enabled ? (value) => onChanged(value ?? false) : null,
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
              title: Text(
                l10n.passphraseWarningAcknowledge,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: ModusPalette.of(context).text,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Text(
              l10n.legalNotice,
              style: theme.textTheme.bodySmall?.copyWith(
                color: ModusPalette.of(context).muted,
              ),
            ),
            Wrap(
              spacing: Spacing.s,
              children: [
                TextButton(
                  key: const ValueKey('legal-terms'),
                  onPressed: () => openInBrowser(_legal('terms.html')),
                  child: Text(l10n.legalTerms),
                ),
                TextButton(
                  key: const ValueKey('legal-privacy'),
                  onPressed: () => openInBrowser(_legal('privacy.html')),
                  child: Text(l10n.legalPrivacy),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // The published pages, also from the phone and from a local web build.
  static Uri _legal(String page) => Uri.https('modus.serv.run', '/$page');
}
