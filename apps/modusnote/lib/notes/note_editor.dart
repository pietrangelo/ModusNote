import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:blob_storage_media/blob_storage_media.dart';
import 'package:flutter/material.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import '../attachments/open_in_browser.dart';
import '../audio/recording_player_view.dart';
import '../audio/recording_sheet.dart';
import '../l10n/generated/app_localizations.dart';
import '../theme/golden_ratio.dart';
import '../vault/auto_lock.dart';
import 'attachments/attachments_input.dart';
import 'books/book_outline.dart';
import 'books/book_section.dart';
import 'documents/page_index.dart';
import 'documents/page_index_section.dart';
import 'dynamic_form_renderer.dart';
import 'editor/markdown_commands.dart';
import 'editor/markdown_controller.dart';
import 'editor/markdown_toolbar.dart';
import 'links/note_links_section.dart';
import 'links/note_picker.dart';
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
    this.category,
    this.clock = DateTime.now,
    this.openLink = openInBrowser,
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

  /// Where a new note is filed; an existing one stays where it is.
  final CategoryId? category;
  final DateTime Function() clock;

  /// Opens a link the person confirmed; the browser outside tests.
  final LinkOpener openLink;

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

  /// Where a new note goes: the category open when it was started, even if
  /// the list beside it moves on to another.
  late final CategoryId? _newIn;

  /// Takes recorded since the last save; kept only once a save holds them.
  final _takes = <BlobId, KeyedRecording>{};

  /// Pictures added since the last save, likewise.
  final _pictures = <BlobId, KeyedImage>{};

  final _markdown = ValueNotifier<MarkdownEditingController?>(null);

  /// The words of a chapter's text, counted as it is typed.
  late final _words = ValueNotifier<int>(_countWords());
  Timer? _timer;
  var _dirty = false;
  var _state = SaveState.saved;
  Future<SaveState>? _saving;

  @override
  void initState() {
    super.initState();
    _newIn = widget.category;
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
    _words.value = _countWords();
    _changed();
  }

  void _onDraft(FormDraft draft) {
    _draft = draft;
    if (_isChapter) _words.value = _countWords();
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
    // A picture picked while this save runs waits for the next one.
    final takes = _takes.values.toList();
    final pictures = _pictures.values.toList();
    _show(SaveState.saving);
    // A save is not cut short by the vault locking itself.
    final release = AutoLockScope.maybeOf(context)?.hold();
    try {
      await widget.store.save(
        entry,
        takes: takes,
        pictures: pictures,
        newIn: _newIn,
      );
    } on Object {
      return _show(SaveState.failed);
    } finally {
      release?.call();
    }
    _saved = entry;
    for (final take in takes) {
      _takes.remove(take.id);
    }
    for (final picture in pictures) {
      _pictures.remove(picture.id);
    }
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

  /// Picks a picture and seals it; it joins the note at the next save.
  Future<BlobId?> _addImage() async {
    final images = widget.store.images;
    if (images == null) return null;
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    // The system's picker sends the app to the background: the vault must
    // still be open when the picture comes back.
    final release = AutoLockScope.maybeOf(context)?.hold();
    try {
      final image = await images.choose();
      if (image == null) return null;
      _pictures[image.id] = image;
      return image.id;
    } on UnsupportedImageException {
      messenger.showSnackBar(SnackBar(content: Text(l10n.imageUnsupported)));
    } on ImageTooLargeException {
      messenger.showSnackBar(SnackBar(content: Text(l10n.imageUnsupported)));
    } on Object {
      messenger.showSnackBar(SnackBar(content: Text(l10n.imageAddFailed)));
    } finally {
      release?.call();
    }
    return null;
  }

  Future<Uint8List> _openImage(BlobId blob) {
    final images = widget.store.images;
    final image = _pictures[blob] ?? widget.store.imageOf(blob);
    if (images == null || image == null) {
      return Future.error(BlobNotFoundException(blob));
    }
    return images.open(image);
  }

  SchemaDefinition? _schemaOf(DynamicEntry entry) {
    for (final schema in widget.schemas) {
      if (schema.id == entry.schemaId) return schema;
    }
    return null;
  }

  DynamicEntry? _find(EntryId id) {
    for (final entry in widget.store.entries) {
      if (entry.id == id) return entry;
    }
    return null;
  }

  /// Picks another note and links to it where the cursor is.
  Future<void> _linkNote() async {
    final controller = _markdown.value;
    if (controller == null) return;
    final picked = await showNotePicker(
      context,
      notes: [
        for (final entry in widget.store.entries)
          if (entry.id != _id) entry,
      ],
      schemaOf: _schemaOf,
    );
    if (picked == null || !mounted || _markdown.value != controller) return;
    controller.apply(
      (value) => MarkdownCommands.noteLink(
        value,
        title: picked.title,
        target: picked.id,
      ),
    );
  }

  bool get _isChapter => _schema.id.name == BookOutline.chapter;

  int _countWords() => switch (_draft.values[FieldKey('body')]) {
    TextValue(:final text) when _isChapter => WordCount.of(text),
    _ => 0,
  };

  /// Where this note is filed, or will be once first saved.
  CategoryId? get _category =>
      widget.store.categoryOf(_id) ?? (_saved == null ? _newIn : null);

  /// Opens a linked note over this one, once this one is saved.
  Future<void> _openLinked(DynamicEntry entry) async {
    final schema = _schemaOf(entry);
    if (schema != null) await _openOver(schema, entry: entry);
  }

  /// Opens [entry], or a new note of [schema] filed in [category], over
  /// this one, once this one is saved.
  Future<void> _openOver(
    SchemaDefinition schema, {
    DynamicEntry? entry,
    CategoryId? category,
  }) async {
    final navigator = Navigator.of(context);
    final autoLock = AutoLockScope.maybeOf(context);
    await _flush();
    if (!mounted) return;
    final screen = NoteEditorScreen(
      schemas: widget.schemas,
      store: widget.store,
      initialSchema: schema,
      entry: entry,
      category: category,
      clock: widget.clock,
      openLink: widget.openLink,
    );
    // A pushed route sits beside the library, not under it: it gets the
    // vault's auto-lock passed along explicitly.
    await navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => autoLock == null
            ? screen
            : AutoLockScope(autoLock: autoLock, child: screen),
      ),
    );
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
    if (_takes.isNotEmpty || _pictures.isNotEmpty) {
      widget.store.discardTakes([..._takes.values, ..._pictures.values]);
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
                        attachments: AttachmentHooks(
                          addImage: widget.store.images == null
                              ? null
                              : _addImage,
                          openImage: _openImage,
                          openLink: widget.openLink,
                        ),
                      ),
                      if (_isChapter)
                        Align(
                          alignment: AlignmentDirectional.centerEnd,
                          child: ValueListenableBuilder(
                            valueListenable: _words,
                            builder: (context, words, _) => Text(
                              l10n.wordCount(words),
                              key: const ValueKey('chapter-words'),
                              style: theme.textTheme.labelSmall,
                            ),
                          ),
                        ),
                      if (_schema.id.name == BookOutline.book)
                        ListenableBuilder(
                          listenable: widget.store,
                          builder: (context, _) {
                            final category = _category;
                            return BookSection(
                              outline: BookOutline.of(
                                category: category,
                                store: widget.store,
                                schemaOf: _schemaOf,
                              ),
                              goal: switch (_draft.values[FieldKey(
                                'word_goal',
                              )]) {
                                NumberValue(:final number) => number.toInt(),
                                _ => null,
                              },
                              schemas: widget.schemas,
                              onOpen: _openLinked,
                              onAdd: (schema) =>
                                  _openOver(schema, category: category),
                            );
                          },
                        ),
                      if (_schema.id.name == PageIndex.document)
                        ListenableBuilder(
                          listenable: widget.store,
                          builder: (context, _) {
                            final category = _category;
                            return PageIndexSection(
                              sections: PageIndex.of(
                                category: category,
                                store: widget.store,
                                schemaOf: _schemaOf,
                              ),
                              current: _id,
                              schemaOf: _schemaOf,
                              onOpen: _openLinked,
                              onAdd: () =>
                                  _openOver(_schema, category: category),
                            );
                          },
                        ),
                      ListenableBuilder(
                        listenable: widget.store,
                        builder: (context, _) => NoteLinksSection(
                          links: NoteLinks.targets(_draft.values.values),
                          backlinks: [
                            for (final entry in widget.store.entries)
                              if (entry.id != _id &&
                                  NoteLinks.targets(entry.attributes.values)
                                      .contains(_id))
                                entry,
                          ],
                          find: _find,
                          schemaOf: _schemaOf,
                          onOpen: _openLinked,
                        ),
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
                          child: MarkdownToolbar(
                            controller: controller,
                            onLinkNote: _linkNote,
                          ),
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
