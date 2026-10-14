import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../theme/golden_ratio.dart';
import '../attachments/attachment_dialogs.dart';
import '../attachments/attachments_input.dart';

/// A web address: "example.com" is kept as "https://example.com", what is
/// not an http or https address stays as typed so the field shows the
/// error. It opens only from its button, after showing the whole address.
class UrlInput extends StatefulWidget {
  const UrlInput({
    required this.label,
    required this.error,
    required this.value,
    required this.onChanged,
    this.openLink,
    super.key,
  });

  final String label;
  final String? error;
  final FieldValue? value;
  final ValueChanged<FieldValue?> onChanged;

  /// Opens a confirmed address; null where links cannot be opened.
  final LinkOpener? openLink;

  @override
  State<UrlInput> createState() => _UrlInputState();
}

class _UrlInputState extends State<UrlInput> {
  late final _controller = TextEditingController(
    text: switch (widget.value) {
      TextValue(:final text) => text,
      _ => '',
    },
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  WebLink? get _link => WebLink.parse(_controller.text);

  Future<void> _open(WebLink link, LinkOpener openLink) async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    if (!await confirmOpenLink(context, link)) return;
    if (!await openLink(Uri.parse(link.url))) {
      messenger.showSnackBar(SnackBar(content: Text(l10n.openLinkFailed)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final link = _link;
    final openLink = widget.openLink;
    return TextField(
      key: const ValueKey('url-field'),
      controller: _controller,
      autocorrect: false,
      enableSuggestions: false,
      keyboardType: TextInputType.url,
      inputFormatters: [FilteringTextInputFormatter.singleLineFormatter],
      decoration: InputDecoration(
        labelText: widget.label,
        errorText: widget.error,
        suffixIcon: openLink == null
            ? null
            : IconButton(
                key: const ValueKey('url-open'),
                icon: const Icon(Icons.open_in_new, size: IconSizes.inline),
                tooltip: l10n.linkOpen,
                onPressed: link == null ? null : () => _open(link, openLink),
              ),
      ),
      onChanged: (text) {
        setState(() {});
        final trimmed = text.trim();
        widget.onChanged(
          trimmed.isEmpty
              ? null
              : TextValue(WebLink.parse(trimmed)?.url ?? trimmed),
        );
      },
    );
  }
}
