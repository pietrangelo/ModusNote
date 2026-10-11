import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import '../audio/recording_sheet.dart' show formatLength;
import '../l10n/generated/app_localizations.dart';
import '../theme/golden_ratio.dart';
import '../theme/modus_colors.dart';
import 'schema_text.dart';

/// What the user has entered so far. [unreadable] holds fields whose input
/// cannot become a value at all (a number field with letters in it): the
/// domain never sees a guess, and the editor refuses to save.
@immutable
final class FormDraft {
  FormDraft(Map<FieldKey, FieldValue> values, Set<FieldKey> unreadable)
    : values = Map.unmodifiable(values),
      unreadable = Set.unmodifiable(unreadable);

  final Map<FieldKey, FieldValue> values;
  final Set<FieldKey> unreadable;
}

/// Builds the form of any [SchemaDefinition] at runtime: one input per
/// field, chosen by its [FieldType]. Nothing here knows about songs or
/// tasks; a new schema needs no new widget.
///
/// Every value is shown through text widgets, never parsed as HTML or
/// Markdown, so content synced from someone else cannot run as code.
class DynamicFormRenderer extends StatefulWidget {
  const DynamicFormRenderer({
    required this.schema,
    required this.values,
    required this.onChanged,
    this.violations = const [],
    this.onRecordAudio,
    this.recordingLength,
    super.key,
  });

  final SchemaDefinition schema;

  /// Starting values; the renderer owns the edits from then on.
  final Map<FieldKey, FieldValue> values;
  final ValueChanged<FormDraft> onChanged;
  final List<Violation> violations;

  /// Records into an audio field; without it the record button is off.
  final Future<BlobId?> Function(FieldDefinition field)? onRecordAudio;

  /// How long the recording behind a blob is, when it is known.
  final Duration? Function(BlobId blob)? recordingLength;

  @override
  State<DynamicFormRenderer> createState() => _DynamicFormRendererState();
}

class _DynamicFormRendererState extends State<DynamicFormRenderer> {
  late final Map<FieldKey, FieldValue> _values = {...widget.values};
  final _unreadable = <FieldKey>{};

  void _set(FieldKey key, FieldValue? value, {bool unreadable = false}) {
    setState(() {
      if (value == null) {
        _values.remove(key);
      } else {
        _values[key] = value;
      }
      if (unreadable) {
        _unreadable.add(key);
      } else {
        _unreadable.remove(key);
      }
    });
    widget.onChanged(FormDraft(_values, _unreadable));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final text = SchemaText(l10n);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final field in _ordered(widget.schema))
          KeyedSubtree(
            key: ValueKey('field-${field.key}'),
            child: Padding(
              padding: const EdgeInsets.only(bottom: Spacing.l),
              child: _input(field, text, l10n),
            ),
          ),
      ],
    );
  }

  Widget _input(FieldDefinition field, SchemaText text, AppLocalizations l10n) {
    final label = text.label(field.label);
    final error = _errorFor(field.key, text);
    final value = _values[field.key];
    void set(FieldValue? v) => _set(field.key, v);
    return switch (field.type) {
      TextFieldType() => _TextInput(
        label: label,
        error: error,
        value: value,
        multiline: false,
        onChanged: set,
      ),
      RichTextFieldType() || MarkdownFieldType() => _TextInput(
        label: label,
        error: error,
        value: value,
        multiline: true,
        onChanged: set,
      ),
      NumberFieldType() => _NumberInput(
        label: label,
        error: error,
        value: value,
        onChanged: (v, {required unreadable}) =>
            _set(field.key, v, unreadable: unreadable),
      ),
      DateFieldType() => _DateInput(
        label: label,
        error: error,
        value: value is DateValue ? value : null,
        onChanged: set,
      ),
      DateTimeFieldType() => _DateTimeInput(
        label: label,
        error: error,
        value: value is DateTimeValue ? value : null,
        onChanged: set,
      ),
      BooleanFieldType() => _BooleanInput(
        label: label,
        error: error,
        value: value is BooleanValue ? value.value : null,
        onChanged: (v) => set(BooleanValue(v)),
      ),
      RatingFieldType(:final min, :final max) => _RatingInput(
        label: label,
        error: error,
        lowest: min < 1 ? 1 : min,
        highest: max,
        value: value is RatingValue ? value.rating : null,
        onChanged: (v) => set(v == null ? null : RatingValue(v)),
      ),
      ChoiceFieldType(:final options) => _ChoiceInput(
        label: label,
        error: error,
        options: {for (final o in options) o: text.option(field, o)},
        value: value is ChoiceValue && options.contains(value.option)
            ? value.option
            : null,
        onChanged: (v) => set(v == null ? null : ChoiceValue(v)),
      ),
      TagListFieldType() => _TagsInput(
        label: label,
        error: error,
        tags: value is TagListValue ? value.tags : const {},
        onChanged: (tags) => set(tags.isEmpty ? null : TagListValue(tags)),
      ),
      AudioBlobFieldType() => _AudioInput(
        label: label,
        error: error,
        attached: value is AudioBlobValue,
        length: value is AudioBlobValue
            ? widget.recordingLength?.call(value.blob)
            : null,
        onRecord: switch (widget.onRecordAudio) {
          null => null,
          final record => () async {
            final blob = await record(field);
            if (blob != null) set(AudioBlobValue(blob));
          },
        },
      ),
    };
  }

  String? _errorFor(FieldKey key, SchemaText text) {
    final codes = {
      if (_unreadable.contains(key)) ViolationCode.typeMismatch,
      for (final v in widget.violations)
        if (v.field == key) v.code,
    };
    return codes.isEmpty ? null : codes.map(text.violation).join(' · ');
  }

  /// Fields placed by the schema's UI hints come first, by section and
  /// order; the rest follow in declaration order.
  static List<FieldDefinition> _ordered(SchemaDefinition schema) {
    final hints = schema.uiHints;
    if (hints.isEmpty) return schema.fields;
    final sections = {for (final hint in hints) hint.section}.toList();
    final placed = [...hints]
      ..sort((a, b) {
        final bySection = sections
            .indexOf(a.section)
            .compareTo(sections.indexOf(b.section));
        return bySection != 0 ? bySection : a.order.compareTo(b.order);
      });
    final keys = {for (final hint in placed) hint.field};
    return [
      for (final hint in placed) schema.fieldFor(hint.field)!,
      for (final field in schema.fields)
        if (!keys.contains(field.key)) field,
    ];
  }
}

class _TextInput extends StatefulWidget {
  const _TextInput({
    required this.label,
    required this.error,
    required this.value,
    required this.multiline,
    required this.onChanged,
  });

  final String label;
  final String? error;
  final FieldValue? value;
  final bool multiline;
  final ValueChanged<FieldValue?> onChanged;

  @override
  State<_TextInput> createState() => _TextInputState();
}

class _TextInputState extends State<_TextInput> {
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

  @override
  Widget build(BuildContext context) => TextField(
    controller: _controller,
    decoration: InputDecoration(
      labelText: widget.label,
      errorText: widget.error,
    ),
    minLines: widget.multiline ? 3 : 1,
    maxLines: widget.multiline ? null : 1,
    keyboardType: widget.multiline
        ? TextInputType.multiline
        : TextInputType.text,
    onChanged: (text) =>
        widget.onChanged(text.isEmpty ? null : TextValue(text)),
  );
}

typedef _NumberChanged = void Function(
  NumberValue? value, {
  required bool unreadable,
});

class _NumberInput extends StatefulWidget {
  const _NumberInput({
    required this.label,
    required this.error,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final String? error;
  final FieldValue? value;
  final _NumberChanged onChanged;

  @override
  State<_NumberInput> createState() => _NumberInputState();
}

class _NumberInputState extends State<_NumberInput> {
  late final _controller = TextEditingController(
    text: switch (widget.value) {
      NumberValue(:final number) => '$number',
      _ => '',
    },
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _parse(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) {
      widget.onChanged(null, unreadable: false);
      return;
    }
    final number = num.tryParse(trimmed.replaceAll(',', '.'));
    if (number == null || !number.isFinite) {
      widget.onChanged(null, unreadable: true);
    } else {
      widget.onChanged(NumberValue(number), unreadable: false);
    }
  }

  @override
  Widget build(BuildContext context) => TextField(
    controller: _controller,
    decoration: InputDecoration(
      labelText: widget.label,
      errorText: widget.error,
    ),
    keyboardType: const TextInputType.numberWithOptions(
      decimal: true,
      signed: true,
    ),
    onChanged: _parse,
  );
}

/// Label and error frame for inputs that are not text fields.
class _Framed extends StatelessWidget {
  const _Framed({
    required this.label,
    required this.error,
    required this.child,
  });

  final String label;
  final String? error;
  final Widget child;

  @override
  Widget build(BuildContext context) => InputDecorator(
    decoration: InputDecoration(
      labelText: label,
      errorText: error,
      border: InputBorder.none,
    ),
    child: child,
  );
}

class _ClearButton extends StatelessWidget {
  const _ClearButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    icon: const Icon(Icons.close, size: IconSizes.inline),
    tooltip: AppLocalizations.of(context).clearValue,
    onPressed: onPressed,
  );
}

class _DateInput extends StatelessWidget {
  const _DateInput({
    required this.label,
    required this.error,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final String? error;
  final DateValue? value;
  final ValueChanged<FieldValue?> onChanged;

  @override
  Widget build(BuildContext context) {
    final current = value;
    final material = MaterialLocalizations.of(context);
    return _Framed(
      label: label,
      error: error,
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              icon: const Icon(Icons.event, size: IconSizes.inline),
              label: Text(
                current == null
                    ? AppLocalizations.of(context).chooseDate
                    : material.formatMediumDate(
                        DateTime(current.year, current.month, current.day),
                      ),
              ),
              onPressed: () async {
                final today = DateTime.now();
                final picked = await showDatePicker(
                  context: context,
                  initialDate: current == null
                      ? today
                      : DateTime(current.year, current.month, current.day),
                  firstDate: DateTime(1900),
                  lastDate: DateTime(2200),
                );
                if (picked != null) {
                  onChanged(DateValue(picked.year, picked.month, picked.day));
                }
              },
            ),
          ),
          if (current != null) _ClearButton(onPressed: () => onChanged(null)),
        ],
      ),
    );
  }
}

class _DateTimeInput extends StatelessWidget {
  const _DateTimeInput({
    required this.label,
    required this.error,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final String? error;
  final DateTimeValue? value;
  final ValueChanged<FieldValue?> onChanged;

  @override
  Widget build(BuildContext context) {
    final local = value?.instant.toLocal();
    final material = MaterialLocalizations.of(context);
    return _Framed(
      label: label,
      error: error,
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              icon: const Icon(Icons.schedule, size: IconSizes.inline),
              label: Text(
                local == null
                    ? AppLocalizations.of(context).chooseDateTime
                    : '${material.formatMediumDate(local)} · '
                          '${material.formatTimeOfDay(TimeOfDay.fromDateTime(local))}',
              ),
              onPressed: () async {
                final start = local ?? DateTime.now();
                final day = await showDatePicker(
                  context: context,
                  initialDate: start,
                  firstDate: DateTime(1900),
                  lastDate: DateTime(2200),
                );
                if (day == null || !context.mounted) return;
                final time = await showTimePicker(
                  context: context,
                  initialTime: TimeOfDay.fromDateTime(start),
                );
                if (time == null) return;
                // Stored in UTC; shown back in the device's zone.
                onChanged(
                  DateTimeValue(
                    DateTime(
                      day.year,
                      day.month,
                      day.day,
                      time.hour,
                      time.minute,
                    ).toUtc(),
                  ),
                );
              },
            ),
          ),
          if (local != null) _ClearButton(onPressed: () => onChanged(null)),
        ],
      ),
    );
  }
}

class _BooleanInput extends StatelessWidget {
  const _BooleanInput({
    required this.label,
    required this.error,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final String? error;
  final bool? value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InputDecorator(
      decoration: InputDecoration(errorText: error, border: InputBorder.none),
      child: InkWell(
        onTap: () => onChanged(!(value ?? false)),
        child: Row(
          children: [
            Checkbox(
              value: value ?? false,
              // Cadence Cyan marks what is done.
              activeColor: scheme.tertiary,
              checkColor: scheme.onTertiary,
              onChanged: (checked) => onChanged(checked ?? false),
            ),
            const SizedBox(width: Spacing.s),
            Expanded(child: Text(label)),
          ],
        ),
      ),
    );
  }
}

class _RatingInput extends StatelessWidget {
  const _RatingInput({
    required this.label,
    required this.error,
    required this.lowest,
    required this.highest,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final String? error;
  final int lowest;
  final int highest;
  final int? value;
  final ValueChanged<int?> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final gold = Theme.of(context).colorScheme.primary;
    final current = value ?? 0;
    return _Framed(
      label: label,
      error: error,
      child: Wrap(
        children: [
          for (var rating = lowest; rating <= highest; rating++)
            IconButton(
              tooltip: l10n.ratingValue(rating, highest),
              iconSize: IconSizes.inline,
              color: gold,
              icon: Icon(rating <= current ? Icons.star : Icons.star_border),
              onPressed: () => onChanged(rating == value ? null : rating),
            ),
        ],
      ),
    );
  }
}

class _ChoiceInput extends StatelessWidget {
  const _ChoiceInput({
    required this.label,
    required this.error,
    required this.options,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final String? error;

  /// Option identifier to its localized text, in schema order.
  final Map<String, String> options;
  final String? value;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) => DropdownButtonFormField<String>(
    initialValue: value,
    isExpanded: true,
    decoration: InputDecoration(labelText: label, errorText: error),
    items: [
      DropdownMenuItem<String>(
        child: Text(AppLocalizations.of(context).notSet),
      ),
      for (final MapEntry(:key, :value) in options.entries)
        DropdownMenuItem(value: key, child: Text(value)),
    ],
    onChanged: onChanged,
  );
}

class _TagsInput extends StatefulWidget {
  const _TagsInput({
    required this.label,
    required this.error,
    required this.tags,
    required this.onChanged,
  });

  final String label;
  final String? error;
  final Set<String> tags;
  final ValueChanged<Set<String>> onChanged;

  @override
  State<_TagsInput> createState() => _TagsInputState();
}

class _TagsInputState extends State<_TagsInput> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _add(String input) {
    final added = input
        .split(',')
        .map((tag) => tag.trim())
        .where((tag) => tag.isNotEmpty);
    _controller.clear();
    if (added.isEmpty) return;
    widget.onChanged({...widget.tags, ...added});
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return _Framed(
      label: widget.label,
      error: widget.error,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.tags.isNotEmpty)
            Wrap(
              spacing: Spacing.s,
              runSpacing: Spacing.xs,
              children: [
                for (final tag in widget.tags)
                  InputChip(
                    label: Text(tag),
                    deleteButtonTooltipMessage: l10n.removeTag(tag),
                    onDeleted: () =>
                        widget.onChanged({...widget.tags}..remove(tag)),
                  ),
              ],
            ),
          TextField(
            controller: _controller,
            decoration: InputDecoration(hintText: l10n.addTag),
            textInputAction: TextInputAction.done,
            inputFormatters: [FilteringTextInputFormatter.singleLineFormatter],
            onSubmitted: _add,
          ),
        ],
      ),
    );
  }
}

class _AudioInput extends StatelessWidget {
  const _AudioInput({
    required this.label,
    required this.error,
    required this.attached,
    required this.length,
    required this.onRecord,
  });

  final String label;
  final String? error;
  final bool attached;
  final Duration? length;
  final VoidCallback? onRecord;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return _Framed(
      label: label,
      error: error,
      child: Row(
        children: [
          Icon(
            attached ? Icons.graphic_eq : Icons.mic_none,
            size: IconSizes.inline,
            // Violet tags audio; the tint is the variant legible as an icon.
            color: ModusColors.rhythmVioletText,
          ),
          const SizedBox(width: Spacing.s),
          Expanded(
            child: Text(switch ((attached, length)) {
              (true, final Duration length) => l10n.recordingAttachedLength(
                formatLength(length),
              ),
              (true, null) => l10n.recordingAttached,
              (false, _) => l10n.noRecording,
            }, style: theme.textTheme.labelMedium),
          ),
          TextButton.icon(
            icon: const Icon(Icons.fiber_manual_record, size: IconSizes.inline),
            label: Text(l10n.record),
            onPressed: onRecord,
          ),
        ],
      ),
    );
  }
}
