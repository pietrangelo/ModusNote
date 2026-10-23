import 'package:flutter/material.dart';

import '../l10n/generated/app_localizations.dart';
import '../theme/golden_ratio.dart';
import '../theme/modus_palette.dart';
import 'notice_center.dart';

/// Tells the library that another device changed who belongs to the vault,
/// until the person opens the notices; this device's own changes never
/// show here.
class SecurityBanner extends StatelessWidget {
  const SecurityBanner({
    required this.notices,
    required this.onOpen,
    super.key,
  });

  final NoticeCenter notices;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: notices,
    builder: (context, _) {
      final count = notices.unreadSecurity;
      if (count == 0) return const SizedBox.shrink();
      final palette = ModusPalette.of(context);
      final l10n = AppLocalizations.of(context);
      return Card(
        key: const ValueKey('security-banner'),
        margin: const EdgeInsets.symmetric(vertical: Spacing.xs),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            Spacing.m,
            Spacing.xs,
            Spacing.xs,
            Spacing.xs,
          ),
          child: Row(
            spacing: Spacing.s,
            children: [
              Icon(Icons.shield_outlined, color: palette.error),
              Expanded(
                child: Text(
                  l10n.noticesBanner(count),
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
              TextButton(
                onPressed: onOpen,
                child: Text(l10n.noticesBannerAction),
              ),
            ],
          ),
        ),
      );
    },
  );
}
