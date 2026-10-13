import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:offline_sync/offline_sync.dart';
import 'package:offline_sync_adapters/offline_sync_adapters.dart';

import '../l10n/generated/app_localizations.dart';
import '../theme/golden_ratio.dart';
import '../theme/modus_colors.dart';
import '../vault/auto_lock.dart';
import 'sync_controller.dart';

/// The library's sync button: its icon tells the sync state, a tap opens
/// [CloudSheet].
class CloudButton extends StatelessWidget {
  const CloudButton({required this.sync, super.key});

  final SyncController sync;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: sync,
      builder: (context, _) => IconButton(
        key: const ValueKey('cloud'),
        tooltip: l10n.cloudSync,
        onPressed: () => CloudSheet.show(context, sync),
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

/// Signs in with a code sent by email, then shows how the sync is doing.
/// The email goes to the sync server only; the passphrase is never asked
/// for here.
class CloudSheet extends StatefulWidget {
  const CloudSheet({required this.sync, super.key});

  final SyncController sync;

  static Future<void> show(BuildContext context, SyncController sync) {
    final autoLock = AutoLockScope.maybeOf(context);
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => autoLock == null
          ? CloudSheet(sync: sync)
          : AutoLockScope(
              autoLock: autoLock,
              child: CloudSheet(sync: sync),
            ),
    );
  }

  @override
  State<CloudSheet> createState() => _CloudSheetState();
}

enum _Problem {
  emailInvalid,
  codeInvalid,
  emailRefused,
  codeRefused,
  unreachable,
  damaged,
}

class _CloudSheetState extends State<CloudSheet> {
  final _email = TextEditingController();
  final _code = TextEditingController();

  /// Where the code was sent; null until it was.
  String? _sentTo;
  _Problem? _problem;
  var _busy = false;

  @override
  void dispose() {
    _email.dispose();
    _code.dispose();
    super.dispose();
  }

  /// Local checks only; the server has the last word on the address.
  static final _emailShape = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');
  static final _codeShape = RegExp(r'^\d{6,10}$');

  Future<void> _sendCode() async {
    final email = _email.text.trim();
    if (email.length > 254 || !_emailShape.hasMatch(email)) {
      return setState(() => _problem = _Problem.emailInvalid);
    }
    await _run(() async {
      await widget.sync.sendCode(email);
      _sentTo = email;
    }, refused: _Problem.emailRefused);
  }

  Future<void> _signIn() async {
    final code = _code.text.trim();
    final email = _sentTo;
    if (email == null) return;
    if (!_codeShape.hasMatch(code)) {
      return setState(() => _problem = _Problem.codeInvalid);
    }
    await _run(() async {
      await widget.sync.signIn(email, code);
      _code.clear();
      _sentTo = null;
    }, refused: _Problem.codeRefused);
  }

  Future<void> _run(
    Future<void> Function() action, {
    required _Problem refused,
  }) async {
    setState(() {
      _busy = true;
      _problem = null;
    });
    _Problem? problem;
    try {
      await action();
    } on SupabaseAuthRejectedException {
      problem = refused;
    } on ServerUnavailableException {
      problem = _Problem.unreachable;
    } on MalformedSyncDataException {
      problem = _Problem.damaged;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _problem = problem;
    });
  }

  void _touched(String _) => AutoLockScope.maybeOf(context)?.touch();

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.sync,
    builder: (context, _) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(Spacing.l),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: widget.sync.signedIn
                ? _status(context)
                : _sentTo == null
                ? _askEmail(context)
                : _askCode(context),
          ),
        ),
      ),
    ),
  );

  List<Widget> _askEmail(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return [
      _title(context),
      const SizedBox(height: Spacing.m),
      _muted(context, l10n.cloudSignInBody),
      const SizedBox(height: Spacing.l),
      TextField(
        key: const ValueKey('cloud-email'),
        controller: _email,
        enabled: !_busy,
        keyboardType: TextInputType.emailAddress,
        autofillHints: const [AutofillHints.email],
        autocorrect: false,
        decoration: InputDecoration(labelText: l10n.cloudEmailLabel),
        onChanged: _touched,
        onSubmitted: (_) => _sendCode(),
      ),
      ..._problemText(context),
      const SizedBox(height: Spacing.l),
      FilledButton(
        onPressed: _busy ? null : _sendCode,
        child: Text(l10n.cloudSendCode),
      ),
      ..._progress(),
    ];
  }

  List<Widget> _askCode(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return [
      _title(context),
      const SizedBox(height: Spacing.m),
      _muted(context, l10n.cloudCodeSent(_sentTo!)),
      const SizedBox(height: Spacing.l),
      TextField(
        key: const ValueKey('cloud-code'),
        controller: _code,
        enabled: !_busy,
        keyboardType: TextInputType.number,
        autofillHints: const [AutofillHints.oneTimeCode],
        inputFormatters: [
          FilteringTextInputFormatter.digitsOnly,
          LengthLimitingTextInputFormatter(10),
        ],
        decoration: InputDecoration(labelText: l10n.cloudCodeLabel),
        onChanged: _touched,
        onSubmitted: (_) => _signIn(),
      ),
      ..._problemText(context),
      const SizedBox(height: Spacing.l),
      FilledButton(
        onPressed: _busy ? null : _signIn,
        child: Text(l10n.cloudSignIn),
      ),
      const SizedBox(height: Spacing.s),
      TextButton(
        onPressed: _busy
            ? null
            : () => setState(() {
                _sentTo = null;
                _problem = null;
                _code.clear();
              }),
        child: Text(l10n.cloudChangeEmail),
      ),
      ..._progress(),
    ];
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
      const SizedBox(height: Spacing.m),
      _muted(context, l10n.cloudOneDevice),
      const SizedBox(height: Spacing.l),
      FilledButton.icon(
        onPressed: syncing ? null : sync.syncNow,
        icon: const Icon(Icons.sync),
        label: Text(l10n.cloudSyncNow),
      ),
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

  Widget _muted(BuildContext context, String text) => Text(
    text,
    style: Theme.of(context).textTheme.bodyMedium
        ?.copyWith(color: ModusColors.dustSilver),
  );

  List<Widget> _problemText(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final text = switch (_problem) {
      null => null,
      _Problem.emailInvalid => l10n.cloudEmailInvalid,
      _Problem.codeInvalid => l10n.cloudCodeInvalid,
      _Problem.emailRefused => l10n.cloudEmailRefused,
      _Problem.codeRefused => l10n.cloudCodeRefused,
      _Problem.unreachable => l10n.cloudUnreachable,
      _Problem.damaged => l10n.cloudUnreachable,
    };
    if (text == null) return const [];
    return [
      const SizedBox(height: Spacing.m),
      Text(
        text,
        key: const ValueKey('cloud-problem'),
        style: Theme.of(context).textTheme.bodyMedium
            ?.copyWith(color: Theme.of(context).colorScheme.error),
      ),
    ];
  }

  List<Widget> _progress() => [
    if (_busy) ...[
      const SizedBox(height: Spacing.l),
      const Center(child: CircularProgressIndicator()),
    ],
  ];
}
