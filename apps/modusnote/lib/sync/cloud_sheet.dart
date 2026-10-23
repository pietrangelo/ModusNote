import 'package:collaboration_access_control/collaboration_access_control.dart';
import 'package:flutter/material.dart';
import 'package:offline_sync/offline_sync.dart';
import 'package:offline_sync_adapters/offline_sync_adapters.dart';

import '../l10n/generated/app_localizations.dart';
import '../theme/golden_ratio.dart';
import '../vault/auto_lock.dart';
import 'members_sheet.dart';
import 'sync_controller.dart';
import '../theme/modus_palette.dart';

/// The library's sync button: its icon tells the sync state, a tap opens
/// [CloudSheet].
class CloudButton extends StatelessWidget {
  const CloudButton({
    required this.sync,
    this.onLinkDevice,
    this.onInvite,
    super.key,
  });

  final SyncController sync;

  /// Opens the linking of another device; null where linking is not
  /// offered.
  final VoidCallback? onLinkDevice;

  /// Opens the invitation of another person; null where not offered.
  final VoidCallback? onInvite;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: sync,
      builder: (context, _) => IconButton(
        key: const ValueKey('cloud'),
        tooltip: l10n.cloudTooltip(sync.state.name),
        onPressed: () => CloudSheet.show(
          context,
          sync,
          onLinkDevice: onLinkDevice,
          onInvite: onInvite,
        ),
        icon: Icon(switch (sync.state) {
          SyncState.off => Icons.cloud_off_outlined,
          SyncState.syncing => Icons.cloud_sync_outlined,
          SyncState.synced => Icons.cloud_done_outlined,
          SyncState.offline => Icons.cloud_off,
          SyncState.failed => Icons.error_outline,
        }),
      ),
    );
  }
}

/// Turns the sync on, then shows how it is doing and, for an owner, links
/// another device, invites a person or deletes the vault from the server.
class CloudSheet extends StatefulWidget {
  const CloudSheet({
    required this.sync,
    this.onLinkDevice,
    this.onInvite,
    super.key,
  });

  final SyncController sync;
  final VoidCallback? onLinkDevice;
  final VoidCallback? onInvite;

  static Future<void> show(
    BuildContext context,
    SyncController sync, {
    VoidCallback? onLinkDevice,
    VoidCallback? onInvite,
  }) {
    final autoLock = AutoLockScope.maybeOf(context);
    final sheet = CloudSheet(
      sync: sync,
      onLinkDevice: onLinkDevice,
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
  State<CloudSheet> createState() => _CloudSheetState();
}

class _CloudSheetState extends State<CloudSheet> {
  var _enabling = false;
  var _deleting = false;
  String? _deleteProblem;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: widget.sync,
      builder: (context, _) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(Spacing.l),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: widget.sync.retired
                  ? [
                      _title(context),
                      const SizedBox(height: Spacing.m),
                      Text(
                        l10n.cloudServerDeleted,
                        key: const ValueKey('cloud-retired'),
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ]
                  : widget.sync.enabled
                  ? _status(context)
                  : _off(context),
            ),
          ),
        ),
      ),
    );
  }

  /// A new vault stays on the device until its person turns the sync on.
  List<Widget> _off(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return [
      _title(context),
      const SizedBox(height: Spacing.m),
      Text(l10n.cloudOffBody, style: Theme.of(context).textTheme.bodyMedium),
      const SizedBox(height: Spacing.l),
      FilledButton.icon(
        key: const ValueKey('cloud-enable'),
        onPressed: _enabling ? null : _enable,
        icon: const Icon(Icons.cloud_upload_outlined),
        label: Text(l10n.cloudEnable),
      ),
    ];
  }

  Future<void> _enable() async {
    setState(() => _enabling = true);
    try {
      await widget.sync.enable();
    } on VaultLockedException {
      // Locked meanwhile: the sheet closes with the vault.
    } finally {
      if (mounted) setState(() => _enabling = false);
    }
  }

  List<Widget> _status(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final sync = widget.sync;
    final state = switch (sync.state) {
      SyncState.off || SyncState.syncing => l10n.cloudStateSyncing,
      SyncState.synced => l10n.cloudStateSynced(
        MaterialLocalizations.of(context)
            .formatTimeOfDay(TimeOfDay.fromDateTime(sync.lastSynced!)),
      ),
      SyncState.offline => l10n.cloudStateOffline,
      SyncState.failed => switch (sync.problem) {
        SyncProblem.untrusted => l10n.cloudStateUntrusted,
        SyncProblem.full => l10n.cloudStateFull,
        SyncProblem.removed => l10n.cloudStateRemoved,
        SyncProblem.notAdmitted => l10n.cloudStateNotAdmitted,
        SyncProblem.refused || null => l10n.cloudStateRefused,
      },
    };
    final syncing = sync.state == SyncState.syncing;
    return [
      _title(context),
      const SizedBox(height: Spacing.m),
      Semantics(
        liveRegion: true,
        child: Text(
          state,
          key: const ValueKey('cloud-state'),
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: sync.state == SyncState.failed
                ? Theme.of(context).colorScheme.error
                : ModusPalette.of(context).muted,
          ),
        ),
      ),
      const SizedBox(height: Spacing.l),
      FilledButton.icon(
        onPressed: syncing ? null : sync.syncNow,
        icon: const Icon(Icons.sync),
        label: Text(l10n.cloudSyncNow),
      ),
      const SizedBox(height: Spacing.s),
      if (widget.onLinkDevice case final link? when sync.managesMembers) ...[
        const SizedBox(height: Spacing.s),
        OutlinedButton.icon(
          key: const ValueKey('link-device'),
          onPressed: sync.state == SyncState.synced
              ? () {
                  Navigator.of(context).pop();
                  link();
                }
              : null,
          icon: const Icon(Icons.devices_outlined),
          label: Text(l10n.linkDeviceAction),
        ),
        if (sync.state != SyncState.synced) ...[
          const SizedBox(height: Spacing.xs),
          Text(
            l10n.cloudNeedsSync,
            key: const ValueKey('link-device-hint'),
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: ModusPalette.of(context).muted),
          ),
        ],
      ],
      const SizedBox(height: Spacing.s),
      OutlinedButton.icon(
        key: const ValueKey('members'),
        onPressed: () =>
            MembersSheet.show(context, sync, onInvite: widget.onInvite),
        icon: const Icon(Icons.group_outlined),
        label: Text(l10n.membersAction),
      ),
      if (sync.managesMembers) ...[
        const SizedBox(height: Spacing.l),
        TextButton.icon(
          key: const ValueKey('delete-server'),
          style: TextButton.styleFrom(
            foregroundColor: Theme.of(context).colorScheme.error,
          ),
          onPressed: _deleting ? null : _deleteFromServer,
          icon: _deleting
              ? const SizedBox.square(
                  dimension: Spacing.m,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.delete_forever_outlined),
          label: Text(l10n.cloudDeleteServer),
        ),
      ],
      if (_deleteProblem case final problem?) ...[
        const SizedBox(height: Spacing.s),
        Semantics(
          liveRegion: true,
          child: Text(
            problem,
            key: const ValueKey('delete-server-problem'),
            style: Theme.of(context).textTheme.bodyMedium
                ?.copyWith(color: Theme.of(context).colorScheme.error),
          ),
        ),
      ],
    ];
  }

  /// Asks first: nothing brings the server's copy back. The notes stay on
  /// the devices.
  Future<void> _deleteFromServer() async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.delete_forever_outlined),
        title: Text(l10n.cloudDeleteServerTitle),
        content: Text(l10n.cloudDeleteServerBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            key: const ValueKey('delete-server-confirm'),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.cloudDeleteServerConfirm),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _deleting = true;
      _deleteProblem = null;
    });
    // The keys stay while the request is out: the vault records the
    // deletion when it comes back.
    final release = AutoLockScope.maybeOf(context)?.hold();
    String? problem;
    try {
      await widget.sync.deleteFromServer();
    } on ServerUnavailableException {
      problem = l10n.cloudDeleteServerOffline;
    } on SyncServerRejectedException {
      problem = l10n.cloudDeleteServerRefused;
    } on NotAdmittedException {
      problem = l10n.cloudDeleteServerRefused;
    } on NotAuthorizedException {
      problem = l10n.cloudDeleteServerRefused;
    } on VaultLockedException {
      return;
    } finally {
      release?.call();
    }
    if (mounted) {
      setState(() {
        _deleting = false;
        _deleteProblem = problem;
      });
    }
  }

  Widget _title(BuildContext context) => Text(
    AppLocalizations.of(context).cloudSync,
    style: Theme.of(context).textTheme.headlineSmall,
  );
}
