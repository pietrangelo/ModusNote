import 'package:collaboration_access_control/collaboration_access_control.dart';
import 'package:flutter/material.dart';
import 'package:offline_sync/offline_sync.dart';

import '../l10n/generated/app_localizations.dart';
import '../theme/golden_ratio.dart';
import '../vault/auto_lock.dart';
import 'sync_controller.dart';
import '../theme/modus_palette.dart';

/// The start of a member's public signing key, in four groups: devices
/// have no names, so this is how two screens are compared.
String memberFingerprint(MemberId member) {
  final hex = member.hex.substring(0, 16).toUpperCase();
  return [for (var i = 0; i < hex.length; i += 4) hex.substring(i, i + 4)]
      .join(' ');
}

/// Who belongs to the vault, and, for an owner, removing a device: the
/// vault's key is rotated, so the removed device reads nothing written
/// from then on.
class MembersSheet extends StatefulWidget {
  const MembersSheet({required this.sync, this.onInvite, super.key});

  final SyncController sync;

  /// Opens the invitation of another person; null where invitations are
  /// not offered.
  final VoidCallback? onInvite;

  static Future<void> show(
    BuildContext context,
    SyncController sync, {
    VoidCallback? onInvite,
  }) {
    final autoLock = AutoLockScope.maybeOf(context);
    final sheet = MembersSheet(sync: sync, onInvite: onInvite);
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => autoLock == null
          ? sheet
          : AutoLockScope(autoLock: autoLock, child: sheet),
    );
  }

  @override
  State<MembersSheet> createState() => _MembersSheetState();
}

class _MembersSheetState extends State<MembersSheet> {
  MemberId? _removing;
  String? _problem;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: widget.sync,
      builder: (context, _) {
        final sync = widget.sync;
        final removed = sync.problem == SyncProblem.removed;
        final manages = sync.managesMembers && !removed;
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(Spacing.l),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(l10n.membersTitle, style: theme.textTheme.headlineSmall),
                const SizedBox(height: Spacing.m),
                Text(
                  l10n.membersBody,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: ModusPalette.of(context).muted,
                  ),
                ),
                const SizedBox(height: Spacing.m),
                for (final member in sync.members)
                  _row(context, member, manages: manages),
                if (widget.onInvite case final invite? when manages) ...[
                  const SizedBox(height: Spacing.s),
                  OutlinedButton.icon(
                    key: const ValueKey('invite'),
                    onPressed: sync.state == SyncState.synced ? invite : null,
                    icon: const Icon(Icons.person_add_alt_outlined),
                    label: Text(l10n.inviteAction),
                  ),
                ],
                if (_problem case final problem?) ...[
                  const SizedBox(height: Spacing.s),
                  Text(
                    problem,
                    key: const ValueKey('members-problem'),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _row(
    BuildContext context,
    WorkspaceMember member, {
    required bool manages,
  }) {
    final l10n = AppLocalizations.of(context);
    final mine = member.id == widget.sync.me;
    final role = switch (member.role) {
      Role.owner => l10n.membersRoleOwner,
      Role.editor => l10n.membersRoleEditor,
      Role.viewer => l10n.membersRoleViewer,
    };
    final removing = _removing == member.id;
    return ListTile(
      key: ValueKey('member-${member.id.hex}'),
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        mine ? Icons.smartphone : Icons.devices_outlined,
        color: mine ? ModusPalette.of(context).primary : null,
      ),
      title: Text(mine ? l10n.membersThisDevice : l10n.membersDevice),
      subtitle: Text(
        l10n.membersFingerprint(role, memberFingerprint(member.id)),
      ),
      trailing: mine || !manages
          ? null
          : removing
          ? const SizedBox.square(
              dimension: Spacing.l,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : IconButton(
              key: ValueKey('remove-${member.id.hex}'),
              tooltip: l10n.membersRemove,
              onPressed: _removing == null ? () => _remove(member.id) : null,
              icon: const Icon(Icons.person_remove_outlined),
            ),
    );
  }

  /// Asks first: a removal cannot be taken back.
  Future<void> _remove(MemberId member) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.person_remove_outlined),
        title: Text(l10n.membersRemoveTitle),
        content: Text(l10n.membersRemoveBody(memberFingerprint(member))),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            key: const ValueKey('remove-confirm'),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.membersRemove),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _removing = member;
      _problem = null;
    });
    final messenger = ScaffoldMessenger.maybeOf(context);
    // The new key must be kept before the vault may lock.
    final release = AutoLockScope.maybeOf(context)?.hold();
    String? problem;
    try {
      await widget.sync.revoke(member);
    } on Object catch (error) {
      // Recorded here but not sent: the next sync sends it.
      problem = !widget.sync.members.any((m) => m.id == member)
          ? l10n.membersRemovePending
          : error is ServerUnavailableException
          ? l10n.membersRemoveOffline
          : l10n.membersRemoveFailed;
    } finally {
      release?.call();
    }
    if (!mounted) return;
    setState(() {
      _removing = null;
      _problem = problem;
    });
    if (problem == null) {
      messenger?.showSnackBar(SnackBar(content: Text(l10n.membersRemoved)));
    }
  }
}
