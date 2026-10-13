import 'dart:async';
import 'dart:math';

import 'package:blob_storage_media/blob_storage_media.dart';
import 'package:flutter/material.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import '../audio/recording_player_view.dart';
import '../audio/recording_sheet.dart';
import '../l10n/generated/app_localizations.dart';
import '../theme/golden_ratio.dart';
import '../vault/auto_lock.dart';
import 'dynamic_form_renderer.dart';
import 'editor/markdown_controller.dart';
import 'editor/markdown_toolbar.dart';
import 'note_appearance.dart';
import 'note_store.dart';
import 'schema_text.dart';

/// Where an edit stands, as the app bar shows it.
enum SaveState { saved, saving, incomplete, failed }

/// Writes a new note or edits one, as a page: title, details, body. There
/// is no save button: every change is saved a moment after typing stops,
/// when the app goes to the background, and when the page is left. A note
/// that cannot be saved yet (a required field is empty) says so, and
/// leaving it asks whether to keep writing or discard.
///
/// Until a new note is first saved its type can be switched from the app
/// bar, keeping whatever still fits the new type.
///
/// On a page of its own it goes back when left. Beside the list on a wide
/// screen it is closed by [onClose] instead, and whoever shows another
/// note in its place asks it to [NoteEditorScreenState.settle] first.
class NoteEditorScreen extends StatefulWidget {
  const NoteEditorScreen({
    required this.schemas,
    required this.store,
    required this.initialSchema,
    this.entry,
    this.onClose,
    this.clock = DateTime.now,
    super.key,
  });

  final List<SchemaDefinition> schemas;
  final NoteStore store;
  final SchemaDefinition initialSchema;

  /// The note being edited, or null for a new one.
  final DynamicEntry? entry;

  /// Closes the note when it is shown beside the list; null on a page of
  /// its own, which goes back instead.
  final VoidCallback? onClose;
  final DateTime Function() clock;

  /// How long typing must pause before the note is saved.
  static const autosaveDelay = Duration(seconds: 1);

  @override
  State<NoteEditorScreen> createState() => NoteEditorScreenState();
}

class NoteEditorScreenState extends State<NoteEditorScreen>
    with WidgetsBindingObserver {
  late SchemaDefinition _schema = widget.initialSchema;
  late FormDraft _draft = FormDraft(widget.entry?.attributes ?? const {}, {});
  List<Violation> _violations = const [];

  /// The note as last saved; null for a new note not saved yet.
  late DynamicEntry? _saved = widget.entry;

  /// The id a new note will be saved under.
  late final EntryId _id = widget.entry?.id ?? _newEntryId();

  /// Takes recorded since the last save; kept only once a save holds them.
  final _takes = <BlobId, KeyedRecording>{};

  final _markdown = ValueNotifier<MarkdownEditingController?>(null);
  Timer? _timer;
  var _dirty = false;
  var _state = SaveState.saved;
  Future<SaveState>? _saving;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      unawaited(_flush());
    }
  }

  void _switchTo(SchemaDefinition schema) {
    if (schema.id == _schema.id) return;
    setState(() {
      _draft = FormDraft(
        SchemaSwitch.carryOver(
          from: _schema,
          values: _draft.values,
          to: schema,
        ),
        {},
      );
      _schema = schema;
      _violations = const [];
    });
    _changed();
  }

  void _onDraft(FormDraft draft) {
    _draft = draft;
    // Typing on a soft keyboard is not a pointer event.
    AutoLockScope.maybeOf(context)?.touch();
    _changed();
  }

  void _changed() {
    _timer?.cancel();
    _timer = Timer(NoteEditorScreen.autosaveDelay, () => unawaited(_flush()));
    if (!_dirty) setState(() => _dirty = true);
  }

  /// Saves what is pending now, one save at a time; what changes during a
  /// save is saved right after it.
  Future<SaveState> _flush() async {
    _timer?.cancel();
    while (_saving != null) {
      await _saving;
    }
    var state = _state;
    while (_dirty && mounted) {
      final saving = _saveDraft();
      _saving = saving;
      try {
        state = await saving;
      } finally {
        _saving = null;
      }
      if (state != SaveState.saving) break;
    }
    return _dirty ? state : SaveState.saved;
  }

  Future<SaveState> _saveDraft() async {
    final values = _draft.values;
    final unreadable = [
      for (final key in _draft.unreadable)
        Violation(ViolationCode.typeMismatch, key),
    ];
    final saved = _saved;
    // An empty new note is not a note yet.
    if (saved == null && values.isEmpty && unreadable.isEmpty) {
      _dirty = false;
      return _show(SaveState.saved);
    }
    final at = widget.clock().toUtc();
    final result = saved == null
        ? DynamicEntry.create(
            schema: _schema,
            id: _id,
            attributes: values,
            at: at,
          )
        : saved.update(
            schema: _schema,
            changes: {
              for (final field in _schema.fields) field.key: values[field.key],
            },
            at: at,
          );
    final DynamicEntry entry;
    switch (result) {
      case Valid(:final value) when unreadable.isEmpty:
        entry = value;
      case Valid():
        _pendingViolations = unreadable;
        return _show(SaveState.incomplete);
      case Invalid(:final violations):
        _pendingViolations = [...violations, ...unreadable];
        return _show(SaveState.incomplete);
    }
    final draft = _draft;
    _show(SaveState.saving);
    // A save is not cut short by the vault locking itself.
    final release = AutoLockScope.maybeOf(context)?.hold();
    try {
      await widget.store.save(entry, takes: _takes.values.toList());
    } on Object {
      return _show(SaveState.failed);
    } finally {
      release?.call();
    }
    _saved = entry;
    _takes.clear();
    _pendingViolations = const [];
    // Typing during the save leaves the note to be saved again.
    if (identical(draft, _draft)) _dirty = false;
    if (mounted) setState(() => _violations = const []);
    return _show(_dirty ? SaveState.saving : SaveState.saved);
  }

  /// Why the draft cannot be saved; shown once the user tries to leave.
  List<Violation> _pendingViolations = const [];

  SaveState _show(SaveState state) {
    if (mounted && state != _state) setState(() => _state = state);
    _state = state;
    return state;
  }

  /// Back, or close: saves first; a note that cannot be saved asks what
  /// to do.
  Future<void> _leave() async {
    if (await settle() && mounted) _close();
  }

  void _close() {
    if (widget.onClose case final onClose?) {
      onClose();
    } else {
      Navigator.of(context).pop();
    }
  }

  /// Saves what is pending and says whether the note may go: false when it
  /// cannot be saved and the user chose to keep writing.
  Future<bool> settle() async {
    final state = await _flush();
    if (!mounted) return true;
    if (state == SaveState.saved || !_dirty) {
      _dirty = false;
      return true;
    }
    setState(() => _violations = _pendingViolations);
    final l10n = AppLocalizations.of(context);
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          state == SaveState.failed
              ? l10n.editorSaveFailed
              : l10n.editorLeaveTitle,
        ),
        content: Text(l10n.editorLeaveBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.editorKeepWriting),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.editorDiscard),
          ),
        ],
      ),
    );
    if (discard != true) return false;
    if (mounted) setState(() => _dirty = false);
    return true;
  }

  /// Moves the note to the trash, with a way back in the snackbar. A new
  /// note never saved just goes.
  Future<void> _trash() async {
    _timer?.cancel();
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final store = widget.store;
    if (await _flush() != SaveState.saved || _saved == null) {
      if (!mounted) return;
      setState(() => _dirty = false);
      _close();
      return;
    }
    await store.moveToTrash(_id);
    final id = _id;
    // The undo must show now, not queued behind an older message.
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(l10n.noteTrashed),
          action: SnackBarAction(
            label: l10n.undo,
            onPressed: () => store.restore(id),
          ),
        ),
      );
    if (mounted) {
      setState(() => _dirty = false);
      _close();
    }
  }

  Future<BlobId?> _record(FieldDefinition field) async {
    final recorder = widget.store.recorder;
    if (recorder == null) return null;
    final take = await RecordingSheet.show(context, recorder);
    if (take == null) return null;
    _takes[take.id] = take;
    return take.id;
  }

  Duration? _lengthOf(BlobId blob) =>
      (_takes[blob] ?? widget.store.recordingOf(blob))?.metadata.duration;

  Widget? _playerOf(BlobId blob) {
    final playback = widget.store.playback;
    final take = _takes[blob] ?? widget.store.recordingOf(blob);
    if (playback == null || take == null || !playback.canPlay(take)) {
      return null;
    }
    return RecordingPlayerView(
      // A new take is a new player: the old samples go with the old one.
      key: ValueKey(blob),
      open: () => playback.open(take),
      length: take.metadata.duration,
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Closed from outside (the vault locking): what was not saved goes,
    // since the keys to save it are being released.
    _timer?.cancel();
    if (_takes.isNotEmpty) {
      widget.store.discardTakes(_takes.values.toList());
    }
    // [_markdown] is left to the garbage collector: the Markdown field
    // clears it after this frame, which must not find it disposed.
    super.dispose();
  }

  /// Opaque and random: ids reach the server in clear, so they must not
  /// reveal order, time or device. 128 bits as 32 hex digits, the shape of
  /// the record id the note is stored under.
  static EntryId _newEntryId() {
    final random = Random.secure();
    return EntryId(
      List.generate(
        16,
        (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final text = SchemaText(l10n);
    final theme = Theme.of(context);
    final status = switch (_state) {
      SaveState.saved => _dirty || _saved == null ? null : l10n.editorSaved,
      SaveState.saving => l10n.editorSaving,
      SaveState.incomplete => l10n.editorIncomplete,
      SaveState.failed => l10n.editorSaveFailed,
    };
    final embedded = widget.onClose != null;
    return PopScope(
      // Beside the list there is nothing to go back to.
      canPop: embedded || !_dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave();
      },
      child: Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: !embedded,
          leading: embedded
              ? IconButton(
                  onPressed: _leave,
                  tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                  icon: const Icon(Icons.close),
                )
              : null,
          title: _TypeTitle(
            schema: _schema,
            schemas: _saved == null ? widget.schemas : const [],
            text: text,
            onSwitch: _switchTo,
          ),
          actions: [
            if (status != null)
              Center(
                child: Text(
                  status,
                  key: const ValueKey('save-state'),
                  style: theme.textTheme.labelSmall,
                ),
              ),
            if (_saved != null)
              IconButton(
                onPressed: _trash,
                tooltip: l10n.moveToTrash,
                icon: const Icon(Icons.delete_outline),
              ),
            const SizedBox(width: Spacing.s),
          ],
        ),
        body: Column(
          children: [
            Expanded(
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: Extents.xxl),
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(
                      Spacing.l,
                      Spacing.s,
                      Spacing.l,
                      Spacing.xxl,
                    ),
                    children: [
                      DynamicFormRenderer(
                        // A new type is a new page, filled with what was
                        // carried over.
                        key: ValueKey(_schema.id),
                        schema: _schema,
                        values: _draft.values,
                        violations: _violations,
                        autofocus: widget.entry == null,
                        markdownTarget: _markdown,
                        onChanged: _onDraft,
                        onRecordAudio: widget.store.recorder == null
                            ? null
                            : _record,
                        recordingLength: _lengthOf,
                        recordingPlayer: _playerOf,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            ValueListenableBuilder(
              valueListenable: _markdown,
              builder: (context, controller, _) => controller == null
                  ? const SizedBox.shrink()
                  : SafeArea(
                      top: false,
                      // Taps on the toolbar keep the keyboard up.
                      child: TextFieldTapRegion(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surface,
                            border: Border(
                              top: BorderSide(color: theme.dividerColor),
                            ),
                          ),
                          child: MarkdownToolbar(controller: controller),
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The note's type in the app bar; a menu to switch it while [schemas]
/// offers any (a new note not saved yet).
class _TypeTitle extends StatelessWidget {
  const _TypeTitle({
    required this.schema,
    required this.schemas,
    required this.text,
    required this.onSwitch,
  });

  final SchemaDefinition schema;
  final List<SchemaDefinition> schemas;
  final SchemaText text;
  final ValueChanged<SchemaDefinition> onSwitch;

  Widget _label(SchemaDefinition schema) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(
        NoteAppearance.icon(schema.icon),
        size: IconSizes.inline,
        color: NoteAppearance.tint(schema.tint),
      ),
      const SizedBox(width: Spacing.s),
      Flexible(
        child: Text(text.label(schema.label), overflow: TextOverflow.ellipsis),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    if (schemas.isEmpty) return _label(schema);
    // A menu button with a child is not announced as a button by itself,
    // and in the app bar's title it would merge into the route's heading.
    return Semantics(
      container: true,
      button: true,
      child: PopupMenuButton<SchemaDefinition>(
        key: const ValueKey('note-type'),
        tooltip: AppLocalizations.of(context).noteType,
        onSelected: onSwitch,
        itemBuilder: (_) => [
          for (final option in schemas)
            PopupMenuItem(value: option, child: _label(option)),
        ],
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(child: _label(schema)),
            const Icon(Icons.arrow_drop_down),
          ],
        ),
      ),
    );
  }
}
