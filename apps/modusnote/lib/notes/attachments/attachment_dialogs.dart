import 'package:flutter/material.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../theme/golden_ratio.dart';

/// Asks for a link's address and title; null when the person cancels.
Future<WebLink?> showLinkDialog(BuildContext context, {WebLink? existing}) =>
    showDialog<WebLink>(
      context: context,
      builder: (_) => _LinkDialog(existing: existing),
    );

/// Asks for a picture's caption; null when the person cancels.
Future<String?> showCaptionDialog(
  BuildContext context, {
  required String initial,
}) => showDialog<String>(
  context: context,
  builder: (_) => _CaptionDialog(initial: initial),
);

/// Shows the whole address before it leaves the app; true to open it.
Future<bool> confirmOpenLink(BuildContext context, WebLink link) async {
  final l10n = AppLocalizations.of(context);
  final theme = Theme.of(context);
  final open = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(l10n.openLinkTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText(
            link.url,
            key: const ValueKey('link-address'),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(height: Spacing.m),
          Text(l10n.openLinkBody),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(l10n.openLink),
        ),
      ],
    ),
  );
  return open ?? false;
}

class _LinkDialog extends StatefulWidget {
  const _LinkDialog({required this.existing});

  final WebLink? existing;

  @override
  State<_LinkDialog> createState() => _LinkDialogState();
}

class _LinkDialogState extends State<_LinkDialog> {
  late final _address = TextEditingController(text: widget.existing?.url);
  late final _title = TextEditingController(text: widget.existing?.title);
  var _badAddress = false;
  var _badTitle = false;

  @override
  void dispose() {
    _address.dispose();
    _title.dispose();
    super.dispose();
  }

  void _save() {
    final address = WebLink.parse(_address.text);
    final link = WebLink.parse(_address.text, title: _title.text);
    if (link == null) {
      setState(() {
        _badAddress = address == null;
        _badTitle = address != null;
      });
      return;
    }
    Navigator.of(context).pop(link);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(
        widget.existing == null ? l10n.addLinkTitle : l10n.editLinkTitle,
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const ValueKey('link-address-field'),
              controller: _address,
              autofocus: widget.existing == null,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: l10n.linkAddress,
                errorText: _badAddress ? l10n.linkAddressInvalid : null,
                errorMaxLines: 3,
              ),
              onChanged: (_) {
                if (_badAddress) setState(() => _badAddress = false);
              },
            ),
            const SizedBox(height: Spacing.m),
            TextField(
              key: const ValueKey('link-title-field'),
              controller: _title,
              maxLength: Attachment.maxText,
              decoration: InputDecoration(
                labelText: l10n.linkTitle,
                errorText: _badTitle ? l10n.attachmentTextInvalid : null,
              ),
              onChanged: (_) {
                if (_badTitle) setState(() => _badTitle = false);
              },
              onSubmitted: (_) => _save(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancel),
        ),
        FilledButton(onPressed: _save, child: Text(l10n.attachmentSave)),
      ],
    );
  }
}

class _CaptionDialog extends StatefulWidget {
  const _CaptionDialog({required this.initial});

  final String initial;

  @override
  State<_CaptionDialog> createState() => _CaptionDialogState();
}

class _CaptionDialogState extends State<_CaptionDialog> {
  late final _caption = TextEditingController(text: widget.initial);
  var _invalid = false;

  @override
  void dispose() {
    _caption.dispose();
    super.dispose();
  }

  void _save() {
    try {
      // The same check the note will make.
      ImageAttachment(BlobId('check'), caption: _caption.text);
    } on InvalidValueException {
      setState(() => _invalid = true);
      return;
    }
    Navigator.of(context).pop(_caption.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l10n.editCaptionTitle),
      content: TextField(
        key: const ValueKey('caption-field'),
        controller: _caption,
        autofocus: true,
        maxLength: Attachment.maxText,
        textCapitalization: TextCapitalization.sentences,
        decoration: InputDecoration(
          labelText: l10n.imageCaption,
          errorText: _invalid ? l10n.attachmentTextInvalid : null,
        ),
        onChanged: (_) {
          if (_invalid) setState(() => _invalid = false);
        },
        onSubmitted: (_) => _save(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancel),
        ),
        FilledButton(onPressed: _save, child: Text(l10n.attachmentSave)),
      ],
    );
  }
}
