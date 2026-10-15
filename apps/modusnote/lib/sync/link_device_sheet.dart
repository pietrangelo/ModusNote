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

/// A one-time code on show and the offer behind it: [poll] admits whoever
/// answers with the code, [cancel] withdraws it.
typedef CodeAdmission = ({
  String code,
  Future<MemberId?> Function() poll,
  VoidCallback cancel,
});

/// The texts of a [CodeAdmissionPanel], which differ between linking one's
/// own device and inviting another person.
typedef CodeAdmissionTexts = ({
  String instructions,
  String waiting,
  String done,
  String refused,
  String untrusted,
});

/// Shows a one-time code for another device of the same account to type,
/// and admits that device into this vault's workspace once it answers.
///
/// The vault stays open while the sheet is up (the code lasts ten minutes
/// at most); closing the sheet withdraws the code.
class LinkDeviceSheet extends StatelessWidget {
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
  }) =>
      showHeldSheet(context, LinkDeviceSheet(offer: offer, onLinked: onLinked));

  Future<CodeAdmission> _start() async {
    final code = LinkCode.random(Random.secure());
    final offering = await offer(code);
    return (code: code.display, poll: offering.poll, cancel: offering.cancel);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return CodeSheetFrame(
      title: l10n.linkDeviceTitle,
      child: CodeAdmissionPanel(
        start: _start,
        onAdmitted: onLinked,
        pollEvery: pollEvery,
        texts: (
          instructions: l10n.linkDeviceInstructions,
          waiting: l10n.linkDeviceWaiting,
          done: l10n.linkDeviceDone,
          refused: l10n.linkDeviceRefused,
          untrusted: l10n.linkDeviceUntrusted,
        ),
      ),
    );
  }
}

/// Shows [sheet] with the vault held open until it closes.
Future<void> showHeldSheet(BuildContext context, Widget sheet) async {
  final autoLock = AutoLockScope.maybeOf(context);
  final release = autoLock?.hold();
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

/// The title, the content and the close button of a code sheet.
class CodeSheetFrame extends StatelessWidget {
  const CodeSheetFrame({required this.title, required this.child, super.key});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(Spacing.l),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: Spacing.m),
            child,
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

/// Makes a code, shows it and polls for the answer until someone is
/// admitted, the code expires or the panel goes away (which withdraws it).
class CodeAdmissionPanel extends StatefulWidget {
  const CodeAdmissionPanel({
    required this.start,
    required this.texts,
    this.onAdmitted,
    this.pollEvery = const Duration(seconds: 2),
    super.key,
  });

  /// Makes a new code and posts its offer.
  final Future<CodeAdmission> Function() start;
  final CodeAdmissionTexts texts;
  final VoidCallback? onAdmitted;
  final Duration pollEvery;

  @override
  State<CodeAdmissionPanel> createState() => _CodeAdmissionPanelState();
}

enum _Stage { preparing, showing, linked, failed }

enum _Problem { expired, unreachable, refused, untrusted }

class _CodeAdmissionPanelState extends State<CodeAdmissionPanel> {
  var _stage = _Stage.preparing;
  _Problem? _problem;
  CodeAdmission? _admission;
  Timer? _next;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  @override
  void dispose() {
    _next?.cancel();
    _admission?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    _admission?.cancel();
    setState(() {
      _stage = _Stage.preparing;
      _problem = null;
      _admission = null;
    });
    // Let the progress indicator paint before Argon2id holds the isolate.
    await Future<void>.delayed(Duration.zero);
    final CodeAdmission admission;
    try {
      admission = await widget.start();
    } on Object catch (error) {
      return _failed(error);
    }
    if (!mounted) return admission.cancel();
    setState(() {
      _admission = admission;
      _stage = _Stage.showing;
    });
    _schedule();
  }

  void _schedule() => _next = Timer(widget.pollEvery, _poll);

  Future<void> _poll() async {
    final admission = _admission;
    if (admission == null || !mounted) return;
    try {
      if (await admission.poll() == null) {
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
    widget.onAdmitted?.call();
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
    final texts = widget.texts;
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(
      color: ModusColors.dustSilver,
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: switch (_stage) {
        _Stage.preparing => [
          Text(l10n.linkDevicePreparing, style: muted),
          const SizedBox(height: Spacing.l),
          const Center(child: CircularProgressIndicator()),
        ],
        _Stage.showing => [
          Text(texts.instructions, style: muted),
          const SizedBox(height: Spacing.l),
          SelectableText(
            _admission!.code,
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
              Flexible(child: Text(texts.waiting, style: muted)),
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
                  texts.done,
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
              _Problem.refused => texts.refused,
              _Problem.untrusted => texts.untrusted,
            },
            key: const ValueKey('link-problem'),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
          const SizedBox(height: Spacing.l),
          FilledButton(onPressed: _start, child: Text(l10n.linkDeviceNewCode)),
        ],
      },
    );
  }
}
