import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:offline_sync/offline_sync.dart';

import '../l10n/generated/app_localizations.dart';
import '../theme/golden_ratio.dart';
import 'passphrase_field.dart';
import 'second_factor.dart';

/// Asks the person to prove again that the open [vault] is theirs, with
/// its passphrase or, where one is enrolled, the [factor], before an
/// action that gives lasting access to it: whoever only found the vault
/// open must not give themselves a way back in. Skipped while an earlier
/// confirmation lasts ([VaultKeeper.confirmationLifetime]).
///
/// The dialog does not hold the auto-lock, which closes it like any other
/// screen; [hold] keeps the vault open only while the person is at the
/// authenticator, whose prompt can send the app to the background.
///
/// Returns whether the vault is now confirmed.
Future<bool> confirmHolder(
  BuildContext context, {
  required VaultKeeper keeper,
  required UnlockedVault vault,
  required PasswordSecret Function(Uint8List utf8Bytes) passwordFrom,
  required SecondFactor factor,
  required VoidCallback Function() hold,
}) async {
  if (keeper.isConfirmed(vault)) return true;
  final enrolled = await keeper.hasPasskey;
  if (!context.mounted) return false;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (_) => _ConfirmDialog(
      keeper: keeper,
      vault: vault,
      passwordFrom: passwordFrom,
      factor: enrolled ? factor : null,
      hold: hold,
    ),
  );
  return confirmed ?? false;
}

class _ConfirmDialog extends StatefulWidget {
  const _ConfirmDialog({
    required this.keeper,
    required this.vault,
    required this.passwordFrom,
    required this.factor,
    required this.hold,
  });

  final VaultKeeper keeper;
  final UnlockedVault vault;
  final PasswordSecret Function(Uint8List utf8Bytes) passwordFrom;

  /// Offered next to the passphrase when enrolled.
  final SecondFactor? factor;
  final VoidCallback Function() hold;

  @override
  State<_ConfirmDialog> createState() => _ConfirmDialogState();
}

class _ConfirmDialogState extends State<_ConfirmDialog> {
  final _typed = TextEditingController();
  var _busy = false;
  String? _problem;

  @override
  void dispose() {
    _typed.dispose();
    super.dispose();
  }

  Future<void> _withPassphrase() async {
    final l10n = AppLocalizations.of(context);
    // As on the lock screen: the String is dropped at once.
    final bytes = Uint8List.fromList(utf8.encode(_typed.text));
    _typed.clear();
    final PasswordSecret password;
    try {
      password = widget.passwordFrom(bytes);
    } on WeakPassphraseException {
      // Shorter than any passphrase a vault can have: simply wrong.
      setState(() => _problem = l10n.passphraseWrong);
      return;
    }
    await _run(() => widget.keeper.confirm(widget.vault, password));
  }

  Future<void> _withFactor() => _run(() async {
    final release = widget.hold();
    try {
      await widget.keeper.confirmWithPasskey(widget.vault);
    } finally {
      release();
    }
  });

  Future<void> _run(Future<void> Function() confirming) async {
    final l10n = AppLocalizations.of(context);
    final factor = widget.factor ?? SecondFactor.passkey;
    setState(() {
      _busy = true;
      _problem = null;
    });
    // Let the progress indicator paint before Argon2id holds the isolate.
    await Future<void>.delayed(Duration.zero);
    String? problem;
    try {
      await confirming();
      if (mounted) Navigator.of(context).pop(true);
      return;
    } on WrongPassphraseException {
      problem = l10n.passphraseWrong;
    } on PasskeyCancelledException {
      problem = factor.cancelled(l10n);
    } on PasskeyRejectedException {
      problem = factor.rejected(l10n);
    } on PasskeyUnsupportedException {
      problem = factor.unsupported(l10n);
    } on NoPasskeyException {
      problem = factor.unsupported(l10n);
    } on VaultLockedException {
      if (mounted) Navigator.of(context).pop(false);
      return;
    }
    if (mounted) {
      setState(() {
        _busy = false;
        _problem = problem;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final factor = widget.factor;
    return AlertDialog(
      icon: const Icon(Icons.shield_outlined),
      title: Text(l10n.confirmTitle),
      // Scrolls when the keyboard leaves little room.
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l10n.confirmBody),
          const SizedBox(height: Spacing.m),
          PassphraseField(
            key: const ValueKey('confirm-passphrase'),
            controller: _typed,
            label: l10n.passphraseLabel,
            enabled: !_busy,
            onSubmitted: _withPassphrase,
          ),
          if (_problem case final problem?) ...[
            const SizedBox(height: Spacing.s),
            Text(
              problem,
              key: const ValueKey('confirm-problem'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          if (_busy) ...[
            const SizedBox(height: Spacing.m),
            const LinearProgressIndicator(),
          ],
          if (factor != null) ...[
            const SizedBox(height: Spacing.m),
            OutlinedButton.icon(
              key: const ValueKey('confirm-factor'),
              onPressed: _busy ? null : _withFactor,
              icon: const Icon(Icons.fingerprint, size: IconSizes.inline),
              label: Text(factor.confirmAction(l10n)),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          key: const ValueKey('confirm-submit'),
          onPressed: _busy ? null : _withPassphrase,
          child: Text(l10n.confirmAction),
        ),
      ],
    );
  }
}
