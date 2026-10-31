import 'dart:async';
import 'dart:math';

import 'package:blob_storage_media/blob_storage_media.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:publishing/publishing.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import '../attachments/open_in_browser.dart';
import '../audio/recording_player_view.dart';
import '../audio/recording_sheet.dart';
import '../appearance/appearance_scope.dart';
import '../appearance/page_appearance.dart';
import '../appearance/page_sheet.dart';
import '../l10n/generated/app_localizations.dart';
import '../publishing/publish_sheet.dart';
import '../theme/golden_ratio.dart';
import '../theme/modus_theme.dart';
import '../theme/modus_themes.dart';
import '../vault/auto_lock.dart';
import 'attachments/attachments_input.dart';
import 'books/book_outline.dart';
import 'books/book_section.dart';
import 'documents/page_index.dart';
import 'documents/page_index_section.dart';
import 'journal/journal_days.dart';
import 'journal/on_this_day_section.dart';
import 'draft_merge.dart';
import 'dynamic_form_renderer.dart';
import 'editor/markdown_commands.dart';
import 'editor/markdown_controller.dart';
import 'editor/markdown_toolbar.dart';
import 'links/note_links_section.dart';
import 'links/note_picker.dart';
import 'note_appearance.dart';
import 'note_store.dart';
import 'schema_text.dart';
import '../theme/modus_palette.dart';

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
///
/// Focus mode ([focusActivator], or the button in the app bar) leaves only
/// the title and the text: no details, recordings, attachments, toolbar or
/// sections below, and [onFocusChanged] lets the library fold its columns
/// away too. Escape, or back, leaves it.
class NoteEditorScreen extends StatefulWidget {
  const NoteEditorScreen({
    required this.schemas,
    required this.store,
    required this.initialSchema,
    this.offered,
    this.entry,
    this.onClose,
    this.onFocusChanged,
    this.category,
    this.day,
    this.clock = DateTime.now,
    this.openLink = openInBrowser,
    super.key,
  });

  final List<SchemaDefinition> schemas;
  final NoteStore store;
  final SchemaDefinition initialSchema;

  /// The types a new note may take, here and in the notes it starts (a
  /// book's chapter, a manual's page); [schemas] when null. A note of a
  /// type turned off still opens and saves.
  final List<SchemaDefinition>? offered;

  /// The note being edited, or null for a new one.
  final DynamicEntry? entry;

  /// Closes the note when it is shown beside the list; null on a page of
  /// its own, which goes back instead.
  final VoidCallback? onClose;

  /// Told when focus mode starts or ends.
  final ValueChanged<bool>? onFocusChanged;

  /// Where a new note is filed; an existing one stays where it is.
  final CategoryId? category;

  /// The day a new journal page is about; today when null.
  final DateValue? day;
  final DateTime Function() clock;

  /// Opens a link the person confirmed; the browser outside tests.
  final LinkOpener openLink;

  /// How long typing must pause before the note is saved.
  static const autosaveDelay = Duration(seconds: 1);

  /// How long typing must pause before a chapter's or a journal page's
  /// words are counted again: counting a long text on every key is wasted.
  static const wordCountDelay = Duration(milliseconds: 377);

  /// Ctrl+Shift+F, or ⌘⇧F on Apple platforms: focus mode on and off.
  static SingleActivator get focusActivator => SingleActivator(
    LogicalKeyboardKey.keyF,
    control: !_apple,
    meta: _apple,
    shift: true,
  );

  static bool get _apple =>
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.iOS;

  /// The focus button's tooltip, with its shortcut.
  static String focusTooltip(AppLocalizations l10n, {required bool focused}) =>
      '${focused ? l10n.exitFocusMode : l10n.focusMode} '
      '(${_apple ? '⌘⇧F' : 'Ctrl+Shift+F'})';

  @override
  State<NoteEditorScreen> createState() => NoteEditorScreenState();
}

class NoteEditorScreenState extends State<NoteEditorScreen>
    with WidgetsBindingObserver {
  late SchemaDefinition _schema = widget.initialSchema;

  /// What a new note starts with: a journal page, its day. A new note
  /// holding only that is not a note yet.
  late Map<FieldKey, FieldValue> _prefill = widget.entry == null
      ? _prefillFor(widget.initialSchema, const {})
      : const {};
  late FormDraft _draft = FormDraft(widget.entry?.attributes ?? _prefill, {});
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

  /// The words of a chapter's or a journal page's text, counted as it is
  /// typed.
  late final _words = ValueNotifier<int>(_countWords());

  /// The day of a journal page, as it is picked.
  late final _day = ValueNotifier<DateValue?>(_dayOf(_draft.values));
  Timer? _timer;
  Timer? _recount;
  var _dirty = false;
  var _state = SaveState.saved;
  Future<SaveState>? _saving;
  var _focused = false;

  /// Bumped when the draft is replaced from outside (another device saved
  /// the note), so the fields show the new values.
  var _generation = 0;

  /// The editor is going away by itself: what the store says no longer
  /// matters.
  var _leaving = false;

  /// Whether only the title and the text show.
  bool get focused => _focused;

  /// Turns focus mode on or off.
  void toggleFocus() {
    setState(() => _focused = !_focused);
    widget.onFocusChanged?.call(_focused);
  }

  @override
  void initState() {
    super.initState();
    _newIn = widget.category;
    WidgetsBinding.instance.addObserver(this);
    widget.store.addListener(_storeChanged);
  }

  /// Another device's edit reached the open note (a sync read the notes
  /// again): the draft takes it in, field by field, instead of saving
  /// over it at the next key. Where both sides changed a field the draft
  /// keeps its own, and the other version is kept as a copy first. A note
  /// deleted or put in the trash elsewhere closes, unless something is
  /// being typed: saving that keeps it.
  void _storeChanged() {
    final saved = _saved;
    if (saved == null || _saving != null || _leaving || !mounted) return;
    final latest = widget.store.entryOf(_id);
    if (latest == null) {
      if (_dirty) return;
      _leaving = true;
      _timer?.cancel();
      scheduleMicrotask(() {
        if (mounted) _close();
      });
      return;
    }
    if (latest.audit == saved.audit) return;
    // A note upgraded to a new version of its type is shown as it was.
    if (latest.schemaId != _schema.id) return;
    final merge = DraftMerge.of(
      base: saved.attributes,
      mine: _draft.values,
      theirs: latest.attributes,
    );
    // Before the copy: making it notifies again.
    _saved = latest;
    if (merge.clashes.isNotEmpty) {
      unawaited(widget.store.keepConflictCopy(_id));
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context).editorChangedElsewhere),
        ),
      );
    }
    if (!mapEquals(merge.values, _draft.values)) {
      setState(() {
        _draft = FormDraft(merge.values, _draft.unreadable);
        _generation++;
      });
      _words.value = _countWords();
      _day.value = _dayOf(_draft.values);
    }
    if (mapEquals(merge.values, latest.attributes) &&
        _draft.unreadable.isEmpty) {
      _timer?.cancel();
      _dirty = false;
      _show(SaveState.saved);
    }
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
      final carried = SchemaSwitch.carryOver(
        from: _schema,
        values: _draft.values,
        to: schema,
      );
      _prefill = _prefillFor(schema, carried);
      _draft = FormDraft({..._prefill, ...carried}, {});
      _schema = schema;
      _violations = const [];
    });
    _words.value = _countWords();
    _day.value = _dayOf(_draft.values);
    _changed();
  }

  /// A new journal page is about [NoteEditorScreen.day], or today, unless
  /// [values] already say which day.
  Map<FieldKey, FieldValue> _prefillFor(
    SchemaDefinition schema,
    Map<FieldKey, FieldValue> values,
  ) =>
      schema.id.name == Journal.schema &&
          schema.fieldFor(Journal.date)?.type is DateFieldType &&
          values[Journal.date] == null
      ? {Journal.date: widget.day ?? JournalDays.of(widget.clock())}
      : const {};

  DateValue? _dayOf(Map<FieldKey, FieldValue> values) =>
      switch (values[Journal.date]) {
        final DateValue day when _isJournal => day,
        _ => null,
      };

  void _onDraft(FormDraft draft) {
    _draft = draft;
    if (_countedField != null) {
      _recount?.cancel();
      _recount = Timer(
        NoteEditorScreen.wordCountDelay,
        () => _words.value = _countWords(),
      );
    }
    if (_isJournal) _day.value = _dayOf(draft.values);
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
    // What another device saved while this one was saving.
    _storeChanged();
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
    if (saved == null && mapEquals(values, _prefill) && unreadable.isEmpty) {
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
    // A picture pasted from another note's text brings its metadata from
    // there; one this vault does not know cannot be saved.
    final pictures = [
      ..._pictures.values,
      for (final blob in InlineImages.picturesOf(entry))
        if (!_pictures.containsKey(blob)) ?widget.store.imageOf(blob),
    ];
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
    // The missing fields must be seen, and focus mode hides most of them.
    if (_focused) toggleFocus();
    final l10n = AppLocalizations.of(context);
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          state == SaveState.failed
              ? l10n.editorSaveFailed
              : l10n.editorLeaveTitle,
        ),
        // A failed write highlights no field: it is the vault saying no.
        content: Text(
          state == SaveState.failed
              ? l10n.editorSaveFailedBody
              : l10n.editorLeaveBody,
        ),
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
    _leaving = true;
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

  List<SchemaDefinition> get _offered => widget.offered ?? widget.schemas;

  SchemaDefinition? _schemaOf(DynamicEntry entry) {
    for (final schema in widget.schemas) {
      if (schema.id == entry.schemaId) return schema;
    }
    return null;
  }

  DynamicEntry? _find(EntryId id) => widget.store.entryOf(id);

  /// Picks a picture, seals it and puts it in the text where the cursor
  /// is; it joins the note at the next save.
  Future<void> _insertImage() async {
    final controller = _markdown.value;
    if (controller == null) return;
    final blob = await _addImage();
    if (blob == null || !mounted || _markdown.value != controller) return;
    controller.apply((value) => MarkdownCommands.image(value, blob));
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

  bool get _isJournal => _schema.id.name == Journal.schema;

  /// The text whose words are counted as it is typed: a chapter's, a
  /// journal page's.
  FieldKey? get _countedField => _isChapter
      ? FieldKey('body')
      : _isJournal
      ? Journal.page
      : null;

  int _countWords() => switch (_countedField) {
    final field? => switch (_draft.values[field]) {
      TextValue(:final text) => WordCount.of(text),
      _ => 0,
    },
    null => 0,
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
      offered: widget.offered,
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
    widget.store.removeListener(_storeChanged);
    // Closed from outside (the vault locking): what was not saved goes,
    // since the keys to save it are being released.
    _timer?.cancel();
    _recount?.cancel();
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

  /// The page in the typeface this device chose: the note's title and text
  /// alike, falling back to the body font (and then the music signs) for
  /// what the typeface lacks. Inter keeps the app's own pairing.
  static Widget _inFont(ThemeData theme, PageFont font, Widget page) =>
      font == PageFont.inter
      ? page
      : Theme(
          data: theme.copyWith(
            textTheme: theme.textTheme.apply(
              fontFamily: font.family,
              fontFamilyFallback: const [
                ModusTheme.bodyFont,
                ModusTheme.symbolFont,
              ],
            ),
          ),
          child: page,
        );

  /// The page in the mood of the note's type, within the app's theme: a
  /// new type, picked while writing, changes it smoothly.
  @override
  Widget build(BuildContext context) {
    final appearance = AppearanceScope.maybeOf(context);
    if (appearance == null) return _page(context);
    return AnimatedTheme(
      data: ModusTheme.of(appearance.pagePalette(_schema)),
      duration: ModusThemes.transition,
      child: Builder(builder: _page),
    );
  }

  Widget _page(BuildContext context) {
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
    final focused = _focused;
    final publishing = PublishingScope.maybeOf(context);
    final appearance = AppearanceScope.maybeOf(context);
    final page = appearance?.page ?? const PageAppearance();
    final font = appearance?.shownFont ?? PageFont.inter;
    // On a narrow window the page is the screen: only a wide one offers
    // the other widths.
    final width = MediaQuery.sizeOf(context).width >= PageAppearance.wideFrom
        ? page.width
        : PageWidth.narrow;
    return PopScope(
      // Beside the list there is nothing to go back to; in focus mode back
      // leaves focus mode first.
      canPop: !focused && (embedded || !_dirty),
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (focused) {
          toggleFocus();
        } else {
          _leave();
        }
      },
      child: CallbackShortcuts(
        bindings: {
          NoteEditorScreen.focusActivator: toggleFocus,
          if (focused)
            const SingleActivator(LogicalKeyboardKey.escape): toggleFocus,
        },
        child: Scaffold(
          appBar: AppBar(
            automaticallyImplyLeading: !embedded && !focused,
            leading: focused
                ? null
                : embedded
                ? IconButton(
                    onPressed: _leave,
                    tooltip: MaterialLocalizations.of(context)
                        .closeButtonTooltip,
                    icon: const Icon(Icons.close),
                  )
                : null,
            title: focused
                ? null
                : _TypeTitle(
                    schema: _schema,
                    schemas: _saved == null ? _offered : const [],
                    text: text,
                    onSwitch: _switchTo,
                  ),
            actions: [
              if (status != null)
                // At most two short lines, so that a phone's app bar keeps
                // room for back, the type and the buttons.
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: Extents.s),
                  child: Center(
                    child: Text(
                      status,
                      key: const ValueKey('save-state'),
                      style: theme.textTheme.labelSmall,
                      textAlign: TextAlign.end,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              if (appearance != null)
                IconButton(
                  key: const ValueKey('page-appearance'),
                  onPressed: () => AppearanceSheet.show(context),
                  tooltip: l10n.pageAppearance,
                  icon: const Icon(Icons.format_size),
                ),
              IconButton(
                key: const ValueKey('focus-mode'),
                onPressed: toggleFocus,
                isSelected: focused,
                tooltip: NoteEditorScreen.focusTooltip(l10n, focused: focused),
                icon: const Icon(Icons.center_focus_weak),
                selectedIcon: const Icon(Icons.center_focus_strong),
              ),
              if (_saved case final saved?
                  when !focused &&
                      publishing != null &&
                      PublicationPolicy.canPublish(_schema))
                IconButton(
                  key: const ValueKey('publish-note'),
                  // What is published is the note as saved.
                  onPressed: _dirty
                      ? null
                      : () => PublishSheet.show(
                          context,
                          access: publishing,
                          entry: saved,
                          schema: _schema,
                        ),
                  tooltip: l10n.publishAction,
                  icon: const Icon(Icons.public),
                ),
              if (_saved != null && !focused)
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
                child: MediaQuery(
                  // The page's text size on top of the system's.
                  data: MediaQuery.of(context).copyWith(
                    textScaler: PageTextScaler(
                      MediaQuery.textScalerOf(context),
                      page.textFactor,
                    ),
                  ),
                  child: _inFont(
                    theme,
                    font,
                    Align(
                      alignment: Alignment.topCenter,
                      child: ConstrainedBox(
                        key: const ValueKey('note-page'),
                        constraints: BoxConstraints(maxWidth: width.maxWidth),
                        child: ListView(
                          padding: EdgeInsets.fromLTRB(
                            width.margin,
                            Spacing.s,
                            width.margin,
                            Spacing.xxl,
                          ),
                          children: [
                            if (_isJournal)
                              ValueListenableBuilder(
                                valueListenable: _day,
                                builder: (context, day, _) => day == null
                                    ? const SizedBox.shrink()
                                    : Text(
                                        JournalDays.long(context, day),
                                        key: const ValueKey('journal-day'),
                                        style: theme.textTheme.labelLarge
                                            ?.copyWith(
                                              color: ModusPalette.of(context)
                                                  .tint(_schema.tint),
                                            ),
                                      ),
                              ),
                            DynamicFormRenderer(
                              // A new type is a new page, filled with what was
                              // carried over.
                              key: ValueKey((_schema.id, _generation)),
                              schema: _schema,
                              values: _draft.values,
                              violations: _violations,
                              autofocus: widget.entry == null,
                              focused: focused,
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
                                imageSize: (blob) =>
                                    (_pictures[blob] ??
                                            widget.store.imageOf(blob))
                                        ?.metadata
                                        .info,
                              ),
                            ),
                            if (_countedField != null)
                              Align(
                                alignment: AlignmentDirectional.centerEnd,
                                child: ValueListenableBuilder(
                                  valueListenable: _words,
                                  builder: (context, words, _) => Text(
                                    l10n.wordCount(words),
                                    key: ValueKey(
                                      _isChapter
                                          ? 'chapter-words'
                                          : 'journal-words',
                                    ),
                                    style: theme.textTheme.labelSmall,
                                  ),
                                ),
                              ),
                            if (_schema.id.name == BookOutline.book && !focused)
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
                                      NumberValue(:final number) =>
                                        number.toInt(),
                                      _ => null,
                                    },
                                    schemas: widget.schemas,
                                    offered: _offered,
                                    onOpen: _openLinked,
                                    onAdd: (schema) =>
                                        _openOver(schema, category: category),
                                  );
                                },
                              ),
                            if (_schema.id.name == PageIndex.document &&
                                !focused)
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
                                    onAdd: _offered.contains(_schema)
                                        ? () => _openOver(
                                            _schema,
                                            category: category,
                                          )
                                        : null,
                                  );
                                },
                              ),
                            if (_isJournal && !focused)
                              ListenableBuilder(
                                listenable: Listenable.merge([
                                  widget.store,
                                  _day,
                                ]),
                                builder: (context, _) => switch (_day.value) {
                                  final day? => OnThisDaySection(
                                    day: day,
                                    pages: Journal.onThisDay(
                                      widget.store.entries.where(
                                        (entry) => entry.id != _id,
                                      ),
                                      day,
                                    ),
                                    schemaOf: _schemaOf,
                                    onOpen: _openLinked,
                                  ),
                                  null => const SizedBox.shrink(),
                                },
                              ),
                            if (!focused)
                              ListenableBuilder(
                                listenable: widget.store,
                                builder: (context, _) => NoteLinksSection(
                                  links: NoteLinks.targets(
                                    _draft.values.values,
                                  ),
                                  backlinks: [
                                    for (final entry in widget.store.entries)
                                      if (entry.id != _id &&
                                          NoteLinks.of(entry).contains(_id))
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
                ),
              ),
              ValueListenableBuilder(
                valueListenable: _markdown,
                builder: (context, controller, _) =>
                    controller == null || focused
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
                              onInsertImage: widget.store.images == null
                                  ? null
                                  : _insertImage,
                            ),
                          ),
                        ),
                      ),
              ),
            ],
          ),
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

  Widget _label(BuildContext context, SchemaDefinition schema) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(
        NoteAppearance.icon(schema.icon),
        size: IconSizes.inline,
        color: ModusPalette.of(context).tint(schema.tint),
      ),
      const SizedBox(width: Spacing.s),
      Flexible(
        child: Text(text.label(schema.label), overflow: TextOverflow.ellipsis),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    if (schemas.isEmpty) return _label(context, schema);
    // A menu button with a child is not announced as a button by itself,
    // and in the app bar's title it would merge into the route's heading.
    return Semantics(
      container: true,
      button: true,
      child: PopupMenuButton<SchemaDefinition>(
        key: const ValueKey('note-type'),
        tooltip: AppLocalizations.of(context).noteType,
        onSelected: onSwitch,
        itemBuilder: (context) => [
          for (final option in schemas)
            PopupMenuItem(value: option, child: _label(context, option)),
        ],
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(child: _label(context, schema)),
            const Icon(Icons.arrow_drop_down),
          ],
        ),
      ),
    );
  }
}
