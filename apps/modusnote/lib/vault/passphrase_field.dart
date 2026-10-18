import 'package:flutter/material.dart';

import '../l10n/generated/app_localizations.dart';
import '../theme/golden_ratio.dart';

/// A vault passphrase field, masked until the person asks to see it.
class PassphraseField extends StatefulWidget {
  const PassphraseField({
    required this.controller,
    required this.label,
    required this.enabled,
    this.onSubmitted,
    this.autofillHints = const [AutofillHints.password],
    super.key,
  });

  final TextEditingController controller;
  final String label;
  final bool enabled;
  final VoidCallback? onSubmitted;
  final Iterable<String>? autofillHints;

  @override
  State<PassphraseField> createState() => _PassphraseFieldState();
}

class _PassphraseFieldState extends State<PassphraseField> {
  var _shown = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final submitted = widget.onSubmitted;
    return TextField(
      controller: widget.controller,
      enabled: widget.enabled,
      obscureText: !_shown,
      autocorrect: false,
      enableSuggestions: false,
      keyboardType: TextInputType.visiblePassword,
      autofillHints: widget.autofillHints,
      decoration: InputDecoration(
        labelText: widget.label,
        suffixIcon: IconButton(
          key: const ValueKey('passphrase-visibility'),
          icon: Icon(
            _shown ? Icons.visibility_off_outlined : Icons.visibility_outlined,
            size: IconSizes.inline,
          ),
          tooltip: _shown ? l10n.passwordHide : l10n.passwordShow,
          onPressed: () => setState(() => _shown = !_shown),
        ),
      ),
      onSubmitted: submitted == null ? null : (_) => submitted(),
    );
  }
}
