import 'package:collaboration_access_control/collaboration_access_control.dart';
import 'package:flutter/material.dart';
import 'package:offline_sync/offline_sync.dart';

import '../l10n/generated/app_localizations.dart';
import '../sync/members_sheet.dart';
import '../sync/sync_controller.dart';
import '../theme/golden_ratio.dart';
import '../theme/modus_palette.dart';
import '../vault/auto_lock.dart';
import 'notice_center.dart';

/// The vault's notices: the operator's first, as plain text that links and
/// formatting cannot dress up, under a fixed line on what they never ask;
/// then the vault's security, newest first, from the member log this device
/// verified. Opening it marks everything read; what was new stays marked
/// while it is open.
class NoticesSheet extends StatefulWidget {
  const NoticesSheet({
    required this.notices,
    required this.sync,
    this.onInvite,
    super.key,
  });

  final NoticeCenter notices;
  final SyncController sync;

  /// Passed on to the members sheet.
  final VoidCallback? onInvite;

  static Future<void> show(
    BuildContext context,
    NoticeCenter notices,
    SyncController sync, {
    VoidCallback? onInvite,
  }) {
    final autoLock = AutoLockScope.maybeOf(context);
    final sheet = NoticesSheet(
      notices: notices,
      sync: sync,
      onInvite: onInvite,
    );
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => autoLock == null
          ? sheet
          : AutoLockScope(autoLock: autoLock, child: sheet),
    );
  }

  @override
  State<NoticesSheet> createState() => _NoticesSheetState();
}

class _NoticesSheetState extends State<NoticesSheet> {
  /// The security notices that were new when the sheet opened.
  late final Set<int> _fresh = {
    for (final notice in widget.notices.security)
      if (notice.unread) notice.notice.sequence,
  };

  @override
  void initState() {
    super.initState();
    // After the first frame: the badges listening redraw outside a build.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        await widget.notices.markRead();
      } on VaultLockedException {
        // Locked meanwhile: they show as new again at the next unlock.
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final palette = ModusPalette.of(context);
    return ListenableBuilder(
      listenable: widget.notices,
      builder: (context, _) {
        final notices = widget.notices;
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(Spacing.l),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(l10n.noticesAction, style: theme.textTheme.headlineSmall),
                const SizedBox(height: Spacing.m),
                for (final notice in notices.service) _service(notice),
                Text(
                  l10n.noticesDisclaimer,
                  key: const ValueKey('notices-disclaimer'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: palette.muted,
                  ),
                ),
                const SizedBox(height: Spacing.l),
                Text(l10n.noticesSecurity, style: theme.textTheme.titleMedium),
                const SizedBox(height: Spacing.s),
                if (notices.security.isEmpty)
                  Text(
                    l10n.noticesEmpty,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: palette.muted,
                    ),
                  ),
                for (final notice in notices.security) _security(notice),
              ],
            ),
          ),
        );
      },
    );
  }

  /// The operator's words as they are: never Markdown, never a link.
  Widget _service(ServiceNotice notice) {
    final l10n = AppLocalizations.of(context);
    final palette = ModusPalette.of(context);
    final warning = notice.level == ServiceNoticeLevel.warning;
    return Card(
      key: ValueKey('service-${notice.serial}'),
      margin: const EdgeInsets.only(bottom: Spacing.m),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          Spacing.m,
          Spacing.s,
          Spacing.xs,
          Spacing.s,
        ),
        child: Row(
          spacing: Spacing.s,
          children: [
            Icon(
              warning ? Icons.warning_amber_outlined : Icons.info_outline,
              color: warning ? palette.error : palette.primary,
              semanticLabel: warning ? l10n.noticeWarning : null,
            ),
            Expanded(
              child: Text(
                notice.textFor(Localizations.localeOf(context).languageCode),
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            IconButton(
              tooltip: l10n.noticeClose,
              onPressed: () => _dismiss(notice.serial),
              icon: const Icon(Icons.close),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _dismiss(int serial) async {
    try {
      await widget.notices.dismiss(serial);
    } on VaultLockedException {
      // Locked meanwhile: the sheet closes with the vault.
    }
  }

  Widget _security(SecurityNotice entry) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final palette = ModusPalette.of(context);
    final notice = entry.notice;
    final me = widget.notices.me;
    final subject = notice.member == me ? 'me' : 'other';
    final fresh = _fresh.contains(notice.sequence);
    final (icon, text) = switch (notice) {
      MemberJoined(:final role) => (
        Icons.person_add_alt_outlined,
        l10n.noticeJoined(subject, role.name),
      ),
      MemberRemoved(:final member) when member == me => (
        Icons.person_remove_outlined,
        l10n.noticeRemovedThis,
      ),
      MemberRemoved() => (
        Icons.person_remove_outlined,
        l10n.noticeRemoved(entry.rotated ? 'yes' : 'no'),
      ),
      MemberLeft() => (Icons.logout, l10n.noticeLeft(subject)),
      MemberRoleChanged(:final from, :final to) => (
        Icons.manage_accounts_outlined,
        l10n.noticeRoleChanged(subject, from.name, to.name),
      ),
    };
    final device = notice.member == me
        ? l10n.membersThisDevice
        : l10n.noticeDevice(notice.member.fingerprint);
    final author = entry.byThisDevice
        ? l10n.noticeByThisDevice
        : l10n.noticeBy(notice.author.fingerprint);
    return Padding(
      key: ValueKey('notice-${notice.sequence}'),
      padding: const EdgeInsets.symmetric(vertical: Spacing.s),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: Spacing.m,
        children: [
          Icon(icon, color: fresh ? palette.error : palette.muted),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (fresh)
                  Text(
                    l10n.noticeNew,
                    key: ValueKey('notice-new-${notice.sequence}'),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: palette.error,
                    ),
                  ),
                Text(text, style: theme.textTheme.bodyMedium),
                Text(
                  '$device · $author',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: palette.muted,
                  ),
                ),
                if (!entry.byThisDevice)
                  TextButton(
                    style: TextButton.styleFrom(padding: EdgeInsets.zero),
                    onPressed: () => MembersSheet.show(
                      context,
                      widget.sync,
                      onInvite: widget.onInvite,
                    ),
                    child: Text(l10n.noticeUnrecognized),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
