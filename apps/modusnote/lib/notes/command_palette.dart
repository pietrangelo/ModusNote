import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/generated/app_localizations.dart';
import '../theme/golden_ratio.dart';

/// Something the palette can do: open a note, start one, go somewhere.
@immutable
final class PaletteCommand {
  const PaletteCommand({
    required this.icon,
    required this.label,
    required this.run,
    this.color,
    this.detail,
  });

  final IconData icon;
  final Color? color;
  final String label;

  /// A second line: a note's date, say.
  final String? detail;
  final VoidCallback run;
}

/// Find a note or run a command from the keyboard, as in a desktop notes
/// app: type, move with the arrows, Enter to run, Escape to close.
/// [search] gives the commands for a query, best first; the palette shows
/// at most [shown] of them.
class CommandPalette extends StatefulWidget {
  const CommandPalette({required this.search, super.key});

  final List<PaletteCommand> Function(String query) search;

  static const shown = 8;

  /// Ctrl+P, or ⌘P on Apple platforms.
  static SingleActivator get activator =>
      SingleActivator(LogicalKeyboardKey.keyP, control: !_apple, meta: _apple);

  static bool get _apple =>
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.iOS;

  /// The button's tooltip, with its shortcut.
  static String tooltip(AppLocalizations l10n) =>
      '${l10n.commandPalette} (${_apple ? '⌘P' : 'Ctrl+P'})';

  /// Shows the palette and runs what is picked once it has closed.
  static Future<void> show(
    BuildContext context,
    List<PaletteCommand> Function(String query) search,
  ) async {
    final picked = await showDialog<PaletteCommand>(
      context: context,
      builder: (_) => CommandPalette(search: search),
    );
    picked?.run();
  }

  @override
  State<CommandPalette> createState() => _CommandPaletteState();
}

class _CommandPaletteState extends State<CommandPalette> {
  var _results = const <PaletteCommand>[];
  var _choice = 0;
  final _chosen = GlobalKey();

  @override
  void initState() {
    super.initState();
    _search('');
  }

  void _search(String query) => setState(() {
    _results = widget.search(query).take(CommandPalette.shown).toList();
    _choice = 0;
  });

  void _move(int by) {
    if (_results.isEmpty) return;
    setState(() => _choice = (_choice + by) % _results.length);
    // The choice stays in sight when the list is longer than the box.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final chosen = _chosen.currentContext;
      if (chosen != null && chosen.mounted) Scrollable.ensureVisible(chosen);
    });
  }

  /// Set once a command is picked: Enter may arrive both as a key and as
  /// the field's submit, and only one may close the palette.
  var _picked = false;

  void _run([int? index]) {
    final at = index ?? _choice;
    if (_picked || at >= _results.length) return;
    _picked = true;
    Navigator.of(context).pop(_results[at]);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Dialog(
      alignment: Alignment.topCenter,
      insetPadding: const EdgeInsets.fromLTRB(
        Spacing.l,
        Spacing.xxl,
        Spacing.l,
        Spacing.l,
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: Extents.xxl,
          maxHeight: Extents.xxl,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(Spacing.m),
              child: CallbackShortcuts(
                bindings: {
                  const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
                      _move(1),
                  const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
                      _move(-1),
                  const SingleActivator(LogicalKeyboardKey.enter): _run,
                  const SingleActivator(LogicalKeyboardKey.numpadEnter): _run,
                },
                child: TextField(
                  autofocus: true,
                  decoration: InputDecoration(
                    hintText: l10n.paletteHint,
                    prefixIcon: const Icon(Icons.search),
                  ),
                  onChanged: _search,
                  onSubmitted: (_) => _run(),
                ),
              ),
            ),
            if (_results.isEmpty)
              Padding(
                padding: const EdgeInsets.all(Spacing.l),
                child: Text(
                  l10n.noResults,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.labelMedium,
                ),
              )
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.only(bottom: Spacing.s),
                  itemCount: _results.length,
                  itemBuilder: (context, index) {
                    final command = _results[index];
                    return ListTile(
                      key: index == _choice ? _chosen : null,
                      leading: Icon(command.icon, color: command.color),
                      title: Text(
                        command.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: command.detail == null
                          ? null
                          : Text(command.detail!, maxLines: 1),
                      selected: index == _choice,
                      onTap: () => _run(index),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}
