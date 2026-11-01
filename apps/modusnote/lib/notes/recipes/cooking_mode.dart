import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../theme/golden_ratio.dart';
import '../../theme/modus_palette.dart';
import '../attachments/attachments_input.dart';
import '../attachments/video_viewer.dart';
import '../markdown/markdown_document.dart';
import '../markdown/markdown_view.dart';
import 'recipe_text.dart';
import 'screen_awake.dart';

/// The time a step names, read from its words: «inforna per 40 minuti»,
/// «lascia lievitare 2 ore», «bake 25 min». The first one wins; nothing
/// is guessed from a number without its unit.
abstract final class StepTimer {
  static final _time = RegExp(
    r'(\d{1,4})\s*(minuti|minuto|minutes|minute|mins|min|ore|ora|hours|hour|h)\b',
    caseSensitive: false,
  );

  /// The longest timer: a day.
  static const maxMinutes = 1440;

  static int? minutesIn(String text) {
    final match = _time.firstMatch(text);
    if (match == null) return null;
    final count = int.parse(match.group(1)!);
    final unit = match.group(2)!.toLowerCase();
    final minutes = unit.startsWith('m') ? count : count * 60;
    return minutes < 1 || minutes > maxMinutes ? null : minutes;
  }
}

/// A recipe to cook from: the ingredients for the servings chosen, to tick
/// off, then one step per page in large type, with its pictures and a
/// timer. The screen stays on while it is open. Nothing here changes the
/// note: ticks and servings last as long as the screen.
class CookingModeScreen extends StatefulWidget {
  const CookingModeScreen({
    required this.entry,
    required this.title,
    required this.openImage,
    this.openVideo,
    this.onShopping,
    super.key,
  });

  final DynamicEntry entry;
  final String title;
  final Future<Uint8List> Function(BlobId blob) openImage;

  /// A step's video; null where videos cannot be opened.
  final Future<Uint8List> Function(BlobId blob)? openVideo;

  /// Saves a shopping list of [lines]; null where notes cannot be saved.
  final Future<void> Function(List<String> lines)? onShopping;

  static Future<void> show(
    BuildContext context, {
    required DynamicEntry entry,
    required String title,
    required Future<Uint8List> Function(BlobId blob) openImage,
    Future<Uint8List> Function(BlobId blob)? openVideo,
    Future<void> Function(List<String> lines)? onShopping,
  }) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => CookingModeScreen(
        entry: entry,
        title: title,
        openImage: openImage,
        openVideo: openVideo,
        onShopping: onShopping,
      ),
    ),
  );

  @override
  State<CookingModeScreen> createState() => _CookingModeScreenState();
}

class _CookingModeScreenState extends State<CookingModeScreen> {
  late final int? _written = Recipe.servingsOf(widget.entry);
  late int? _servings = _written;
  late final _ingredients = Recipe.ingredientsOf(widget.entry);
  late final _steps = Recipe.stepsOf(widget.entry);
  final _have = <int>{};
  final _pages = PageController();
  var _page = 0;

  final _opened = <BlobId, Future<Uint8List>>{};

  Timer? _ticker;
  Duration? _left;

  Future<Uint8List> _bytesOf(BlobId blob) =>
      _opened[blob] ??= widget.openImage(blob);

  int get _pageCount => _steps.length + (_ingredients.isEmpty ? 0 : 1);

  List<Ingredient> get _scaled => switch ((_written, _servings)) {
    (final from?, final to?) => Recipe.scale(_ingredients, from: from, to: to),
    _ => _ingredients,
  };

  @override
  void initState() {
    super.initState();
    unawaited(ScreenAwake.keep(true));
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _pages.dispose();
    unawaited(ScreenAwake.keep(false));
    super.dispose();
  }

  void _go(int page) => unawaited(
    _pages.animateToPage(
      page,
      duration: Durations.medium2,
      curve: Curves.easeOutCubic,
    ),
  );

  void _startTimer(int minutes) {
    _ticker?.cancel();
    setState(() => _left = Duration(minutes: minutes));
    _ticker = Timer.periodic(const Duration(seconds: 1), (timer) {
      final left = _left! - const Duration(seconds: 1);
      if (left > Duration.zero) {
        setState(() => _left = left);
        return;
      }
      timer.cancel();
      setState(() => _left = null);
      unawaited(SystemSound.play(SystemSoundType.alert));
      unawaited(HapticFeedback.heavyImpact());
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).stepTimerDone)),
        );
      }
    });
  }

  void _stopTimer() {
    _ticker?.cancel();
    setState(() => _left = null);
  }

  Future<void> _askTimer(int? suggested) async {
    final minutes = await showDialog<int>(
      context: context,
      builder: (_) => _TimerDialog(initial: suggested ?? 10),
    );
    if (minutes != null && minutes > 0 && minutes <= StepTimer.maxMinutes) {
      _startTimer(minutes);
    }
  }

  Future<void> _shop() async {
    final onShopping = widget.onShopping;
    if (onShopping == null) return;
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final text = RecipeText(l10n);
    final lines = [
      for (final (index, item) in _scaled.indexed)
        if (!_have.contains(index)) text.line(item),
    ];
    if (lines.isEmpty) {
      messenger.showSnackBar(SnackBar(content: Text(l10n.shoppingNothing)));
      return;
    }
    await onShopping(lines);
    messenger.showSnackBar(
      SnackBar(content: Text(l10n.shoppingListCreated(lines.length))),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final palette = ModusPalette.of(context);
    final left = _left;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          if (left != null)
            TextButton.icon(
              key: const ValueKey('timer-running'),
              onPressed: _stopTimer,
              icon: const Icon(Icons.timer_off_outlined),
              label: Text(
                '${left.inMinutes}:'
                '${(left.inSeconds % 60).toString().padLeft(2, '0')}',
                style: theme.textTheme.titleMedium?.copyWith(
                  color: palette.sage,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          const SizedBox(width: Spacing.s),
        ],
      ),
      body: _pageCount == 0
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(Spacing.l),
                child: Text(l10n.cookingNothing, textAlign: TextAlign.center),
              ),
            )
          : Column(
              children: [
                LinearProgressIndicator(
                  value: (_page + 1) / _pageCount,
                  color: palette.sage,
                  backgroundColor: palette.surface,
                ),
                Expanded(
                  child: PageView(
                    controller: _pages,
                    onPageChanged: (page) => setState(() => _page = page),
                    children: [
                      if (_ingredients.isNotEmpty) _ingredientsPage(l10n),
                      for (final (index, step) in _steps.indexed)
                        _stepPage(l10n, index, step),
                    ],
                  ),
                ),
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.all(Spacing.s),
                    child: Row(
                      children: [
                        TextButton.icon(
                          onPressed: _page == 0 ? null : () => _go(_page - 1),
                          icon: const Icon(Icons.arrow_back),
                          label: Text(l10n.cookingPrevious),
                        ),
                        const Spacer(),
                        FilledButton.icon(
                          key: const ValueKey('cooking-next'),
                          onPressed: _page == _pageCount - 1
                              ? () => Navigator.of(context).pop()
                              : () => _go(_page + 1),
                          icon: Icon(
                            _page == _pageCount - 1
                                ? Icons.check
                                : Icons.arrow_forward,
                          ),
                          label: Text(
                            _page == _pageCount - 1
                                ? l10n.cookingDone
                                : l10n.cookingNext,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  /// A page of the reading width, centred.
  Widget _column(List<Widget> children) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: Extents.xl),
      child: ListView(
        padding: const EdgeInsets.all(Spacing.l),
        children: children,
      ),
    ),
  );

  Widget _ingredientsPage(AppLocalizations l10n) {
    final theme = Theme.of(context);
    final palette = ModusPalette.of(context);
    final text = RecipeText(l10n);
    final servings = _servings;
    return _column([
      Text(l10n.cookingIngredients, style: theme.textTheme.headlineSmall),
      if (servings != null)
        Row(
          children: [
            IconButton(
              key: const ValueKey('servings-fewer'),
              onPressed: servings <= 1
                  ? null
                  : () => setState(() => _servings = servings - 1),
              tooltip: l10n.cookingFewerServings,
              icon: const Icon(Icons.remove_circle_outline),
            ),
            Text(
              l10n.cookingServings(servings),
              key: const ValueKey('servings'),
              style: theme.textTheme.titleMedium,
            ),
            IconButton(
              key: const ValueKey('servings-more'),
              onPressed: servings >= 100
                  ? null
                  : () => setState(() => _servings = servings + 1),
              tooltip: l10n.cookingMoreServings,
              icon: const Icon(Icons.add_circle_outline),
            ),
          ],
        ),
      Padding(
        padding: const EdgeInsets.only(top: Spacing.s),
        child: Text(
          l10n.cookingHaveHint,
          style: theme.textTheme.bodySmall?.copyWith(color: palette.muted),
        ),
      ),
      for (final (index, item) in _scaled.indexed)
        CheckboxListTile(
          key: ValueKey('have-$index'),
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          activeColor: palette.sage,
          checkColor: palette.onAccent,
          value: _have.contains(index),
          onChanged: (on) => setState(
            () => on ?? false ? _have.add(index) : _have.remove(index),
          ),
          title: Text(
            text.line(item),
            style: theme.textTheme.titleMedium?.copyWith(
              decoration: _have.contains(index)
                  ? TextDecoration.lineThrough
                  : null,
              color: _have.contains(index) ? palette.muted : null,
            ),
          ),
        ),
      if (widget.onShopping != null)
        Padding(
          padding: const EdgeInsets.only(top: Spacing.m),
          child: Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              key: const ValueKey('add-to-shopping'),
              onPressed: _shop,
              icon: const Icon(Icons.shopping_cart_outlined),
              label: Text(l10n.addToShopping),
            ),
          ),
        ),
    ]);
  }

  Widget _stepPage(AppLocalizations l10n, int index, PreparationStep step) {
    final theme = Theme.of(context);
    final palette = ModusPalette.of(context);
    final suggested = StepTimer.minutesIn(step.text);
    final text = RecipeText(l10n);
    return _column([
      Text(
        l10n.cookingStepOf(index + 1, _steps.length),
        style: theme.textTheme.labelLarge?.copyWith(color: palette.sage),
      ),
      const SizedBox(height: Spacing.s),
      // Large type, read from arm's length: one step of the φ scale up.
      DefaultTextStyle.merge(
        style: theme.textTheme.headlineSmall,
        child: Theme(
          data: theme.copyWith(
            textTheme: theme.textTheme.copyWith(
              bodyLarge: theme.textTheme.headlineSmall,
            ),
          ),
          child: MarkdownView(document: MarkdownDocument.parse(step.text)),
        ),
      ),
      for (final picture in step.pictures)
        Padding(
          padding: const EdgeInsets.only(top: Spacing.m),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(Radii.small),
            child: AspectRatio(
              aspectRatio: GoldenRatio.phi,
              child: SealedImage(
                bytes: _bytesOf(picture.blob),
                fit: BoxFit.cover,
              ),
            ),
          ),
        ),
      if ((step.video, widget.openVideo) case (final video?, final open?))
        Padding(
          padding: const EdgeInsets.only(top: Spacing.m),
          child: Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.tonalIcon(
              key: const ValueKey('cooking-video'),
              icon: const Icon(Icons.play_circle_outline),
              label: Text(AppLocalizations.of(context).stepVideo),
              onPressed: () => VideoViewer.show(context, bytes: open(video)),
            ),
          ),
        ),
      Padding(
        padding: const EdgeInsets.only(top: Spacing.m),
        child: Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            key: ValueKey('step-timer-$index'),
            onPressed: () => _askTimer(suggested),
            icon: const Icon(Icons.timer_outlined),
            label: Text(
              suggested == null
                  ? l10n.stepTimer
                  : l10n.stepTimerFor(text.minutes(suggested)),
            ),
          ),
        ),
      ),
    ]);
  }
}

/// Asks how many minutes a timer runs; the dialog owns its text, so it
/// outlives the closing animation.
class _TimerDialog extends StatefulWidget {
  const _TimerDialog({required this.initial});

  final int initial;

  @override
  State<_TimerDialog> createState() => _TimerDialogState();
}

class _TimerDialogState extends State<_TimerDialog> {
  late final _controller = TextEditingController(text: '${widget.initial}');

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l10n.stepTimer),
      content: TextField(
        key: const ValueKey('timer-minutes'),
        controller: _controller,
        autofocus: true,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(labelText: l10n.stepTimerMinutes),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.of(context).pop(int.tryParse(_controller.text.trim())),
          child: Text(l10n.stepTimerStart),
        ),
      ],
    );
  }
}
