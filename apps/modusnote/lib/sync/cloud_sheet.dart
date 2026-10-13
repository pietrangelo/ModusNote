import 'package:flutter/material.dart';

import '../l10n/generated/app_localizations.dart';
import '../theme/golden_ratio.dart';
import '../theme/modus_colors.dart';
import '../vault/auto_lock.dart';
import 'sign_in_form.dart';
import 'sync_controller.dart';

/// The library's sync button: its icon tells the sync state, a tap opens
/// [CloudSheet].
class CloudButton extends StatelessWidget {
  const CloudButton({required this.sync, this.onLinkDevice, super.key});

  final SyncController sync;

  /// Opens the linking of another device; null where linking is not
  /// offered.
  final VoidCallback? onLinkDevice;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: sync,
      builder: (context, _) => IconButton(
        key: const ValueKey('cloud'),
        tooltip: l10n.cloudSync,
        onPressed: () =>
            CloudSheet.show(context, sync, onLinkDevice: onLinkDevice),
        icon: Icon(switch (sync.state) {
          SyncState.signedOut => Icons.cloud_off_outlined,
          SyncState.syncing => Icons.cloud_sync_outlined,
          SyncState.synced => Icons.cloud_done_outlined,
          SyncState.offline => Icons.cloud_off,
          SyncState.failed => Icons.error_outline,
        }),
      ),
    );
  }
}

/// Signs in with a code sent by email, then shows how the sync is doing
/// and, where it is offered, links another device of the same account.
class CloudSheet extends StatefulWidget {
  const CloudSheet({required this.sync, this.onLinkDevice, super.key});

  final SyncController sync;
  final VoidCallback? onLinkDevice;

  static Future<void> show(
    BuildContext context,
    SyncController sync, {
    VoidCallback? onLinkDevice,
  }) {
    final autoLock = AutoLockScope.maybeOf(context);
    final sheet = CloudSheet(sync: sync, onLinkDevice: onLinkDevice);
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
            child: widget.sync.signedIn
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: _status(context),
                  )
                : SignInForm(
                    title: l10n.cloudSync,
                    body: l10n.cloudSignInBody,
                    sendCode: widget.sync.sendCode,
                    signIn: widget.sync.signIn,
                    onTyped: () => AutoLockScope.maybeOf(context)?.touch(),
                  ),
          ),
        ),
      ),
    );
  }

  List<Widget> _status(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final sync = widget.sync;
    final state = switch (sync.state) {
      SyncState.signedOut || SyncState.syncing => l10n.cloudStateSyncing,
      SyncState.synced => l10n.cloudStateSynced(
        MaterialLocalizations.of(context)
            .formatTimeOfDay(TimeOfDay.fromDateTime(sync.lastSynced!)),
      ),
      SyncState.offline => l10n.cloudStateOffline,
      SyncState.failed => switch (sync.problem) {
        SyncProblem.untrusted => l10n.cloudStateUntrusted,
        SyncProblem.refused || null => l10n.cloudStateRefused,
      },
    };
    final syncing = sync.state == SyncState.syncing;
    return [
      _title(context),
      const SizedBox(height: Spacing.m),
      Text(
        l10n.cloudSignedInAs(sync.email ?? ''),
        style: Theme.of(context).textTheme.bodyMedium,
      ),
      const SizedBox(height: Spacing.s),
      Text(
        state,
        key: const ValueKey('cloud-state'),
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: sync.state == SyncState.failed
              ? Theme.of(context).colorScheme.error
              : ModusColors.dustSilver,
        ),
      ),
      const SizedBox(height: Spacing.l),
      FilledButton.icon(
        onPressed: syncing ? null : sync.syncNow,
        icon: const Icon(Icons.sync),
        label: Text(l10n.cloudSyncNow),
      ),
      const SizedBox(height: Spacing.s),
      if (widget.onLinkDevice case final link?) ...[
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
      ],
      const SizedBox(height: Spacing.s),
      OutlinedButton(
        onPressed: syncing ? null : sync.signOut,
        child: Text(l10n.cloudSignOut),
      ),
    ];
  }

  Widget _title(BuildContext context) => Text(
    AppLocalizations.of(context).cloudSync,
    style: Theme.of(context).textTheme.headlineSmall,
  );
}
