import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../theme/golden_ratio.dart';
import '../../theme/modus_palette.dart';
import '../attachments/attachment_dialogs.dart';
import '../attachments/attachments_input.dart';
import '../attachments/video_viewer.dart';
import 'recipe_text.dart';

/// Reports a field that may hold input that cannot become a value yet.
typedef DraftChanged = void Function(
  FieldValue? value, {
  required bool unreadable,
});

Widget _label(BuildContext context, String label, String? error) {
  final theme = Theme.of(context);
  return Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.only(top: Spacing.l, bottom: Spacing.xs),
        child: Text(label, style: theme.textTheme.labelMedium),
      ),
      if (error != null)
        Text(
          error,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.error,
          ),
        ),
    ],
  );
}

/// Some options of a closed set, as chips to turn on and off.
class ChoiceSetInput extends StatelessWidget {
  const ChoiceSetInput({
    required this.label,
    required this.error,
    required this.options,
    required this.value,
    required this.onChanged,
    super.key,
  });

  final String label;
  final String? error;

  /// Option identifier to its localized text, in schema order.
  final Map<String, String> options;
  final Set<String> value;
  final ValueChanged<ChoiceSetValue?> onChanged;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _label(context, label, error),
      Wrap(
        spacing: Spacing.xs,
        runSpacing: Spacing.xs,
        children: [
          for (final MapEntry(:key, value: text) in options.entries)
            FilterChip(
              key: ValueKey('choice-$key'),
              label: Text(text),
              selected: value.contains(key),
              onSelected: (on) {
                final next = {...value};
                on ? next.add(key) : next.remove(key);
                onChanged(next.isEmpty ? null : ChoiceSetValue(next));
              },
            ),
        ],
      ),
    ],
  );
}

final class _IngredientRow {
  _IngredientRow([Ingredient? item, RecipeText? text])
    : unit = item?.unit,
      name = TextEditingController(text: item?.name ?? ''),
      amount = TextEditingController(
        text: switch (item?.amount) {
          final n? => text?.amount(n) ?? '$n',
          null => '',
        },
      ),
      quantity = TextEditingController(text: item?.quantity ?? ''),
      link = TextEditingController(text: item?.link?.url ?? '');

  final key = UniqueKey();
  final TextEditingController name;
  final TextEditingController amount;
  final TextEditingController quantity;
  final TextEditingController link;
  final focus = FocusNode();
  IngredientUnit? unit;

  bool get blank =>
      name.text.trim().isEmpty &&
      amount.text.trim().isEmpty &&
      quantity.text.trim().isEmpty &&
      link.text.trim().isEmpty;

  void dispose() {
    name.dispose();
    amount.dispose();
    quantity.dispose();
    link.dispose();
    focus.dispose();
  }
}

/// The ingredients of a recipe: for each, an amount and its unit, the
/// name, words of quantity and a link to buy it. An amount that is not a
/// positive number, or a link that is not `https`, is marked and keeps
/// the note from saving: the domain never sees a guess.
class IngredientsInput extends StatefulWidget {
  const IngredientsInput({
    required this.label,
    required this.error,
    required this.value,
    required this.onChanged,
    super.key,
  });

  final String label;
  final String? error;
  final IngredientsValue? value;
  final DraftChanged onChanged;

  /// Parses an amount written with either decimal sign: «1,5» or «1.5».
  static num? parseAmount(String input) {
    final text = input.trim().replaceAll(',', '.');
    if (!RegExp(r'^\d{1,7}(\.\d{1,3})?$').hasMatch(text)) return null;
    final n = num.parse(text);
    if (n <= 0 || n > Ingredient.maxAmount) return null;
    return n == n.truncate() ? n.toInt() : n;
  }

  /// A shop link as typed; null when it is empty or not `https`.
  static WebLink? parseLink(String input) => switch (WebLink.parse(input)) {
    final link? when link.url.startsWith('https://') => link,
    _ => null,
  };

  @override
  State<IngredientsInput> createState() => _IngredientsInputState();
}

class _IngredientsInputState extends State<IngredientsInput> {
  late final List<_IngredientRow> _rows;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final text = RecipeText(AppLocalizations.of(context));
    _rows = [
      for (final item in widget.value?.items ?? const <Ingredient>[])
        _IngredientRow(item, text),
      if (widget.value == null) _IngredientRow(),
    ];
  }

  @override
  void dispose() {
    for (final row in _rows) {
      row.dispose();
    }
    super.dispose();
  }

  bool _badAmount(_IngredientRow row) =>
      row.amount.text.trim().isNotEmpty &&
      IngredientsInput.parseAmount(row.amount.text) == null;

  bool _badLink(_IngredientRow row) =>
      row.link.text.trim().isNotEmpty &&
      IngredientsInput.parseLink(row.link.text) == null;

  void _report() {
    var unreadable = false;
    final items = <Ingredient>[];
    for (final row in _rows) {
      if (row.blank) continue;
      if (_badAmount(row) || _badLink(row)) {
        unreadable = true;
        continue;
      }
      final amount = IngredientsInput.parseAmount(row.amount.text);
      items.add(
        Ingredient(
          row.name.text.trim(),
          amount: amount,
          unit: amount == null ? null : row.unit,
          quantity: row.quantity.text.trim(),
          link: IngredientsInput.parseLink(row.link.text),
        ),
      );
    }
    widget.onChanged(
      items.isEmpty ? null : IngredientsValue(items),
      unreadable: unreadable,
    );
  }

  void _add() {
    final row = _IngredientRow();
    setState(() => _rows.add(row));
    row.focus.requestFocus();
  }

  void _remove(int index) {
    final row = _rows[index];
    setState(() => _rows.removeAt(index));
    WidgetsBinding.instance.addPostFrameCallback((_) => row.dispose());
    _report();
  }

  void _changed() {
    setState(() {});
    _report();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final text = RecipeText(l10n);
    final palette = ModusPalette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _label(context, widget.label, widget.error),
        for (final (index, row) in _rows.indexed)
          Padding(
            key: row.key,
            padding: const EdgeInsets.only(bottom: Spacing.s),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Amount and unit take 38.2 % of the row, the name the
                    // rest.
                    Expanded(
                      flex: 382,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: TextField(
                              key: ValueKey('ingredient-amount-$index'),
                              controller: row.amount,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                    decimal: true,
                                  ),
                              decoration: InputDecoration(
                                hintText: l10n.ingredientAmountHint,
                                errorText: _badAmount(row)
                                    ? l10n.ingredientAmountInvalid
                                    : null,
                              ),
                              onChanged: (_) => _changed(),
                            ),
                          ),
                          const SizedBox(width: Spacing.xs),
                          Expanded(
                            child: DropdownButtonFormField<IngredientUnit?>(
                              key: ValueKey('ingredient-unit-$index'),
                              initialValue: row.unit,
                              isExpanded: true,
                              decoration: InputDecoration(
                                hintText: l10n.ingredientUnitLabel,
                              ),
                              items: [
                                DropdownMenuItem<IngredientUnit?>(
                                  child: Text(l10n.ingredientNoUnit),
                                ),
                                for (final unit in IngredientUnit.values)
                                  DropdownMenuItem(
                                    value: unit,
                                    child: Text(text.unit(unit)),
                                  ),
                              ],
                              onChanged: (unit) {
                                row.unit = unit;
                                _changed();
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: Spacing.s),
                    Expanded(
                      flex: 618,
                      child: TextField(
                        key: ValueKey('ingredient-name-$index'),
                        controller: row.name,
                        focusNode: row.focus,
                        decoration: InputDecoration(
                          hintText: l10n.ingredientNameHint,
                        ),
                        onChanged: (_) => _changed(),
                      ),
                    ),
                    if (_rows.length > 1)
                      IconButton(
                        icon: const Icon(Icons.close, size: IconSizes.inline),
                        color: palette.muted,
                        tooltip: l10n.removeIngredient,
                        onPressed: () => _remove(index),
                      ),
                  ],
                ),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 382,
                      child: TextField(
                        key: ValueKey('ingredient-quantity-$index'),
                        controller: row.quantity,
                        style: Theme.of(context).textTheme.bodySmall,
                        decoration: InputDecoration(
                          isDense: true,
                          hintText: l10n.ingredientQuantityHint,
                        ),
                        onChanged: (_) => _changed(),
                      ),
                    ),
                    const SizedBox(width: Spacing.s),
                    Expanded(
                      flex: 618,
                      child: TextField(
                        key: ValueKey('ingredient-link-$index'),
                        controller: row.link,
                        keyboardType: TextInputType.url,
                        style: Theme.of(context).textTheme.bodySmall,
                        decoration: InputDecoration(
                          isDense: true,
                          prefixIcon: const Icon(
                            Icons.shopping_bag_outlined,
                            size: IconSizes.inline,
                          ),
                          hintText: l10n.ingredientLinkHint,
                          errorText: _badLink(row)
                              ? l10n.ingredientLinkInvalid
                              : null,
                        ),
                        onChanged: (_) => _changed(),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _add,
            icon: const Icon(Icons.add, size: IconSizes.inline),
            label: Text(l10n.addIngredient),
          ),
        ),
      ],
    );
  }
}

final class _StepRow {
  _StepRow([PreparationStep? step])
    : text = TextEditingController(text: step?.text ?? ''),
      pictures = [...?step?.pictures],
      video = step?.video;

  final key = UniqueKey();
  final TextEditingController text;
  final List<ImageAttachment> pictures;
  BlobId? video;
  final focus = FocusNode();

  bool get blank =>
      text.text.trim().isEmpty && pictures.isEmpty && video == null;

  void dispose() {
    text.dispose();
    focus.dispose();
  }
}

/// The steps of a preparation, numbered: each with its text and its
/// pictures, which can be moved up and down.
class StepsInput extends StatefulWidget {
  const StepsInput({
    required this.label,
    required this.error,
    required this.value,
    required this.hooks,
    required this.onChanged,
    super.key,
  });

  final String label;
  final String? error;
  final StepsValue? value;
  final AttachmentHooks hooks;
  final ValueChanged<StepsValue?> onChanged;

  @override
  State<StepsInput> createState() => _StepsInputState();
}

class _StepsInputState extends State<StepsInput> {
  late final List<_StepRow> _rows = [
    for (final step in widget.value?.steps ?? const <PreparationStep>[])
      _StepRow(step),
    if (widget.value == null) _StepRow(),
  ];

  /// Each picture is decrypted once while the page is open.
  final _opened = <BlobId, Future<Uint8List>>{};

  Future<Uint8List> _bytesOf(BlobId blob) =>
      _opened[blob] ??= widget.hooks.openImage(blob);

  @override
  void dispose() {
    for (final row in _rows) {
      row.dispose();
    }
    super.dispose();
  }

  void _report() {
    final steps = [
      for (final row in _rows)
        if (!row.blank)
          PreparationStep(
            row.text.text.trim(),
            pictures: row.pictures,
            video: row.video,
          ),
    ];
    widget.onChanged(steps.isEmpty ? null : StepsValue(steps));
  }

  void _update(VoidCallback change) {
    setState(change);
    _report();
  }

  void _add() {
    final row = _StepRow();
    setState(() => _rows.add(row));
    row.focus.requestFocus();
  }

  void _remove(int index) {
    final row = _rows[index];
    _update(() => _rows.removeAt(index));
    WidgetsBinding.instance.addPostFrameCallback((_) => row.dispose());
  }

  void _move(int index, int by) =>
      _update(() => _rows.insert(index + by, _rows.removeAt(index)));

  Future<void> _addPicture(_StepRow row, Future<BlobId?> Function() add) async {
    final blob = await add();
    if (blob == null || !mounted) return;
    _update(() => row.pictures.add(ImageAttachment(blob)));
  }

  Future<void> _addVideo(
    _StepRow row,
    Future<BlobId?> Function({required bool camera}) add, {
    required bool camera,
  }) async {
    final blob = await add(camera: camera);
    if (blob == null || !mounted) return;
    _update(() => row.video = blob);
  }

  /// «0:42»: a clip is at most a minute.
  static String _length(Duration length) =>
      '${length.inMinutes}:${(length.inSeconds % 60).toString().padLeft(2, '0')}';

  Widget _video(BuildContext context, _StepRow row, int index) {
    final l10n = AppLocalizations.of(context);
    final palette = ModusPalette.of(context);
    final video = row.video;
    final open = widget.hooks.openVideo;
    if (video != null) {
      final length = widget.hooks.videoLength?.call(video);
      return Padding(
        padding: const EdgeInsets.only(top: Spacing.s),
        child: Row(
          children: [
            TextButton.icon(
              key: ValueKey('step-video-$index'),
              icon: const Icon(Icons.play_circle_outline),
              label: Text(
                length == null
                    ? l10n.stepVideo
                    : l10n.stepVideoLength(_length(length)),
              ),
              onPressed: open == null
                  ? null
                  : () => VideoViewer.show(context, bytes: open(video)),
            ),
            const Spacer(),
            IconButton(
              key: ValueKey('step-remove-video-$index'),
              icon: const Icon(Icons.close, size: IconSizes.inline),
              color: palette.muted,
              tooltip: l10n.removeStepVideo,
              onPressed: () => _update(() => row.video = null),
            ),
          ],
        ),
      );
    }
    final add = widget.hooks.addVideo;
    if (add == null) return const SizedBox.shrink();
    return Align(
      alignment: Alignment.centerLeft,
      child: PopupMenuButton<bool>(
        key: ValueKey('step-add-video-$index'),
        tooltip: l10n.addStepVideo,
        onSelected: (camera) => _addVideo(row, add, camera: camera),
        itemBuilder: (_) => [
          // A browser here has no camera of its own.
          if (!kIsWeb)
            PopupMenuItem(
              key: const ValueKey('step-record-video'),
              value: true,
              child: Text(l10n.recordStepVideo),
            ),
          PopupMenuItem(
            key: const ValueKey('step-choose-video'),
            value: false,
            child: Text(l10n.chooseStepVideo),
          ),
        ],
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Spacing.s,
            vertical: Spacing.xs,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.videocam_outlined,
                size: IconSizes.inline,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: Spacing.xs),
              Text(
                l10n.addStepVideo,
                style: Theme.of(context).textTheme.labelLarge
                    ?.copyWith(color: Theme.of(context).colorScheme.primary),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final palette = ModusPalette.of(context);
    final addImage = widget.hooks.addImage;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _label(context, widget.label, widget.error),
        for (final (index, row) in _rows.indexed)
          Padding(
            key: row.key,
            padding: const EdgeInsets.only(bottom: Spacing.m),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        l10n.stepNumber(index + 1),
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: palette.sage,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(
                        Icons.arrow_upward,
                        size: IconSizes.inline,
                      ),
                      tooltip: l10n.moveStepUp,
                      onPressed: index == 0 ? null : () => _move(index, -1),
                    ),
                    IconButton(
                      icon: const Icon(
                        Icons.arrow_downward,
                        size: IconSizes.inline,
                      ),
                      tooltip: l10n.moveStepDown,
                      onPressed: index == _rows.length - 1
                          ? null
                          : () => _move(index, 1),
                    ),
                    if (_rows.length > 1)
                      IconButton(
                        icon: const Icon(Icons.close, size: IconSizes.inline),
                        color: palette.muted,
                        tooltip: l10n.removeStep,
                        onPressed: () => _remove(index),
                      ),
                  ],
                ),
                TextField(
                  key: ValueKey('step-text-$index'),
                  controller: row.text,
                  focusNode: row.focus,
                  minLines: 2,
                  maxLines: null,
                  keyboardType: TextInputType.multiline,
                  decoration: InputDecoration(hintText: l10n.stepHint),
                  onChanged: (_) => _report(),
                ),
                if (row.pictures.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: Spacing.s),
                    child: Wrap(
                      spacing: Spacing.s,
                      runSpacing: Spacing.s,
                      children: [
                        for (final picture in row.pictures)
                          PictureThumbnail(
                            key: ValueKey('step-image-${picture.blob.value}'),
                            image: picture,
                            bytes: _bytesOf(picture.blob),
                            onView: () => ImageViewer.show(
                              context,
                              bytes: _bytesOf(picture.blob),
                              caption: picture.caption,
                            ),
                            onCaption: () async {
                              final caption = await showCaptionDialog(
                                context,
                                initial: picture.caption,
                              );
                              if (caption == null || !mounted) return;
                              _update(() {
                                final at = row.pictures.indexOf(picture);
                                if (at >= 0) {
                                  row.pictures[at] = picture.captioned(caption);
                                }
                              });
                            },
                            onRemove: () =>
                                _update(() => row.pictures.remove(picture)),
                          ),
                      ],
                    ),
                  ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    key: ValueKey('step-add-picture-$index'),
                    icon: const Icon(
                      Icons.add_photo_alternate_outlined,
                      size: IconSizes.inline,
                    ),
                    label: Text(l10n.addStepPicture),
                    onPressed:
                        addImage == null ||
                            row.pictures.length >=
                                StepsFieldType.maxPicturesPerStep
                        ? null
                        : () => _addPicture(row, addImage),
                  ),
                ),
                _video(context, row, index),
              ],
            ),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _add,
            icon: const Icon(Icons.add, size: IconSizes.inline),
            label: Text(l10n.addStep),
          ),
        ),
      ],
    );
  }
}
