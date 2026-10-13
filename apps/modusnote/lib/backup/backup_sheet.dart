import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:offline_sync/offline_sync.dart';

import '../l10n/generated/app_localizations.dart';
import '../theme/golden_ratio.dart';
import '../vault/auto_lock.dart';
import 'file_exchange.dart';

/// What the backup sheet does, filled by the vault gate for the open vault.
final class BackupTools {
  const BackupTools({
    required this.files,
    required this.secretFrom,
    required this.export,
    required this.open,
    required this.restore,
    required this.markdown,
  });

  final FileExchange files;

  /// Moves typed UTF-8 into a secret and wipes the buffer.
  final PasswordSecret Function(Uint8List utf8Bytes) secretFrom;

  /// The sealed backup of the open vault, under the secret (consumed).
  final Future<Uint8List> Function(PasswordSecret phrase) export;

  /// Opens a backup file with the secret (consumed).
  final Future<BackupContents> Function(Uint8List file, PasswordSecret phrase)
  open;

  /// Writes what the vault lacks, then shows it.
  final Future<BackupRestore> Function(BackupContents backup) restore;

  /// Every note as Markdown files in a ZIP, in clear.
  final Uint8List Function(DateTime at) markdown;

  /// The largest backup file the restore reads into memory.
  static const maxFile = 512 * 1024 * 1024;

  static const extension = 'mnbackup';
}

/// Offers the encrypted backup, its restore, and the Markdown export.
Future<void> showBackupSheet(BuildContext context, BackupTools tools) async {
  final l10n = AppLocalizations.of(context);
  final picked = await showModalBottomSheet<_Action>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * LayoutSplit.primary,
        ),
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Spacing.l,
                0,
                Spacing.l,
                Spacing.s,
              ),
              child: Text(
                l10n.backupTitle,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            for (final (action, icon, title, hint) in [
              (
                _Action.export,
                Icons.lock_outline,
                l10n.backupExport,
                l10n.backupExportHint,
              ),
              (
                _Action.restore,
                Icons.settings_backup_restore,
                l10n.backupRestore,
                l10n.backupRestoreHint,
              ),
              (
                _Action.markdown,
                Icons.description_outlined,
                l10n.markdownExport,
                l10n.markdownExportHint,
              ),
            ])
              ListTile(
                key: ValueKey('backup-${action.name}'),
                leading: Icon(icon),
                title: Text(title),
                subtitle: Text(hint),
                onTap: () => Navigator.of(context).pop(action),
              ),
            const SizedBox(height: Spacing.m),
          ],
        ),
      ),
    ),
  );
  if (picked == null || !context.mounted) return;
  final release = AutoLockScope.maybeOf(context)?.hold();
  try {
    await switch (picked) {
      _Action.export => _export(context, tools),
      _Action.restore => _restore(context, tools),
      _Action.markdown => _markdown(context, tools),
    };
  } finally {
    release?.call();
  }
}

enum _Action { export, restore, markdown }

String _stamp(DateTime at) =>
    '${at.year}-${'${at.month}'.padLeft(2, '0')}-'
    '${'${at.day}'.padLeft(2, '0')}';

Future<void> _export(BuildContext context, BackupTools tools) async {
  final l10n = AppLocalizations.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final phrase = await _askPhrase(context, tools, confirm: true);
  if (phrase == null || !context.mounted) return;
  final file = await _working(context, () => tools.export(phrase));
  await tools.files.save(
    'modus-notes-${_stamp(DateTime.now())}.${BackupTools.extension}',
    'application/octet-stream',
    file,
  );
  messenger.showSnackBar(SnackBar(content: Text(l10n.backupSaved)));
}

Future<void> _restore(BuildContext context, BackupTools tools) async {
  final l10n = AppLocalizations.of(context);
  final messenger = ScaffoldMessenger.of(context);
  void say(String text) => messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));
  final Uint8List? file;
  try {
    file = await tools.files.pick(
      accept: '.${BackupTools.extension}',
      maxBytes: BackupTools.maxFile,
    );
  } on FileTooLargeException {
    say(l10n.backupTooLarge);
    return;
  }
  if (file == null || !context.mounted) return;
  final phrase = await _askPhrase(context, tools, confirm: false);
  if (phrase == null || !context.mounted) return;
  try {
    final restored = await _working(context, () async {
      final backup = await tools.open(file!, phrase);
      return tools.restore(backup);
    });
    say(l10n.backupRestored(restored.added, restored.kept));
  } on BackupRejectedException {
    say(l10n.backupRejected);
  }
}

Future<void> _markdown(BuildContext context, BackupTools tools) async {
  final l10n = AppLocalizations.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final go = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      icon: const Icon(Icons.lock_open),
      title: Text(l10n.markdownWarningTitle),
      content: Text(l10n.markdownWarningBody),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(l10n.markdownExportAction),
        ),
      ],
    ),
  );
  if (go != true) return;
  final now = DateTime.now();
  await tools.files.save(
    'modus-notes-${_stamp(now)}.zip',
    'application/zip',
    tools.markdown(now),
  );
  messenger.showSnackBar(SnackBar(content: Text(l10n.markdownSaved)));
}

/// Runs [work] behind a progress dialog that cannot be dismissed: Argon2id
/// holds the UI for a moment.
Future<T> _working<T>(BuildContext context, Future<T> Function() work) async {
  final navigator = Navigator.of(context);
  unawaited(
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => PopScope(
        canPop: false,
        child: AlertDialog(
          content: Row(
            children: [
              const CircularProgressIndicator(),
              const SizedBox(width: Spacing.l),
              Expanded(child: Text(AppLocalizations.of(context).backupWorking)),
            ],
          ),
        ),
      ),
    ),
  );
  try {
    // Two frames, so the dialog is on screen before the work holds the UI.
    await WidgetsBinding.instance.endOfFrame;
    await WidgetsBinding.instance.endOfFrame;
    return await work();
  } finally {
    navigator.pop();
  }
}

/// Asks for the backup's phrase (twice when [confirm]); the typed text
/// becomes a secret at once and the fields are emptied.
Future<PasswordSecret?> _askPhrase(
  BuildContext context,
  BackupTools tools, {
  required bool confirm,
}) => showDialog<PasswordSecret>(
  context: context,
  builder: (_) => _PhraseDialog(tools: tools, confirm: confirm),
);

class _PhraseDialog extends StatefulWidget {
  const _PhraseDialog({required this.tools, required this.confirm});

  final BackupTools tools;
  final bool confirm;

  @override
  State<_PhraseDialog> createState() => _PhraseDialogState();
}

class _PhraseDialogState extends State<_PhraseDialog> {
  final _phrase = TextEditingController();
  final _again = TextEditingController();
  String? _problem;

  @override
  void dispose() {
    _phrase
      ..clear()
      ..dispose();
    _again
      ..clear()
      ..dispose();
    super.dispose();
  }

  void _done() {
    final l10n = AppLocalizations.of(context);
    final typed = Uint8List.fromList(utf8.encode(_phrase.text));
    if (widget.confirm && typed.length < PassphrasePolicy.minimumBytes) {
      typed.fillRange(0, typed.length, 0);
      setState(
        () => _problem = l10n.passphraseTooShort(PassphrasePolicy.minimumBytes),
      );
      return;
    }
    if (widget.confirm && _again.text != _phrase.text) {
      typed.fillRange(0, typed.length, 0);
      setState(() => _problem = l10n.backupPhraseMismatch);
      return;
    }
    _phrase.clear();
    _again.clear();
    Navigator.of(context).pop(widget.tools.secretFrom(typed));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l10n.backupPhraseTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.confirm) ...[
            Text(l10n.backupPhraseHint),
            const SizedBox(height: Spacing.m),
          ],
          TextField(
            key: const ValueKey('backup-phrase'),
            controller: _phrase,
            obscureText: true,
            autofocus: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(labelText: l10n.backupPhraseTitle),
            onSubmitted: widget.confirm ? null : (_) => _done(),
          ),
          if (widget.confirm)
            TextField(
              key: const ValueKey('backup-phrase-again'),
              controller: _again,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: l10n.backupPhraseConfirm,
                errorText: _problem,
              ),
              onSubmitted: (_) => _done(),
            )
          else if (_problem != null)
            Text(_problem!),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancel),
        ),
        FilledButton(onPressed: _done, child: Text(l10n.backupPhraseDone)),
      ],
    );
  }
}
