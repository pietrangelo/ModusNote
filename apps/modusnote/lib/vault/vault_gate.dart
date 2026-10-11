import 'dart:convert';
import 'dart:typed_data';

import 'package:collaboration_access_control/collaboration_access_control.dart';
import 'package:flutter/material.dart';
import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:offline_sync/offline_sync.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import '../audio/note_playback.dart';
import '../audio/note_recorder.dart';
import '../l10n/generated/app_localizations.dart';
import '../notes/note_library.dart';
import '../theme/golden_ratio.dart';
import '../theme/modus_colors.dart';
import 'vault_note_store.dart';

/// Moves a UTF-8 passphrase into native memory and wipes the buffer.
typedef PasswordFactory = PasswordSecret Function(Uint8List utf8Bytes);

/// The app's front door: creates the vault on first launch, asks for the
/// passphrase afterwards, and shows the notes only while it is unlocked.
class VaultGate extends StatefulWidget {
  const VaultGate({
    required this.keeper,
    required this.passwordFrom,
    required this.schemas,
    this.recorderFor,
    this.playbackFor,
    super.key,
  });

  final VaultKeeper keeper;
  final PasswordFactory passwordFrom;
  final List<SchemaDefinition> schemas;

  /// Builds the recorder for an unlocked vault; without it notes cannot
  /// hold recordings.
  final NoteRecorder Function(SyncEngine engine)? recorderFor;

  /// Builds the player's opener for an unlocked vault; without it
  /// recordings show their length but cannot be played.
  final NotePlayback Function(SyncEngine engine)? playbackFor;

  @override
  State<VaultGate> createState() => _VaultGateState();
}

sealed class _Stage {
  const _Stage();
}

final class _Checking extends _Stage {
  const _Checking();
}

final class _Locked extends _Stage {
  const _Locked({required this.exists});

  final bool exists;
}

final class _Open extends _Stage {
  const _Open(this.vault, this.store);

  final UnlockedVault vault;
  final VaultNoteStore store;
}

enum _Problem { tooShort, mismatch, wrong, damaged }

class _VaultGateState extends State<VaultGate> {
  _Stage _stage = const _Checking();
  _Problem? _problem;
  var _busy = false;
  final _passphrase = TextEditingController();
  final _confirmation = TextEditingController();

  @override
  void initState() {
    super.initState();
    widget.keeper.exists.then((exists) {
      if (mounted) setState(() => _stage = _Locked(exists: exists));
    });
  }

  @override
  void dispose() {
    if (_stage case _Open(:final vault)) vault.lock();
    _passphrase.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  Future<void> _submit({required bool creating}) async {
    final mismatch = creating && _passphrase.text != _confirmation.text;
    // The String in a TextField cannot be wiped, only dropped quickly: it
    // is turned into a native secret and the fields are cleared at once.
    final bytes = Uint8List.fromList(utf8.encode(_passphrase.text));
    _passphrase.clear();
    _confirmation.clear();
    if (mismatch) {
      bytes.fillRange(0, bytes.length, 0);
      setState(() => _problem = _Problem.mismatch);
      return;
    }
    final PasswordSecret password;
    try {
      password = widget.passwordFrom(bytes);
    } on WeakPassphraseException {
      setState(() => _problem = _Problem.tooShort);
      return;
    }
    setState(() {
      _busy = true;
      _problem = null;
    });
    // Let the progress indicator paint before Argon2id holds the isolate.
    await Future<void>.delayed(Duration.zero);
    try {
      final vault = creating
          ? await widget.keeper.create(password)
          : await widget.keeper.unlock(password);
      final store = await VaultNoteStore.open(
        vault.engine,
        schemas: widget.schemas,
        recorder: widget.recorderFor?.call(vault.engine),
        playback: widget.playbackFor?.call(vault.engine),
      );
      if (!mounted) {
        vault.lock();
        return;
      }
      setState(() => _stage = _Open(vault, store));
    } on WrongPassphraseException {
      _fail(_Problem.wrong);
    } on TamperedWorkspaceDataException {
      _fail(_Problem.damaged);
    } on MalformedSyncDataException {
      _fail(_Problem.damaged);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _fail(_Problem problem) {
    if (mounted) setState(() => _problem = problem);
  }

  void _lock() {
    if (_stage case _Open(:final vault, :final store)) {
      vault.lock();
      store.dispose();
      setState(() => _stage = const _Locked(exists: true));
    }
  }

  @override
  Widget build(BuildContext context) => switch (_stage) {
    _Checking() => const Scaffold(
      body: Center(child: CircularProgressIndicator()),
    ),
    _Open(:final store) => NoteLibraryScreen(
      schemas: widget.schemas,
      store: store,
      onLock: _lock,
    ),
    _Locked(:final exists) => _form(context, creating: !exists),
  };

  Widget _form(BuildContext context, {required bool creating}) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final problem = switch (_problem) {
      null => null,
      _Problem.tooShort => l10n.passphraseTooShort(
        PassphrasePolicy.minimumBytes,
      ),
      _Problem.mismatch => l10n.passphraseMismatch,
      _Problem.wrong => l10n.passphraseWrong,
      _Problem.damaged => l10n.vaultDamaged,
    };
    final submit = _busy ? null : () => _submit(creating: creating);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(Spacing.l),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: Extents.xl),
              child: AutofillGroup(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(
                      Icons.lock_outline,
                      size: IconSizes.prominent,
                      color: ModusColors.aureoGold,
                    ),
                    const SizedBox(height: Spacing.l),
                    Text(
                      creating ? l10n.vaultCreateTitle : l10n.vaultUnlockTitle,
                      style: theme.textTheme.headlineMedium,
                      textAlign: TextAlign.center,
                    ),
                    if (creating) ...[
                      const SizedBox(height: Spacing.m),
                      Text(
                        l10n.vaultCreateBody,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: ModusColors.dustSilver,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                    const SizedBox(height: Spacing.xl),
                    _PassphraseField(
                      key: const ValueKey('passphrase'),
                      controller: _passphrase,
                      label: l10n.passphraseLabel,
                      enabled: !_busy,
                      onSubmitted: creating ? null : submit,
                    ),
                    if (creating) ...[
                      const SizedBox(height: Spacing.m),
                      _PassphraseField(
                        key: const ValueKey('passphrase-confirm'),
                        controller: _confirmation,
                        label: l10n.passphraseConfirmLabel,
                        enabled: !_busy,
                        onSubmitted: submit,
                      ),
                    ],
                    if (problem != null) ...[
                      const SizedBox(height: Spacing.m),
                      Text(
                        problem,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                    const SizedBox(height: Spacing.l),
                    FilledButton(
                      onPressed: submit,
                      child: Text(
                        creating
                            ? l10n.vaultCreateAction
                            : l10n.vaultUnlockAction,
                      ),
                    ),
                    if (_busy) ...[
                      const SizedBox(height: Spacing.l),
                      const Center(child: CircularProgressIndicator()),
                      const SizedBox(height: Spacing.s),
                      Text(
                        l10n.vaultOpening,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: ModusColors.dustSilver,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PassphraseField extends StatelessWidget {
  const _PassphraseField({
    required this.controller,
    required this.label,
    required this.enabled,
    required this.onSubmitted,
    super.key,
  });

  final TextEditingController controller;
  final String label;
  final bool enabled;
  final VoidCallback? onSubmitted;

  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    enabled: enabled,
    obscureText: true,
    autocorrect: false,
    enableSuggestions: false,
    keyboardType: TextInputType.visiblePassword,
    autofillHints: const [AutofillHints.password],
    decoration: InputDecoration(labelText: label),
    onSubmitted: onSubmitted == null ? null : (_) => onSubmitted!(),
  );
}
