import 'dart:math';

import 'package:flutter/material.dart';
import 'package:offline_sync/offline_sync.dart';

import '../l10n/generated/app_localizations.dart';
import '../theme/golden_ratio.dart';
import '../theme/modus_colors.dart';

/// Shows a vault's name and opens the vault picker; [created] is false while
/// the vault has no database yet, the only time it can be removed.
typedef ShelfSwitcher = Widget Function({required bool created});

/// One vault on the shelf, its storage opened by the platform.
final class ShelfVault {
  ShelfVault({
    required this.build,
    required this.close,
    required this.erase,
    required this.isEmpty,
  });

  /// The vault's gate, with [ShelfSwitcher] on its lock screen.
  final Widget Function(ShelfSwitcher switcher) build;

  /// Releases the storage once the gate is gone.
  final Future<void> Function() close;

  /// Closes the storage and deletes it from the device.
  final Future<void> Function() erase;

  /// True while no vault was created or joined here.
  final Future<bool> Function() isEmpty;
}

/// The vaults kept on this device, one open at a time: each [VaultShelf]
/// entry has its own database, recordings, passphrase and workspace, and
/// [open] makes the gate for one of them.
///
/// Switching happens only from a lock screen, so a vault is always locked
/// when its gate goes away; the storage is closed after the gate is gone
/// and before the next vault's is opened.
class VaultShelfGate extends StatefulWidget {
  const VaultShelfGate({
    required this.store,
    required this.open,
    this.random,
    super.key,
  });

  final ShelfStore store;
  final Future<ShelfVault> Function(ShelfEntry entry) open;

  /// For tests; ids come from [Random.secure] otherwise.
  final Random? random;

  @override
  State<VaultShelfGate> createState() => _VaultShelfGateState();
}

class _VaultShelfGateState extends State<VaultShelfGate> {
  VaultShelf? _shelf;
  ShelfVault? _vault;
  var _changing = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    final shelf = await widget.store.load();
    final vault = await widget.open(shelf.current);
    if (!mounted) {
      await vault.close();
      return;
    }
    setState(() {
      _shelf = shelf;
      _vault = vault;
    });
  }

  @override
  void dispose() {
    _vault?.close();
    super.dispose();
  }

  /// Takes the current gate down, lets [release] close or erase its
  /// storage, then opens the shelf's current vault.
  Future<void> _replace(
    VaultShelf next,
    Future<void> Function(ShelfVault old) release,
  ) async {
    if (_changing) return;
    final old = _vault!;
    setState(() {
      _changing = true;
      _vault = null;
    });
    // The old gate is disposed when this frame is built.
    await WidgetsBinding.instance.endOfFrame;
    try {
      var shelf = next;
      try {
        await release(old);
        await widget.store.save(next);
      } on Object {
        // Storage that could not be closed, erased or recorded: stay on
        // the vault that was there.
        shelf = _shelf!;
      }
      final vault = await widget.open(shelf.current);
      if (!mounted) {
        await vault.close();
        return;
      }
      setState(() {
        _shelf = shelf;
        _vault = vault;
      });
    } finally {
      if (mounted) setState(() => _changing = false);
    }
  }

  Future<void> _choose({required bool created}) async {
    final shelf = _shelf!;
    final choice = await showShelfPicker(
      context,
      shelf: shelf,
      removable: !created && shelf.lastOpened != ShelfId.first,
    );
    if (!mounted || choice == null || _changing) return;
    switch (choice) {
      case ShelfOpen(:final id) when id != shelf.lastOpened:
        await _replace(shelf.open(id), (old) => old.close());
      case ShelfOpen():
        break;
      case ShelfAdd(:final label):
        final (next, _) = shelf.add(label, widget.random ?? Random.secure());
        await _replace(next, (old) => old.close());
      case ShelfRename(:final id, :final label):
        final next = shelf.rename(id, label);
        await widget.store.save(next);
        if (mounted) setState(() => _shelf = next);
      case ShelfRemove():
        final id = shelf.lastOpened;
        // Checked again here: only a vault nothing was created in goes.
        if (id == ShelfId.first || !await _vault!.isEmpty()) return;
        await _replace(shelf.remove(id), (old) => old.erase());
    }
  }

  @override
  Widget build(BuildContext context) {
    final shelf = _shelf;
    final vault = _vault;
    if (shelf == null || vault == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return KeyedSubtree(
      key: ValueKey(shelf.lastOpened),
      child: vault.build(
        ({required created}) => ShelfButton(
          name: shelfName(AppLocalizations.of(context), shelf.current),
          onPressed: () => _choose(created: created),
        ),
      ),
    );
  }
}

/// A vault's name as the person sees it.
String shelfName(AppLocalizations l10n, ShelfEntry entry) =>
    entry.label ?? l10n.shelfDefaultName;

/// The current vault's name on a lock screen; a tap opens the picker.
class ShelfButton extends StatelessWidget {
  const ShelfButton({required this.name, required this.onPressed, super.key});

  final String name;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Center(
    child: TextButton.icon(
      key: const ValueKey('shelf'),
      onPressed: onPressed,
      icon: const Icon(Icons.inventory_2_outlined),
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              name,
              semanticsLabel: AppLocalizations.of(context).shelfSwitch(name),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const Icon(Icons.arrow_drop_down),
        ],
      ),
    ),
  );
}

/// What the person picked in the vault picker.
sealed class ShelfChoice {
  const ShelfChoice();
}

final class ShelfOpen extends ShelfChoice {
  const ShelfOpen(this.id);
  final ShelfId id;
}

final class ShelfAdd extends ShelfChoice {
  const ShelfAdd(this.label);
  final String label;
}

final class ShelfRename extends ShelfChoice {
  const ShelfRename(this.id, this.label);
  final ShelfId id;
  final String label;
}

final class ShelfRemove extends ShelfChoice {
  const ShelfRemove();
}

/// Lists the device's vaults: open another, rename one, add a new one, or
/// ([removable]) remove the current one, still empty.
Future<ShelfChoice?> showShelfPicker(
  BuildContext context, {
  required VaultShelf shelf,
  required bool removable,
}) => showModalBottomSheet<ShelfChoice>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final full = shelf.entries.length >= VaultShelf.maxVaults;
    return SafeArea(
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
                Spacing.xs,
              ),
              child: Text(l10n.shelfTitle, style: theme.textTheme.titleMedium),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Spacing.l,
                0,
                Spacing.l,
                Spacing.s,
              ),
              child: Text(
                l10n.shelfBody,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: ModusColors.dustSilver,
                ),
              ),
            ),
            for (final entry in shelf.entries)
              ListTile(
                key: ValueKey('shelf-${entry.id}'),
                contentPadding: const EdgeInsetsDirectional.only(
                  start: Spacing.l,
                  end: Spacing.s,
                ),
                leading: Icon(
                  entry.id == shelf.lastOpened
                      ? Icons.check
                      : Icons.inventory_2_outlined,
                  color: entry.id == shelf.lastOpened
                      ? ModusColors.aureoGold
                      : null,
                ),
                title: Text(
                  shelfName(l10n, entry),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: IconButton(
                  key: ValueKey('shelf-rename-${entry.id}'),
                  tooltip: l10n.shelfRename,
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: () async {
                    final label = await showShelfNameDialog(
                      context,
                      initial: shelfName(l10n, entry),
                    );
                    if (label != null && context.mounted) {
                      Navigator.of(context).pop(ShelfRename(entry.id, label));
                    }
                  },
                ),
                onTap: () => Navigator.of(context).pop(ShelfOpen(entry.id)),
              ),
            ListTile(
              key: const ValueKey('shelf-add'),
              enabled: !full,
              contentPadding: const EdgeInsets.symmetric(horizontal: Spacing.l),
              leading: const Icon(Icons.add),
              title: Text(l10n.shelfAdd),
              subtitle: full
                  ? Text(l10n.shelfFull(VaultShelf.maxVaults))
                  : null,
              onTap: () async {
                final label = await showShelfNameDialog(context);
                if (label != null && context.mounted) {
                  Navigator.of(context).pop(ShelfAdd(label));
                }
              },
            ),
            if (removable)
              ListTile(
                key: const ValueKey('shelf-remove'),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: Spacing.l,
                ),
                leading: const Icon(Icons.close),
                title: Text(l10n.shelfRemove),
                onTap: () => Navigator.of(context).pop(const ShelfRemove()),
              ),
            const SizedBox(height: Spacing.s),
          ],
        ),
      ),
    );
  },
);

/// Asks for a vault's name: a new one when [initial] is null. Returns the
/// name, already checked, or null when the person cancels.
Future<String?> showShelfNameDialog(BuildContext context, {String? initial}) =>
    showDialog<String>(
      context: context,
      builder: (_) => _ShelfNameDialog(initial: initial),
    );

class _ShelfNameDialog extends StatefulWidget {
  const _ShelfNameDialog({required this.initial});

  final String? initial;

  @override
  State<_ShelfNameDialog> createState() => _ShelfNameDialogState();
}

class _ShelfNameDialogState extends State<_ShelfNameDialog> {
  late final _name = TextEditingController(text: widget.initial ?? '');
  var _invalid = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _save() {
    final String label;
    try {
      label = ShelfEntry(id: ShelfId.first, label: _name.text, scope: 0).label!;
    } on InvalidShelfLabelException {
      setState(() => _invalid = true);
      return;
    }
    Navigator.of(context).pop(label);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final adding = widget.initial == null;
    return AlertDialog(
      title: Text(adding ? l10n.shelfAdd : l10n.shelfRename),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (adding) ...[
            Text(
              l10n.shelfAddBody,
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(color: ModusColors.dustSilver),
            ),
            const SizedBox(height: Spacing.m),
          ],
          TextField(
            key: const ValueKey('shelf-name'),
            controller: _name,
            autofocus: true,
            maxLength: ShelfEntry.maxLabel,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              labelText: l10n.shelfName,
              errorText: _invalid ? l10n.shelfNameInvalid : null,
              errorMaxLines: 2,
            ),
            onChanged: (_) {
              if (_invalid) setState(() => _invalid = false);
            },
            onSubmitted: (_) => _save(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          key: const ValueKey('shelf-name-save'),
          onPressed: _save,
          child: Text(adding ? l10n.shelfCreate : l10n.shelfSave),
        ),
      ],
    );
  }
}
