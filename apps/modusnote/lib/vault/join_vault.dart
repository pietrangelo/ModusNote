import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:collaboration_access_control/collaboration_access_control.dart';
import 'package:flutter/material.dart';
import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:offline_sync/offline_sync.dart';
import 'package:offline_sync_adapters/offline_sync_adapters.dart';

import '../l10n/generated/app_localizations.dart';
import '../sync/sign_in_form.dart';
import '../theme/golden_ratio.dart';
import 'passphrase_warning.dart';
import '../theme/modus_palette.dart';

/// First launch on a second device: signs in to the same account, takes
/// the code another device shows and a passphrase for this one, then waits
/// for that device to admit this one and opens the new vault.
class JoinVaultScreen extends StatefulWidget {
  const JoinVaultScreen({
    required this.account,
    required this.join,
    this.accept,
    required this.onJoined,
    required this.onBack,
    this.pollEvery = const Duration(seconds: 2),
    super.key,
  });

  /// Signed in here, before any vault exists to keep the session in.
  final SyncAccount account;

  /// Posts this device's answer; see [VaultKeeper.join]. The passphrase
  /// arrives as UTF-8, to be moved into native memory at once.
  final Future<LinkRequest> Function(LinkCode code, Uint8List passphrase) join;

  /// Posts this device's answer to another person's invitation; see
  /// [VaultKeeper.acceptInvite]. Null where invitations are not offered.
  final Future<LinkRequest> Function(InviteCode code, Uint8List secret)? accept;

  /// The vault was created; the gate takes it from here.
  final Future<void> Function(UnlockedVault vault) onJoined;
  final VoidCallback onBack;
  final Duration pollEvery;

  @override
  State<JoinVaultScreen> createState() => _JoinVaultScreenState();
}

enum _Problem {
  codeShape,
  codeRejected,
  tooShort,
  mismatch,
  expired,
  unreachable,
  refused,
  untrusted,
}

class _JoinVaultScreenState extends State<JoinVaultScreen> {
  final _code = TextEditingController();
  final _passphrase = TextEditingController();
  final _confirmation = TextEditingController();
  _Problem? _problem;
  bool _acknowledged = false;
  var _busy = false;
  LinkRequest? _request;
  Timer? _next;

  @override
  void dispose() {
    _next?.cancel();
    _request?.cancel();
    _code.dispose();
    _passphrase.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    // A link code (another device of this account) or an invitation (from
    // another person): their lengths tell them apart.
    final Object? code = switch (widget.accept) {
      null => LinkCode.tryParse(_code.text),
      _ => LinkCode.tryParse(_code.text) ?? InviteCode.tryParse(_code.text),
    };
    final mismatch = _passphrase.text != _confirmation.text;
    // As on the create form: the Strings are dropped at once.
    final bytes = Uint8List.fromList(utf8.encode(_passphrase.text));
    _passphrase.clear();
    _confirmation.clear();
    final problem = code == null
        ? _Problem.codeShape
        : mismatch
        ? _Problem.mismatch
        : null;
    if (problem != null) {
      bytes.fillRange(0, bytes.length, 0);
      return setState(() => _problem = problem);
    }
    setState(() {
      _busy = true;
      _problem = null;
    });
    // Let the progress indicator paint before Argon2id holds the isolate.
    await Future<void>.delayed(Duration.zero);
    try {
      final request = switch (code) {
        final InviteCode invite => await widget.accept!(invite, bytes),
        _ => await widget.join(code! as LinkCode, bytes),
      };
      if (!mounted) return request.cancel();
      _code.clear();
      setState(() => _request = request);
      _schedule();
    } on Object catch (error) {
      _failed(error);
    }
  }

  void _schedule() => _next = Timer(widget.pollEvery, _poll);

  Future<void> _poll() async {
    final request = _request;
    if (request == null || !mounted) return;
    final UnlockedVault? vault;
    try {
      vault = await request.poll();
    } on ServerUnavailableException {
      // No network for a moment: the other device's answer waits.
      if (mounted) _schedule();
      return;
    } on Object catch (error) {
      return _failed(error);
    }
    if (vault == null) {
      if (mounted) _schedule();
      return;
    }
    _request = null;
    await widget.onJoined(vault);
  }

  void _failed(Object error) {
    final problem = switch (error) {
      WeakPassphraseException() => _Problem.tooShort,
      LinkCodeRejectedException() => _Problem.codeRejected,
      LinkExpiredException() => _Problem.expired,
      ServerUnavailableException() => _Problem.unreachable,
      SyncServerRejectedException() => _Problem.refused,
      TamperedWorkspaceDataException() ||
      MalformedSyncDataException() ||
      MalformedWorkspaceDataException() ||
      LedgerRollbackException() => _Problem.untrusted,
      // Anything else still stops the wait, never a spinner forever.
      _ => _Problem.refused,
    };
    _next?.cancel();
    _request?.cancel();
    _request = null;
    if (!mounted) return;
    setState(() {
      _busy = false;
      _problem = problem;
    });
  }

  void _back() {
    _next?.cancel();
    _request?.cancel();
    _request = null;
    widget.onBack();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(Spacing.l),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: Extents.xl),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(
                    Icons.devices_outlined,
                    size: IconSizes.prominent,
                    color: ModusPalette.of(context).primary,
                  ),
                  const SizedBox(height: Spacing.l),
                  if (!widget.account.signedIn)
                    SignInForm(
                      title: l10n.joinVaultTitle,
                      body: l10n.joinVaultSignInBody,
                      sendCode: widget.account.sendCode,
                      signIn: (email, code) async {
                        await widget.account.signIn(email, code);
                        if (mounted) setState(() {});
                      },
                    )
                  else
                    ..._linkForm(context),
                  const SizedBox(height: Spacing.s),
                  TextButton(
                    key: const ValueKey('join-back'),
                    onPressed: _back,
                    child: Text(l10n.joinVaultBack),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _linkForm(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(
      color: ModusPalette.of(context).muted,
    );
    final problem = switch (_problem) {
      null => null,
      _Problem.codeShape => l10n.joinVaultCodeShape,
      _Problem.codeRejected => l10n.joinVaultCodeRejected,
      _Problem.tooShort => l10n.passphraseTooShort(
        PassphrasePolicy.minimumBytes,
      ),
      _Problem.mismatch => l10n.passphraseMismatch,
      _Problem.expired => l10n.joinVaultExpired,
      _Problem.unreachable => l10n.cloudUnreachable,
      _Problem.refused => l10n.cloudStateRefused,
      _Problem.untrusted => l10n.joinVaultUntrusted,
    };
    final waiting = _request != null;
    return [
      Text(
        l10n.joinVaultTitle,
        style: theme.textTheme.headlineMedium,
        textAlign: TextAlign.center,
      ),
      const SizedBox(height: Spacing.m),
      Text(
        waiting ? l10n.joinVaultWaiting : l10n.joinVaultBody,
        style: muted,
        textAlign: TextAlign.center,
      ),
      if (waiting) ...[
        const SizedBox(height: Spacing.l),
        const Center(child: CircularProgressIndicator()),
      ] else ...[
        const SizedBox(height: Spacing.xl),
        TextField(
          key: const ValueKey('join-code'),
          controller: _code,
          enabled: !_busy,
          autocorrect: false,
          enableSuggestions: false,
          textCapitalization: TextCapitalization.characters,
          decoration: InputDecoration(labelText: l10n.joinVaultCodeLabel),
        ),
        const SizedBox(height: Spacing.m),
        TextField(
          key: const ValueKey('passphrase'),
          controller: _passphrase,
          enabled: !_busy,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          keyboardType: TextInputType.visiblePassword,
          autofillHints: const [AutofillHints.newPassword],
          decoration: InputDecoration(labelText: l10n.passphraseLabel),
        ),
        const SizedBox(height: Spacing.m),
        TextField(
          key: const ValueKey('passphrase-confirm'),
          controller: _confirmation,
          enabled: !_busy,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          keyboardType: TextInputType.visiblePassword,
          decoration: InputDecoration(labelText: l10n.passphraseConfirmLabel),
          onSubmitted: _busy || !_acknowledged ? null : (_) => _submit(),
        ),
        const SizedBox(height: Spacing.l),
        PassphraseWarning(
          acknowledged: _acknowledged,
          enabled: !_busy,
          onChanged: (value) => setState(() => _acknowledged = value),
        ),
        if (problem != null) ...[
          const SizedBox(height: Spacing.m),
          Text(
            problem,
            key: const ValueKey('join-problem'),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.error,
            ),
            textAlign: TextAlign.center,
          ),
        ],
        const SizedBox(height: Spacing.l),
        FilledButton(
          key: const ValueKey('join-submit'),
          onPressed: _busy || !_acknowledged ? null : _submit,
          child: Text(l10n.joinVaultSubmit),
        ),
        if (_busy) ...[
          const SizedBox(height: Spacing.l),
          const Center(child: CircularProgressIndicator()),
        ],
      ],
    ];
  }
}
