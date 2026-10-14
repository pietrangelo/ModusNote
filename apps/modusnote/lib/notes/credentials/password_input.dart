import 'package:flutter/material.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../theme/golden_ratio.dart';
import 'password_generator_sheet.dart';
import 'secret_clipboard.dart';

/// A password field: masked until the person asks to see it, copied
/// without showing it (and taken off the clipboard again), and filled by
/// the generator. No suggestions, no autocorrect and no autofill: the
/// keyboard and the system's password manager never learn it.
class PasswordInput extends StatefulWidget {
  const PasswordInput({
    required this.label,
    required this.error,
    required this.value,
    required this.onChanged,
    super.key,
  });

  final String label;
  final String? error;
  final FieldValue? value;
  final ValueChanged<FieldValue?> onChanged;

  @override
  State<PasswordInput> createState() => _PasswordInputState();
}

class _PasswordInputState extends State<PasswordInput> {
  late final _controller = TextEditingController(
    text: switch (widget.value) {
      SecretValue(:final text) => text,
      _ => '',
    },
  );
  var _shown = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _report(String text) =>
      widget.onChanged(text.isEmpty ? null : SecretValue(text));

  Future<void> _copy() async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    await SecretClipboard.copy(_controller.text);
    messenger?.showSnackBar(SnackBar(content: Text(l10n.passwordCopied)));
  }

  Future<void> _generate() async {
    final password = await showPasswordGenerator(context);
    if (password == null || !mounted) return;
    _controller.text = password.text;
    _report(password.text);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final empty = _controller.text.isEmpty;
    return TextField(
      key: const ValueKey('password-field'),
      controller: _controller,
      obscureText: !_shown,
      autocorrect: false,
      enableSuggestions: false,
      enableIMEPersonalizedLearning: false,
      keyboardType: TextInputType.visiblePassword,
      maxLines: 1,
      decoration: InputDecoration(
        labelText: widget.label,
        errorText: widget.error,
        suffixIcon: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              key: const ValueKey('password-visibility'),
              icon: Icon(
                _shown
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
                size: IconSizes.inline,
              ),
              tooltip: _shown ? l10n.passwordHide : l10n.passwordShow,
              onPressed: () => setState(() => _shown = !_shown),
            ),
            IconButton(
              key: const ValueKey('password-copy'),
              icon: const Icon(Icons.copy, size: IconSizes.inline),
              tooltip: l10n.passwordCopy,
              onPressed: empty ? null : _copy,
            ),
            IconButton(
              key: const ValueKey('password-generate'),
              icon: const Icon(Icons.password, size: IconSizes.inline),
              tooltip: l10n.passwordGenerate,
              onPressed: _generate,
            ),
          ],
        ),
      ),
      onChanged: (text) {
        setState(() {});
        _report(text);
      },
    );
  }
}
