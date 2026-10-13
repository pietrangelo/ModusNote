import 'dart:async';
import 'dart:math';

import 'package:collaboration_access_control/collaboration_access_control.dart';
import 'package:flutter/material.dart';
import 'package:offline_sync/offline_sync.dart';
import 'package:offline_sync_adapters/offline_sync_adapters.dart';

import '../l10n/generated/app_localizations.dart';
import '../theme/golden_ratio.dart';
import '../theme/modus_colors.dart';
import '../vault/auto_lock.dart';

/// Shows a one-time code for another device of the same account to type,
/// and admits that device into this vault's workspace once it answers.
///
/// The vault stays open while the sheet is up (the code lasts ten minutes
/// at most); closing the sheet withdraws the code.
class LinkDeviceSheet extends StatefulWidget {
  const LinkDeviceSheet({
    required this.offer,
    this.onLinked,
    this.pollEvery = const Duration(seconds: 2),
    super.key,
  });

  /// Posts the offer for [code]; see [VaultKeeper.offerLink].
  final Future<LinkOffering> Function(LinkCode code) offer;

  /// Called once a device was admitted, to sync it the keys at once.
  final VoidCallback? onLinked;
  final Duration pollEvery;

  static Future<void> show(
    BuildContext context, {
    required Future<LinkOffering> Function(LinkCode code) offer,
    VoidCallback? onLinked,
  }) async {
    final autoLock = AutoLockScope.maybeOf(context);
    final release = autoLock?.hold();
    final sheet = LinkDeviceSheet(offer: offer, onLinked: onLinked);
    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (_) => autoLock == null
            ? sheet
            : AutoLockScope(autoLock: autoLock, child: sheet),
      );
    } finally {
      release?.call();
    }
  }

  @override
  State<LinkDeviceSheet> createState() => _LinkDeviceSheetState();
}

enum _Stage { preparing, showing, linked, failed }

enum _Problem { expired, unreachable, refused, untrusted }

class _LinkDeviceSheetState extends State<LinkDeviceSheet> {
  var _stage = _Stage.preparing;
  _Problem? _problem;
  LinkCode? _code;
  LinkOffering? _offering;
  Timer? _next;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  @override
  void dispose() {
    _next?.cancel();
    _offering?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    _offering?.cancel();
    final code = LinkCode.random(Random.secure());
    setState(() {
      _stage = _Stage.preparing;
      _problem = null;
      _code = null;
    });
    // Let the progress indicator paint before Argon2id holds the isolate.
    await Future<void>.delayed(Duration.zero);
    final LinkOffering offering;
    try {
      offering = await widget.offer(code);
    } on Object catch (error) {
      return _failed(error);
    }
    if (!mounted) return offering.cancel();
    setState(() {
      _offering = offering;
      _code = code;
      _stage = _Stage.showing;
    });
    _schedule();
  }

  void _schedule() => _next = Timer(widget.pollEvery, _poll);

  Future<void> _poll() async {
    final offering = _offering;
    if (offering == null || !mounted) return;
    try {
      if (await offering.poll() == null) {
        if (mounted) _schedule();
        return;
      }
    } on ServerUnavailableException {
      // No network for a moment: the answer waits on the server.
      if (mounted) _schedule();
      return;
    } on Object catch (error) {
      return _failed(error);
    }
    if (!mounted) return;
    setState(() => _stage = _Stage.linked);
    widget.onLinked?.call();
  }

  void _failed(Object error) {
    final problem = switch (error) {
      LinkExpiredException() => _Problem.expired,
      ServerUnavailableException() => _Problem.unreachable,
      SyncServerRejectedException() => _Problem.refused,
      LedgerRollbackException() ||
      TamperedWorkspaceDataException() ||
      MalformedSyncDataException() => _Problem.untrusted,
      // Locked meanwhile: the sheet closes with the vault.
      VaultLockedException() => null,
      _ => throw error,
    };
    if (!mounted || problem == null) return;
    setState(() {
      _stage = _Stage.failed;
      _problem = problem;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(
      color: ModusColors.dustSilver,
    );
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(Spacing.l),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l10n.linkDeviceTitle, style: theme.textTheme.headlineSmall),
            const SizedBox(height: Spacing.m),
            ...switch (_stage) {
              _Stage.preparing => [
                Text(l10n.linkDevicePreparing, style: muted),
                const SizedBox(height: Spacing.l),
                const Center(child: CircularProgressIndicator()),
              ],
              _Stage.showing => [
                Text(l10n.linkDeviceInstructions, style: muted),
                const SizedBox(height: Spacing.l),
                SelectableText(
                  _code!.display,
                  key: const ValueKey('link-code'),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineMedium?.copyWith(
                    color: ModusColors.aureoGold,
                  ),
                ),
                const SizedBox(height: Spacing.l),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const SizedBox.square(
                      dimension: IconSizes.inline,
                      child: CircularProgressIndicator(),
                    ),
                    const SizedBox(width: Spacing.m),
                    Flexible(child: Text(l10n.linkDeviceWaiting, style: muted)),
                  ],
                ),
              ],
              _Stage.linked => [
                Row(
                  children: [
                    const Icon(
                      Icons.check_circle_outline,
                      color: ModusColors.cadenceCyan,
                    ),
                    const SizedBox(width: Spacing.m),
                    Expanded(
                      child: Text(
                        l10n.linkDeviceDone,
                        key: const ValueKey('link-done'),
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                  ],
                ),
              ],
              _Stage.failed => [
                Text(
                  switch (_problem!) {
                    _Problem.expired => l10n.linkDeviceExpired,
                    _Problem.unreachable => l10n.cloudUnreachable,
                    _Problem.refused => l10n.linkDeviceRefused,
                    _Problem.untrusted => l10n.linkDeviceUntrusted,
                  },
                  key: const ValueKey('link-problem'),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
                const SizedBox(height: Spacing.l),
                FilledButton(
                  onPressed: _start,
                  child: Text(l10n.linkDeviceNewCode),
                ),
              ],
            },
            const SizedBox(height: Spacing.s),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(l10n.dialogClose),
            ),
          ],
        ),
      ),
    );
  }
}
