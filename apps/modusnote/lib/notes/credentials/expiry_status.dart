import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import '../../l10n/generated/app_localizations.dart';

/// What a credential card says about its password's expiry: nothing until
/// a week before, then how long is left, then that it has expired.
abstract final class ExpiryStatus {
  static String? of(
    DynamicEntry entry,
    AppLocalizations l10n, {
    required DateTime now,
  }) {
    final expiry = PasswordExpiry.of(entry);
    if (expiry == null) return null;
    final today = DateValue(now.year, now.month, now.day);
    if (!PasswordExpiry.isSoon(expiry, today: today)) return null;
    return switch (PasswordExpiry.daysLeft(expiry, today: today)) {
      < 0 => l10n.expiryExpired,
      0 => l10n.expiryToday,
      1 => l10n.expiryTomorrow,
      final days => l10n.expiryInDays(days),
    };
  }
}
