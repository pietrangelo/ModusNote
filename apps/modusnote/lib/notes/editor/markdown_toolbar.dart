import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../theme/golden_ratio.dart';
import 'markdown_commands.dart';
import 'markdown_controller.dart';

typedef MarkdownCommand = TextEditingValue Function(TextEditingValue);

/// One formatting action: its icon, its name and its key.
final class MarkdownAction {
  const MarkdownAction(
    this.icon,
    this.label,
    this.command,
    this.key, {
    this.shift = false,
    this.alt = false,
  });

  final IconData icon;
  final String Function(AppLocalizations) label;
  final MarkdownCommand command;
  final LogicalKeyboardKey key;
  final bool shift;
  final bool alt;

  /// Cmd on Apple platforms, Ctrl elsewhere.
  static bool get _apple =>
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.iOS;

  SingleActivator get activator =>
      SingleActivator(key, control: !_apple, meta: _apple, shift: shift);

  String tooltip(AppLocalizations l10n) {
    final keys = [
      _apple ? '⌘' : 'Ctrl',
      if (alt) _apple ? '⌥' : 'Alt',
      if (shift) _apple ? '⇧' : 'Shift',
      key.keyLabel.toUpperCase(),
    ].join(_apple ? '' : '+');
    return '${label(l10n)} ($keys)';
  }

  static final all = <MarkdownAction>[
    MarkdownAction(
      Icons.title,
      (l) => l.markdownHeading,
      MarkdownCommands.heading,
      LogicalKeyboardKey.keyH,
      shift: true,
    ),
    MarkdownAction(
      Icons.format_bold,
      (l) => l.markdownBold,
      MarkdownCommands.bold,
      LogicalKeyboardKey.keyB,
    ),
    MarkdownAction(
      Icons.format_italic,
      (l) => l.markdownItalic,
      MarkdownCommands.italic,
      LogicalKeyboardKey.keyI,
    ),
    MarkdownAction(
      Icons.format_strikethrough,
      (l) => l.markdownStrike,
      MarkdownCommands.strike,
      LogicalKeyboardKey.keyX,
      shift: true,
    ),
    MarkdownAction(
      Icons.checklist,
      (l) => l.markdownTasks,
      MarkdownCommands.tasks,
      LogicalKeyboardKey.digit9,
      shift: true,
    ),
    MarkdownAction(
      Icons.format_list_bulleted,
      (l) => l.markdownBullets,
      MarkdownCommands.bullets,
      LogicalKeyboardKey.digit8,
      shift: true,
    ),
    MarkdownAction(
      Icons.format_list_numbered,
      (l) => l.markdownNumbered,
      MarkdownCommands.numbered,
      LogicalKeyboardKey.digit7,
      shift: true,
    ),
    MarkdownAction(
      Icons.format_quote,
      (l) => l.markdownQuote,
      MarkdownCommands.quote,
      LogicalKeyboardKey.period,
      shift: true,
    ),
    MarkdownAction(
      Icons.code,
      (l) => l.markdownCode,
      MarkdownCommands.code,
      LogicalKeyboardKey.keyE,
    ),
    MarkdownAction(
      Icons.data_object,
      (l) => l.markdownCodeBlock,
      MarkdownCommands.codeBlock,
      // Ctrl+Shift+C opens the browser's inspector.
      LogicalKeyboardKey.keyC,
      alt: true,
    ),
    MarkdownAction(
      Icons.link,
      (l) => l.markdownLink,
      MarkdownCommands.link,
      LogicalKeyboardKey.keyK,
    ),
    MarkdownAction(
      Icons.horizontal_rule,
      (l) => l.markdownRule,
      MarkdownCommands.rule,
      LogicalKeyboardKey.minus,
      shift: true,
    ),
  ];
}

/// The formatting buttons of a Markdown field, in one scrolling row.
class MarkdownToolbar extends StatelessWidget {
  const MarkdownToolbar({
    required this.controller,
    this.onLinkNote,
    this.onInsertImage,
    super.key,
  });

  /// The field the buttons edit; it reports the change like typing.
  final MarkdownEditingController controller;

  /// Picks a note and links to it; null where there are no notes to link.
  final VoidCallback? onLinkNote;

  /// Picks a picture and puts it in the text; null where pictures cannot
  /// be kept.
  final VoidCallback? onInsertImage;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: Spacing.s),
      child: Row(
        children: [
          if (onLinkNote case final onLinkNote?)
            IconButton(
              key: const ValueKey('link-note'),
              tooltip: l10n.linkNote,
              icon: const Icon(Icons.add_link, size: IconSizes.inline),
              onPressed: onLinkNote,
            ),
          if (onInsertImage case final onInsertImage?)
            IconButton(
              key: const ValueKey('insert-image'),
              tooltip: l10n.insertImage,
              icon: const Icon(Icons.image_outlined, size: IconSizes.inline),
              onPressed: onInsertImage,
            ),
          for (final action in MarkdownAction.all)
            IconButton(
              tooltip: action.tooltip(l10n),
              icon: Icon(action.icon, size: IconSizes.inline),
              onPressed: () => controller.apply(action.command),
            ),
        ],
      ),
    );
  }
}
