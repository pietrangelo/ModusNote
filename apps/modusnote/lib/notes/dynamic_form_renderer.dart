import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import '../audio/recording_sheet.dart' show formatLength;
import '../l10n/generated/app_localizations.dart';
import '../theme/golden_ratio.dart';
import '../theme/modus_colors.dart';
import 'editor/markdown_controller.dart';
import 'editor/markdown_toolbar.dart';
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
/// It is laid out as a page to write on, the way Standard Notes and
/// Notesnook do it: the first one-line text is the title, large and
/// without a frame; the first long text (or else the first list of tasks)
/// is the body, also frameless; recordings stay in sight above it; every
/// other field folds under the title as the note's details.
///
/// Every value is shown through text widgets, never parsed as HTML, so
/// content synced from someone else cannot run as code. A Markdown body
/// is rendered as it is typed, in the field itself
/// ([MarkdownEditingController]).
class DynamicFormRenderer extends StatefulWidget {
  const DynamicFormRenderer({
    required this.schema,
    required this.values,
    required this.onChanged,
    this.violations = const [],
    this.onRecordAudio,
    this.recordingLength,
    this.recordingPlayer,
    this.markdownTarget,
    this.autofocus = false,
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

  /// The player for an attached recording, or null where it cannot be
  /// played; the field then shows only its length.
  final Widget? Function(BlobId blob)? recordingPlayer;

  /// Set to the Markdown body's controller, for a formatting toolbar
  /// outside the form; null when the body is not Markdown.
  final ValueNotifier<MarkdownEditingController?>? markdownTarget;

  /// Puts the cursor in the title, or in the body when there is none.
  final bool autofocus;

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

  late final _layout = _PageLayout.of(widget.schema);
  late var _detailsOpen =
      _layout.details.every((field) => widget.values[field.key] == null) ||
      _layout.details.any(_hasViolation);

  bool _hasViolation(FieldDefinition field) =>
      widget.violations.any((v) => v.field == field.key);

  @override
  void didUpdateWidget(DynamicFormRenderer old) {
    super.didUpdateWidget(old);
    // Errors in a folded detail must be seen.
    if (!_detailsOpen && _layout.details.any(_hasViolation)) {
      _detailsOpen = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final text = SchemaText(l10n);
    Widget keyed(FieldDefinition field, Widget child) =>
        KeyedSubtree(key: ValueKey('field-${field.key}'), child: child);
    final title = _layout.title;
    final body = _layout.body;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (title != null)
          keyed(
            title,
            _TitleInput(
              label: text.label(title.label),
              error: _errorFor(title.key, text),
              value: _values[title.key],
              autofocus: widget.autofocus,
              onChanged: (v) => _set(title.key, v),
            ),
          ),
        if (_layout.details.isNotEmpty) ...[
          _DetailsHeader(
            open: _detailsOpen,
            onToggle: () => setState(() => _detailsOpen = !_detailsOpen),
          ),
          Visibility(
            visible: _detailsOpen,
            maintainState: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final field in _layout.details)
                  keyed(
                    field,
                    Padding(
                      padding: const EdgeInsets.only(bottom: Spacing.l),
                      child: _input(field, text, l10n),
                    ),
                  ),
              ],
            ),
          ),
        ],
        for (final field in _layout.recordings)
          keyed(
            field,
            Padding(
              padding: const EdgeInsets.only(bottom: Spacing.l),
              child: _input(field, text, l10n),
            ),
          ),
        if (body != null)
          keyed(body, switch (body.type) {
            MarkdownFieldType() => _MarkdownInput(
              label: text.label(body.label),
              hint: l10n.editorBodyHint,
              error: _errorFor(body.key, text),
              value: _values[body.key],
              target: widget.markdownTarget,
              autofocus: widget.autofocus && title == null,
              onChanged: (v) => _set(body.key, v),
            ),
            ChecklistFieldType() => _input(body, text, l10n),
            _ => _BodyInput(
              label: text.label(body.label),
              error: _errorFor(body.key, text),
              value: _values[body.key],
              autofocus: widget.autofocus && title == null,
              onChanged: (v) => _set(body.key, v),
            ),
          }),
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
      RichTextFieldType() => _TextInput(
        label: label,
        error: error,
        value: value,
        multiline: true,
        onChanged: set,
      ),
      MarkdownFieldType() => _MarkdownInput(
        label: label,
        hint: label,
        error: error,
        value: value,
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
      ChecklistFieldType() => _ChecklistInput(
        label: label,
        error: error,
        value: value is ChecklistValue ? value : null,
        onChanged: set,
      ),
      AudioBlobFieldType() => _AudioInput(
        label: label,
        error: error,
        attached: value is AudioBlobValue,
        length: value is AudioBlobValue
            ? widget.recordingLength?.call(value.blob)
            : null,
        player: value is AudioBlobValue
            ? widget.recordingPlayer?.call(value.blob)
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

/// The page layout of a schema: which field is the title, which the
/// body, and what is left as details, in the order of [_ordered].
final class _PageLayout {
  _PageLayout(this.title, this.body, this.details, this.recordings);

  factory _PageLayout.of(SchemaDefinition schema) {
    final fields = _DynamicFormRendererState._ordered(schema);
    FieldDefinition? first(bool Function(FieldType) test) {
      for (final field in fields) {
        if (test(field.type)) return field;
      }
      return null;
    }

    final title = first((type) => type is TextFieldType);
    final body =
        first(
          (type) => type is MarkdownFieldType || type is RichTextFieldType,
        ) ??
        first((type) => type is ChecklistFieldType);
    bool rest(FieldDefinition field) => field != title && field != body;
    return _PageLayout(
      title,
      body,
      [
        for (final field in fields)
          if (rest(field) && field.type is! AudioBlobFieldType) field,
      ],
      [
        for (final field in fields)
          if (rest(field) && field.type is AudioBlobFieldType) field,
      ],
    );
  }

  final FieldDefinition? title;
  final FieldDefinition? body;
  final List<FieldDefinition> details;

  /// Recordings: content, not details, so they never fold away.
  final List<FieldDefinition> recordings;
}

/// The note's title: large, without a frame, its label as the hint.
class _TitleInput extends StatefulWidget {
  const _TitleInput({
    required this.label,
    required this.error,
    required this.value,
    required this.autofocus,
    required this.onChanged,
  });

  final String label;
  final String? error;
  final FieldValue? value;
  final bool autofocus;
  final ValueChanged<FieldValue?> onChanged;

  @override
  State<_TitleInput> createState() => _TitleInputState();
}

class _TitleInputState extends State<_TitleInput> {
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
    autofocus: widget.autofocus,
    style: Theme.of(context).textTheme.headlineSmall,
    decoration: InputDecoration(
      hintText: widget.label,
      errorText: widget.error,
      border: InputBorder.none,
      enabledBorder: InputBorder.none,
      focusedBorder: InputBorder.none,
    ),
    textInputAction: TextInputAction.next,
    onChanged: (text) =>
        widget.onChanged(text.isEmpty ? null : TextValue(text)),
  );
}

/// Folds the details of a note away under its title.
class _DetailsHeader extends StatelessWidget {
  const _DetailsHeader({required this.open, required this.onToggle});

  final bool open;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: TextButton.icon(
      key: const ValueKey('details-toggle'),
      onPressed: onToggle,
      icon: Icon(
        open ? Icons.expand_less : Icons.expand_more,
        size: IconSizes.inline,
      ),
      label: Text(AppLocalizations.of(context).editorDetails),
    ),
  );
}

/// A long plain text as the body of the page, without a frame.
class _BodyInput extends StatefulWidget {
  const _BodyInput({
    required this.label,
    required this.error,
    required this.value,
    required this.autofocus,
    required this.onChanged,
  });

  final String label;
  final String? error;
  final FieldValue? value;
  final bool autofocus;
  final ValueChanged<FieldValue?> onChanged;

  @override
  State<_BodyInput> createState() => _BodyInputState();
}

class _BodyInputState extends State<_BodyInput> {
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
    autofocus: widget.autofocus,
    decoration: _pageDecoration(widget.label, widget.error),
    minLines: 8,
    maxLines: null,
    keyboardType: TextInputType.multiline,
    onChanged: (text) =>
        widget.onChanged(text.isEmpty ? null : TextValue(text)),
  );
}

InputDecoration _pageDecoration(String hint, String? error) => InputDecoration(
  hintText: hint,
  errorText: error,
  border: InputBorder.none,
  enabledBorder: InputBorder.none,
  focusedBorder: InputBorder.none,
);

/// A Markdown field, rendered as it is typed: bold looks bold, a heading
/// is large, list markers stand out and their syntax is dimmed, all in
/// the text being edited, with no separate preview. Enter continues a
/// list. Formatting comes from the keyboard shortcuts here and from a
/// toolbar bound through [target].
class _MarkdownInput extends StatefulWidget {
  const _MarkdownInput({
    required this.label,
    required this.hint,
    required this.error,
    required this.value,
    required this.onChanged,
    this.target,
    this.autofocus = false,
  });

  final String label;
  final String hint;
  final String? error;
  final FieldValue? value;
  final ValueChanged<FieldValue?> onChanged;
  final ValueNotifier<MarkdownEditingController?>? target;
  final bool autofocus;

  @override
  State<_MarkdownInput> createState() => _MarkdownInputState();
}

class _MarkdownInputState extends State<_MarkdownInput> {
  late final _controller = MarkdownEditingController(
    text: switch (widget.value) {
      TextValue(:final text) => text,
      _ => '',
    },
  );
  late var _reported = _controller.text;

  @override
  void initState() {
    super.initState();
    // Typing, toolbar buttons and shortcuts all change the text here.
    _controller.addListener(_report);
    // The toolbar is outside this form: tell it after this frame is built.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.target?.value = _controller;
    });
  }

  void _report() {
    final text = _controller.text;
    if (text == _reported) return;
    _reported = text;
    widget.onChanged(text.isEmpty ? null : TextValue(text));
  }

  @override
  void dispose() {
    // Taken off the toolbar after this frame, when nothing is building.
    if (widget.target case final target? when target.value == _controller) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (target.value == _controller) target.value = null;
        _controller.dispose();
      });
    } else {
      _controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      for (final action in MarkdownAction.all)
        action.activator: () => _controller.apply(action.command),
    },
    child: Semantics(
      label: widget.label,
      child: TextField(
        controller: _controller,
        autofocus: widget.autofocus,
        decoration: _pageDecoration(widget.hint, widget.error),
        minLines: 8,
        maxLines: null,
        keyboardType: TextInputType.multiline,
        inputFormatters: const [MarkdownListFormatter()],
      ),
    ),
  );
}

/// A list of tasks, one line each. Enter after a task adds a new one
/// below it; Enter on an empty task removes it and ends the list. Rows
/// without text are never part of the value.
class _ChecklistInput extends StatefulWidget {
  const _ChecklistInput({
    required this.label,
    required this.error,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final String? error;
  final ChecklistValue? value;
  final ValueChanged<FieldValue?> onChanged;

  @override
  State<_ChecklistInput> createState() => _ChecklistInputState();
}

final class _TaskRow {
  _TaskRow(String text, {this.done = false})
    : controller = TextEditingController(text: text);

  final key = UniqueKey();
  final TextEditingController controller;
  final focus = FocusNode();
  bool done;

  void dispose() {
    controller.dispose();
    focus.dispose();
  }
}

class _ChecklistInputState extends State<_ChecklistInput> {
  late final List<_TaskRow> _rows = [
    for (final item in widget.value?.items ?? const <ChecklistItem>[])
      _TaskRow(item.text, done: item.done),
    // A new list starts with one row to type into.
    if (widget.value == null) _TaskRow(''),
  ];

  @override
  void dispose() {
    for (final row in _rows) {
      row.dispose();
    }
    super.dispose();
  }

  void _report() {
    final items = [
      for (final row in _rows)
        if (row.controller.text.trim().isNotEmpty)
          ChecklistItem(row.controller.text.trim(), done: row.done),
    ];
    widget.onChanged(items.isEmpty ? null : ChecklistValue(items));
  }

  void _insertAfter(int index) {
    final row = _TaskRow('');
    setState(() => _rows.insert(index + 1, row));
    row.focus.requestFocus();
  }

  void _submitted(int index) {
    if (_rows[index].controller.text.trim().isNotEmpty) {
      _insertAfter(index);
      return;
    }
    // An empty task closes the list.
    _rows[index].focus.unfocus();
    if (_rows.length > 1) _remove(index);
  }

  void _remove(int index) {
    final row = _rows[index];
    setState(() => _rows.removeAt(index));
    // Its widgets let go of the controller before it is disposed.
    WidgetsBinding.instance.addPostFrameCallback((_) => row.dispose());
    _report();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final done = _rows.where(
      (row) => row.done && row.controller.text.trim().isNotEmpty,
    );
    final total = _rows.where((row) => row.controller.text.trim().isNotEmpty);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(widget.label, style: theme.textTheme.labelMedium),
            ),
            if (total.isNotEmpty)
              Text(
                l10n.taskProgress(done.length, total.length),
                key: const ValueKey('task-progress'),
                style: theme.textTheme.labelSmall,
              ),
          ],
        ),
        for (final (index, row) in _rows.indexed)
          Row(
            key: row.key,
            children: [
              Checkbox(
                value: row.done,
                activeColor: ModusColors.cadenceCyan,
                checkColor: ModusColors.deepVoid,
                onChanged: (value) {
                  setState(() => row.done = value ?? false);
                  _report();
                },
              ),
              Expanded(
                child: TextField(
                  controller: row.controller,
                  focusNode: row.focus,
                  decoration: InputDecoration(
                    hintText: l10n.taskHint,
                    border: InputBorder.none,
                  ),
                  style: row.done
                      ? theme.textTheme.bodyLarge?.copyWith(
                          color: ModusColors.dustSilver,
                          decoration: TextDecoration.lineThrough,
                        )
                      : null,
                  textInputAction: TextInputAction.next,
                  // Enter is handled below, never as a jump to the next field.
                  onEditingComplete: () {},
                  onSubmitted: (_) => _submitted(index),
                  onChanged: (_) {
                    setState(() {});
                    _report();
                  },
                ),
              ),
              if (_rows.length > 1)
                IconButton(
                  icon: const Icon(Icons.close, size: IconSizes.inline),
                  color: ModusColors.dustSilver,
                  tooltip: l10n.removeTask,
                  onPressed: () => _remove(index),
                ),
            ],
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => _rows.last.controller.text.trim().isEmpty
                ? _rows.last.focus.requestFocus()
                : _insertAfter(_rows.length - 1),
            icon: const Icon(Icons.add, size: IconSizes.inline),
            label: Text(l10n.addTask),
          ),
        ),
        if (widget.error case final error?)
          Text(
            error,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
      ],
    );
  }
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
    required this.player,
    required this.onRecord,
  });

  final String label;
  final String? error;
  final bool attached;
  final Duration? length;
  final Widget? player;
  final VoidCallback? onRecord;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final record = TextButton.icon(
      icon: const Icon(Icons.fiber_manual_record, size: IconSizes.inline),
      label: Text(l10n.record),
      onPressed: onRecord,
    );
    return _Framed(
      label: label,
      error: error,
      // The player takes the whole width, so its waveform stays readable
      // on a phone; recording again moves below it.
      child: switch (player) {
        final player? => Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [player, record],
        ),
        null => Row(
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
            record,
          ],
        ),
      },
    );
  }
}
