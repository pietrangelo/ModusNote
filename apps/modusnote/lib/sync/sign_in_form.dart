import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:offline_sync/offline_sync.dart';
import 'package:offline_sync_adapters/offline_sync_adapters.dart';

import '../l10n/generated/app_localizations.dart';
import '../theme/golden_ratio.dart';
import '../theme/modus_palette.dart';

/// Signs in to the sync account with a code sent by email: the address
/// first, then the code. The email goes to the sync server only; the vault's
/// passphrase is never asked for here.
class SignInForm extends StatefulWidget {
  const SignInForm({
    required this.title,
    required this.body,
    required this.sendCode,
    required this.signIn,
    this.onTyped,
    super.key,
  });

  final String title;
  final String body;
  final Future<void> Function(String email) sendCode;
  final Future<void> Function(String email, String code) signIn;

  /// Called on every keystroke, so an auto-lock sees the user is there.
  final VoidCallback? onTyped;

  @override
  State<SignInForm> createState() => _SignInFormState();
}

enum _Problem {
  emailInvalid,
  codeInvalid,
  emailRefused,
  codeRefused,
  unreachable,
}

class _SignInFormState extends State<SignInForm> {
  final _email = TextEditingController();
  final _code = TextEditingController();

  /// Where the code was sent; null until it was.
  String? _sentTo;
  _Problem? _problem;
  var _busy = false;

  @override
  void dispose() {
    _email.dispose();
    _code.dispose();
    super.dispose();
  }

  /// Local checks only; the server has the last word on the address.
  static final _emailShape = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');
  static final _codeShape = RegExp(r'^\d{6,10}$');

  /// The sign-in link of a default Supabase email, pasted in place of the
  /// code; the adapter checks where it points before using it.
  static final _linkShape = RegExp(r'^https://\S{1,2048}$');

  Future<void> _sendCode() async {
    final email = _email.text.trim();
    if (email.length > 254 || !_emailShape.hasMatch(email)) {
      return setState(() => _problem = _Problem.emailInvalid);
    }
    await _run(() async {
      await widget.sendCode(email);
      _sentTo = email;
    }, refused: _Problem.emailRefused);
  }

  Future<void> _signIn() async {
    final code = _code.text.trim();
    final email = _sentTo;
    if (email == null) return;
    if (!_codeShape.hasMatch(code) && !_linkShape.hasMatch(code)) {
      return setState(() => _problem = _Problem.codeInvalid);
    }
    await _run(() async {
      await widget.signIn(email, code);
      _code.clear();
      _sentTo = null;
    }, refused: _Problem.codeRefused);
  }

  Future<void> _run(
    Future<void> Function() action, {
    required _Problem refused,
  }) async {
    setState(() {
      _busy = true;
      _problem = null;
    });
    _Problem? problem;
    try {
      await action();
    } on SupabaseAuthRejectedException {
      problem = refused;
    } on ServerUnavailableException {
      problem = _Problem.unreachable;
    } on MalformedSyncDataException {
      problem = _Problem.unreachable;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _problem = problem;
    });
  }

  void _typed(String _) => widget.onTyped?.call();

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: _sentTo == null ? _askEmail(context) : _askCode(context),
  );

  List<Widget> _askEmail(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return [
      _title(context),
      const SizedBox(height: Spacing.m),
      _muted(context, widget.body),
      const SizedBox(height: Spacing.l),
      TextField(
        key: const ValueKey('cloud-email'),
        controller: _email,
        enabled: !_busy,
        keyboardType: TextInputType.emailAddress,
        autofillHints: const [AutofillHints.email],
        autocorrect: false,
        decoration: InputDecoration(labelText: l10n.cloudEmailLabel),
        onChanged: _typed,
        onSubmitted: (_) => _sendCode(),
      ),
      ..._problemText(context),
      const SizedBox(height: Spacing.l),
      FilledButton(
        onPressed: _busy ? null : _sendCode,
        child: Text(l10n.cloudSendCode),
      ),
      ..._progress(),
    ];
  }

  List<Widget> _askCode(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return [
      _title(context),
      const SizedBox(height: Spacing.m),
      _muted(context, l10n.cloudCodeSent(_sentTo!)),
      const SizedBox(height: Spacing.l),
      TextField(
        key: const ValueKey('cloud-code'),
        controller: _code,
        enabled: !_busy,
        // Digits for the code; a link from the email can still be pasted.
        keyboardType: TextInputType.number,
        autofillHints: const [AutofillHints.oneTimeCode],
        autocorrect: false,
        enableSuggestions: false,
        inputFormatters: [LengthLimitingTextInputFormatter(2048)],
        decoration: InputDecoration(labelText: l10n.cloudCodeLabel),
        onChanged: _typed,
        onSubmitted: (_) => _signIn(),
      ),
      ..._problemText(context),
      const SizedBox(height: Spacing.l),
      FilledButton(
        onPressed: _busy ? null : _signIn,
        child: Text(l10n.cloudSignIn),
      ),
      const SizedBox(height: Spacing.s),
      TextButton(
        key: const ValueKey('cloud-resend'),
        onPressed: _busy
            ? null
            : () {
                _code.clear();
                _run(
                  () => widget.sendCode(_sentTo!),
                  refused: _Problem.emailRefused,
                );
              },
        child: Text(l10n.cloudResendCode),
      ),
      TextButton(
        onPressed: _busy
            ? null
            : () => setState(() {
                _sentTo = null;
                _problem = null;
                _code.clear();
              }),
        child: Text(l10n.cloudChangeEmail),
      ),
      ..._progress(),
    ];
  }

  Widget _title(BuildContext context) =>
      Text(widget.title, style: Theme.of(context).textTheme.headlineSmall);

  Widget _muted(BuildContext context, String text) => Text(
    text,
    style: Theme.of(context).textTheme.bodyMedium
        ?.copyWith(color: ModusPalette.of(context).muted),
  );

  List<Widget> _problemText(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final text = switch (_problem) {
      null => null,
      _Problem.emailInvalid => l10n.cloudEmailInvalid,
      _Problem.codeInvalid => l10n.cloudCodeInvalid,
      _Problem.emailRefused => l10n.cloudEmailRefused,
      _Problem.codeRefused => l10n.cloudCodeRefused,
      _Problem.unreachable => l10n.cloudUnreachable,
    };
    if (text == null) return const [];
    return [
      const SizedBox(height: Spacing.m),
      Semantics(
        liveRegion: true,
        child: Text(
          text,
          key: const ValueKey('cloud-problem'),
          style: Theme.of(context).textTheme.bodyMedium
              ?.copyWith(color: Theme.of(context).colorScheme.error),
        ),
      ),
    ];
  }

  List<Widget> _progress() => [
    if (_busy) ...[
      const SizedBox(height: Spacing.l),
      const Center(child: CircularProgressIndicator()),
    ],
  ];
}
