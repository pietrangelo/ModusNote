import 'dart:convert';

import 'package:blob_storage_media/blob_storage_media.dart';
import 'package:collaboration_access_control/collaboration_access_control.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:offline_sync/offline_sync.dart';
import 'package:publishing/publishing.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

import '../attachments/note_images.dart';
import '../backup/backup_sheet.dart';
import '../backup/file_exchange.dart';
import '../backup/markdown_export.dart';
import '../audio/note_playback.dart';
import '../audio/note_recorder.dart';
import '../appearance/appearance_scope.dart';
import '../appearance/page_appearance.dart';
import '../l10n/generated/app_localizations.dart';
import '../notes/note_library.dart';
import '../notes/note_types.dart';
import '../notes/schema_text.dart';
import '../notes/journal/journal_settings_sheet.dart';
import '../notices/notice_center.dart';
import '../notices/notices_sheet.dart';
import '../notices/security_banner.dart';
import '../publishing/publication_media.dart';
import '../publishing/publish_sheet.dart';
import '../publishing/reencode_picture.dart';
import '../publishing/vault_publishing.dart';
import '../reminders/journal_reminder.dart';
import '../reminders/password_reminders.dart';
import '../sync/blob_sync.dart';
import '../sync/cloud_sheet.dart';
import '../sync/invite_sheet.dart';
import '../sync/link_device_sheet.dart';
import '../sync/sync_controller.dart';
import '../theme/golden_ratio.dart';
import 'auto_lock.dart';
import 'confirm_holder.dart';
import 'join_vault.dart';
import 'passphrase_field.dart';
import 'passphrase_warning.dart';
import 'second_factor.dart';
import 'unreadable_notice.dart';
import 'vault_note_store.dart';
import 'vault_shelf_gate.dart';
import '../theme/modus_palette.dart';
import '../notes/recipes/recipe_text.dart';

/// Moves a UTF-8 passphrase into native memory and wipes the buffer.
typedef PasswordFactory = PasswordSecret Function(Uint8List utf8Bytes);

/// The app's front door: creates the vault on first launch (or joins a
/// vault with a code from an owner's device), asks for the
/// passphrase (or the passkey, where one is set up) afterwards, and shows
/// the notes only while it is unlocked.
class VaultGate extends StatefulWidget {
  const VaultGate({
    required this.keeper,
    required this.passwordFrom,
    required this.catalog,
    this.recorderFor,
    this.playbackFor,
    this.imagesFor,
    this.sharedBlobsFor,
    this.live,
    this.serviceNotices,
    this.autoLockFor,
    this.files,
    this.remindersFor,
    this.switcher,
    this.secondFactor = SecondFactor.passkey,
    this.sites,
    super.key,
  });

  final VaultKeeper keeper;
  final PasswordFactory passwordFrom;

  /// The note types, current and old, the vault can read.
  final SchemaCatalog catalog;

  /// Builds the recorder for an unlocked vault; without it notes cannot
  /// hold recordings.
  final NoteRecorder Function(SyncEngine engine)? recorderFor;

  /// Builds the player's opener for an unlocked vault; without it
  /// recordings show their length but cannot be played.
  ///
  /// [ensureLocal] downloads a recording from the shared storage; null
  /// without one.
  final NotePlayback Function(
    SyncEngine engine,
    Future<void> Function(SealedBlob blob)? ensureLocal,
  )?
  playbackFor;

  /// Builds the pictures of an unlocked vault; without it notes cannot
  /// hold pictures. [ensureLocal] is as for [playbackFor].
  final NoteImages Function(
    SyncEngine engine,
    Future<void> Function(SealedBlob blob)? ensureLocal,
  )?
  imagesFor;

  /// Connects the open vault's recordings and pictures to the workspace's
  /// shared storage; null without a server, which keeps them on the device.
  final SharedBlobs Function(UnlockedVault vault)? sharedBlobsFor;

  /// Tells an open vault that syncs when another device changed it; null
  /// without a server, or where it has none.
  final LiveChannel? live;

  /// The operator's signed notices; null without a server.
  final ServiceNoticeBoard? serviceNotices;

  /// Builds the auto-lock of an open vault; tests shorten its times.
  final AutoLock Function(VoidCallback onLock)? autoLockFor;

  /// Saves and picks files for the backup and the export; null where the
  /// platform has no way yet, which hides them.
  final FileExchange? files;

  /// Shows the password expiry reminders, given the person's language;
  /// null where the platform has no notifications the app can schedule
  /// (the web), where the credential cards say it instead.
  final ReminderScheduler Function(AppLocalizations l10n)? remindersFor;

  /// The vault's name on the lock screen, to switch to another vault of
  /// the device; see [VaultShelfGate].
  final ShelfSwitcher? switcher;

  /// What the keeper's passkey port is on this platform, for its words.
  final SecondFactor secondFactor;

  /// serv.pub's signed API, where notes are published; null in a build
  /// without a server, which then offers no publishing.
  final SiteGateway? sites;

  @override
  State<VaultGate> createState() => _VaultGateState();
}

sealed class _Stage {
  const _Stage();
}

final class _Checking extends _Stage {
  const _Checking();
}

final class _Locked extends _Stage {
  const _Locked({required this.exists, this.passkey = false});

  final bool exists;

  /// A passkey is set up and the platform can use it.
  final bool passkey;
}

/// First launch, joining another device's vault instead of creating one.
final class _Joining extends _Stage {
  const _Joining();
}

final class _Open extends _Stage {
  const _Open(
    this.vault,
    this.store,
    this.autoLock,
    this.sync,
    this.reminders,
    this.journal,
    this.types,
    this.notices,
    this.publishing,
  );

  final UnlockedVault vault;
  final VaultNoteStore store;
  final AutoLock autoLock;
  final SyncController? sync;

  /// The vault's notices, beside its sync; null without one.
  final NoticeCenter? notices;
  final PasswordReminders? reminders;

  /// The journal's daily reminder; null where there are no reminders.
  final JournalReminderSetting? journal;

  /// The note types this device offers.
  final NoteTypeSetting types;

  /// Publishing on serv.pub; null without a server.
  final PublishingAccess? publishing;
}

/// Present once the sync of the vault was turned on (see
/// SyncController.enabled).
const _enabledSetting = 'sync.enabled';

/// The Supabase session of the vaults that synced there: a vault that has
/// one had its sync on.
const _sessionSetting = 'sync.session';

/// Present once the vault's data was deleted from the server (see
/// SyncController.retired).
const _retiredSetting = 'sync.retired';

/// How this device shows the page of a note (width, text size): sealed
/// like everything else in the vault, though it says nothing of the notes.
const _pageSetting = 'ui.page';

/// The note types this device turned off: like [_pageSetting], a choice
/// of the device, sealed though it says nothing of the notes.
const _typesSetting = 'ui.types';

/// Whether, and when, this device reminds its person to write in the
/// journal.
const _journalSetting = 'journal.reminder';

/// How many records of the member log the person has seen among the
/// notices (a [NoticeMark]).
const _noticeMarkSetting = 'notices.ledger';

/// The operator's notices the person closed in this vault.
const _dismissedSetting = 'notices.service';

enum _Problem {
  tooShort,
  mismatch,
  wrong,
  damaged,
  passkeyCancelled,
  passkeyRejected,
  passkeyUnsupported,
  unexpected,
}

class _VaultGateState extends State<VaultGate> with WidgetsBindingObserver {
  _Stage _stage = const _Checking();
  _Problem? _problem;

  // Ticked on the warning that a forgotten passphrase cannot be recovered;
  // creating a vault waits for it.
  bool _acknowledged = false;
  var _busy = false;
  final _passphrase = TextEditingController();
  final _confirmation = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _showLocked();
  }

  Future<void> _showLocked() async {
    final keeper = widget.keeper;
    final exists = await keeper.exists;
    final passkey = exists && await keeper.hasPasskey;
    if (mounted) {
      setState(() => _stage = _Locked(exists: exists, passkey: passkey));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopWatching();
    _appearance?.detach(reset: false);
    if (_stage case _Open(
      :final vault,
      :final autoLock,
      :final sync,
      :final reminders,
      :final notices,
    )) {
      reminders?.dispose();
      notices?.dispose();
      sync?.dispose();
      autoLock.dispose();
      vault.lock();
    }
    _passphrase.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  Future<void> _submit({required bool creating}) async {
    final mismatch = creating && _passphrase.text != _confirmation.text;
    // The String in a TextField cannot be wiped, only dropped quickly: it
    // is turned into a native secret and the fields are cleared at once.
    final bytes = Uint8List.fromList(utf8.encode(_passphrase.text));
    _passphrase.clear();
    _confirmation.clear();
    if (mismatch) {
      bytes.fillRange(0, bytes.length, 0);
      setState(() => _problem = _Problem.mismatch);
      return;
    }
    final PasswordSecret password;
    try {
      password = widget.passwordFrom(bytes);
    } on WeakPassphraseException {
      setState(() => _problem = _Problem.tooShort);
      return;
    }
    await _open(
      () => creating
          ? widget.keeper.create(password)
          : widget.keeper.unlock(password),
    );
  }

  /// The user confirms on the authenticator; no passphrase is typed.
  Future<void> _unlockWithPasskey() => _open(widget.keeper.unlockWithPasskey);

  Future<void> _open(Future<UnlockedVault> Function() opening) async {
    final l10n = AppLocalizations.of(context);
    setState(() {
      _busy = true;
      _problem = null;
    });
    // Let the progress indicator paint before Argon2id holds the isolate.
    await Future<void>.delayed(Duration.zero);
    UnlockedVault? opened;
    try {
      final vault = opened = await opening();
      final shared = widget.sharedBlobsFor?.call(vault);
      BlobSync? blobs;
      final ensureLocal = shared == null
          ? null
          : (SealedBlob blob) => blobs!.ensureLocal(blob);
      final store = await VaultNoteStore.open(
        vault.engine,
        catalog: widget.catalog,
        recorder: widget.recorderFor?.call(vault.engine),
        playback: widget.playbackFor?.call(vault.engine, ensureLocal),
        images: widget.imagesFor?.call(vault.engine, ensureLocal),
        copyTitle: (title) => title.isEmpty
            ? l10n.conflictCopyUntitled
            : l10n.conflictCopyTitle(title),
      );
      if (shared != null) {
        blobs = _blobSync(vault, store, shared);
        store.onRelease = blobs.release;
      }
      final sync = await _connect(vault, store, blobs);
      final notices = sync == null ? null : await _notices(vault, sync);
      final page = await _storedPage(vault);
      final types = _typesOf(vault, await _storedTypes(vault));
      final daily = widget.remindersFor == null
          ? const JournalReminder()
          : await _storedJournal(vault);
      if (!mounted) {
        notices?.dispose();
        sync?.dispose();
        vault.lock();
        return;
      }
      final autoLock =
          widget.autoLockFor?.call(_autoLocked) ??
          AutoLock(onLock: _autoLocked);
      _watchActivity(autoLock);
      final scheduler = widget.remindersFor?.call(l10n);
      final journal = scheduler == null ? null : _journalOf(vault, daily);
      final reminders = scheduler == null
          ? null
          : PasswordReminders(
              store: store,
              scheduler: scheduler,
              texts: ReminderTexts(l10n),
              journal: journal == null
                  ? null
                  : OfferedJournalReminder(
                      journal,
                      types: types,
                      journalOn: () => types.value
                          .offered(widget.catalog.current)
                          .any((schema) => schema.id.name == Journal.schema),
                    ),
            );
      _attachAppearance(vault, page);
      final sites = widget.sites;
      final pictureBlobs = store.images?.blobs;
      final publishing = sites == null
          ? null
          : PublishingAccess(
              publisher: Publisher(
                gateway: sites,
                keys: VaultSiteKeys(widget.keeper, vault),
                books: VaultSiteBooks(widget.keeper, vault),
                media: VaultPublicationMedia(
                  imageOf: store.imageOf,
                  recordingOf: store.recordingOf,
                  openImage: (image) =>
                      store.images?.open(image) ??
                      Future.error(BlobNotFoundException(image.id)),
                  openRecording: (take) async* {
                    if (pictureBlobs == null) return;
                    await ensureLocal?.call(take.blob);
                    yield* pictureBlobs.read(
                      take.blob,
                      contentKey: vault.engine.contentKeyFor(take.epoch),
                    );
                  },
                  reencode: reencodePicture,
                ),
                isConfirmed: () => widget.keeper.isConfirmed(vault),
              ),
              confirm: _confirmed,
            );
      setState(
        () => _stage = _Open(
          vault,
          store,
          autoLock,
          sync,
          reminders,
          journal,
          types,
          notices,
          publishing,
        ),
      );
      sync?.start();
      reminders?.start();
    } on WrongPassphraseException {
      _fail(_Problem.wrong);
    } on TamperedWorkspaceDataException {
      _fail(_Problem.damaged);
    } on MalformedSyncDataException {
      _fail(_Problem.damaged);
    } on PasskeyCancelledException {
      _fail(_Problem.passkeyCancelled);
    } on PasskeyUnsupportedException {
      _fail(_Problem.passkeyUnsupported);
    } on PasskeyRejectedException {
      _fail(_Problem.passkeyRejected);
    } on NoPasskeyException {
      _fail(_Problem.passkeyRejected);
    } on Object {
      // A damaged database or an app older than the vault: never a silent
      // lock screen, and never keys left behind it.
      opened?.lock();
      _fail(_Problem.unexpected);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _startJoining() => setState(() {
    _problem = null;
    _stage = const _Joining();
  });

  void _stopJoining() => setState(() => _stage = const _Locked(exists: false));

  /// Both secrets move into native memory before anything else happens.
  Future<LinkRequest> _accept(InviteCode code, Uint8List secretBytes) async {
    final password = widget.passwordFrom(secretBytes);
    final PasswordSecret secret;
    try {
      secret = widget.passwordFrom(code.toBytes());
    } catch (_) {
      password.dispose();
      rethrow;
    }
    return widget.keeper.acceptInvite(
      code: secret,
      lookup: code.lookup,
      passphrase: password,
    );
  }

  /// A vault joined with a code syncs from the start: its notes are on the
  /// server already.
  Future<void> _joined(UnlockedVault vault) => _open(() async {
    await widget.keeper.saveSetting(vault, _enabledSetting, _present);
    return vault;
  });

  /// Shows a code for another device of the same person and admits it, as
  /// an owner.
  Future<void> _linkDevice() async {
    if (_stage case _Open(:final vault, :final sync)) {
      if (!await _confirmed()) return;
      if (!mounted) return;
      await LinkDeviceSheet.show(
        context,
        offer: (code) => widget.keeper.offerInvite(
          vault,
          widget.passwordFrom(code.toBytes()),
          lookup: code.lookup,
          role: Role.owner,
        ),
        onLinked: sync?.syncNow,
      );
    }
  }

  /// Shows a code for another person, with the role they get, and admits
  /// their device.
  Future<void> _invite() async {
    if (_stage case _Open(:final vault, :final sync)) {
      if (!await _confirmed()) return;
      if (!mounted) return;
      await InviteSheet.show(
        context,
        offer: (code, role) => widget.keeper.offerInvite(
          vault,
          widget.passwordFrom(code.toBytes()),
          lookup: code.lookup,
          role: role,
        ),
        onInvited: sync?.syncNow,
      );
    }
  }

  /// The sync of the open vault, where the build has a server: on if it
  /// was turned on, or the vault synced through a Supabase account.
  Future<SyncController?> _connect(
    UnlockedVault vault,
    VaultNoteStore store,
    BlobSync? blobs,
  ) async {
    final keeper = widget.keeper;
    if (!keeper.offersInvites) return null;
    final sync = SyncController(
      engine: vault.engine,
      onPulled: store.reload,
      onLost: (lost) async {
        final kept = await store.keepLost(lost);
        if (kept > 0 && mounted) {
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            SnackBar(
              content: Text(
                AppLocalizations.of(context).conflictCopiesKept(kept),
              ),
            ),
          );
        }
      },
      afterSync: blobs == null
          ? null
          : (report) => blobs.afterSync(moved: report.moved),
      enabled: await _isEnabled(vault),
      turnOn: () => keeper.saveSetting(vault, _enabledSetting, _present),
      retired: await _isRetired(vault),
      retire: () => keeper.saveSetting(vault, _retiredSetting, _present),
      live: switch (widget.live) {
        final live? => () => live.open(vault.workspace, vault.signer),
        null => null,
      },
    );
    store.onWrite = sync.changed;
    return sync;
  }

  /// The notices of the open vault. The mark of what the person saw is
  /// written here, before the first sync, only when it is missing or
  /// damaged: a vault opened for the first time since notices exist, or
  /// just joined, shows no flood of old records, and what the first sync
  /// brings is already news.
  Future<NoticeCenter> _notices(
    UnlockedVault vault,
    SyncController sync,
  ) async {
    final keeper = widget.keeper;
    NoticeMark? mark;
    try {
      if (await keeper.loadSetting(vault, _noticeMarkSetting)
          case final bytes?) {
        mark = NoticeMark.parse(bytes);
      }
    } on MalformedSyncDataException {
      mark = null;
    }
    if (mark == null) {
      mark = NoticeMark(vault.engine.ledger.records.length);
      await keeper.saveSetting(vault, _noticeMarkSetting, mark.toBytes());
    }
    Set<int> dismissed;
    try {
      dismissed = switch (await keeper.loadSetting(vault, _dismissedSetting)) {
        final bytes? => DismissedNotices.parse(bytes),
        null => const {},
      };
    } on MalformedSyncDataException {
      // Closed notices may show again: they say nothing that harms.
      dismissed = const {};
    }
    return NoticeCenter(
      engine: vault.engine,
      sync: sync,
      mark: mark,
      saveMark: (mark) =>
          keeper.saveSetting(vault, _noticeMarkSetting, mark.toBytes()),
      board: widget.serviceNotices,
      dismissed: dismissed,
      saveDismissed: (serials) => keeper.saveSetting(
        vault,
        _dismissedSetting,
        DismissedNotices.encode(serials),
      ),
    );
  }

  /// Opens the notices of the open vault.
  void _showNotices() {
    if (_stage case _Open(:final sync?, :final notices?)) {
      NoticesSheet.show(context, notices, sync, onInvite: _invite);
    }
  }

  /// Which blobs the server holds, and which ones to delete there, are
  /// sealed settings; a damaged one only means checking
  /// them again, or leaving blobs for the next sweep.
  BlobSync _blobSync(
    UnlockedVault vault,
    VaultNoteStore store,
    SharedBlobs shared,
  ) {
    final keeper = widget.keeper;
    return BlobSync(
      replication: shared.replication,
      pruning: shared.pruning,
      blobs: () => store.blobs,
      // A reader may not delete blobs on the server: it only downloads.
      canPrune: () =>
          store.unreadable == 0 &&
          (vault.engine.ledger.workspace
                  .member(vault.engine.me)
                  ?.role
                  .writesContent ??
              false),
      unsentWrites: vault.engine.hasUnsentWrites,
      load: (name) async {
        try {
          return await keeper.loadSetting(vault, name);
        } on MalformedSyncDataException {
          return null;
        }
      },
      save: (name, value) => keeper.saveSetting(vault, name, value),
    );
  }

  /// A damaged mark counts as on: the person turned the sync on once.
  /// The session a vault kept when it synced through Supabase means the
  /// same, and is dropped: it opens nothing on our server.
  Future<bool> _isEnabled(UnlockedVault vault) async {
    final keeper = widget.keeper;
    try {
      if (await keeper.loadSetting(vault, _enabledSetting) != null) return true;
    } on MalformedSyncDataException {
      return true;
    }
    bool synced;
    try {
      synced = await keeper.loadSetting(vault, _sessionSetting) != null;
    } on MalformedSyncDataException {
      synced = true;
    }
    if (synced) {
      await keeper.saveSetting(vault, _enabledSetting, _present);
      await keeper.saveSetting(vault, _sessionSetting, null);
    }
    return synced;
  }

  Future<PageAppearance> _storedPage(UnlockedVault vault) async {
    try {
      return PageAppearance.fromBytes(
        await widget.keeper.loadSetting(vault, _pageSetting),
      );
    } on MalformedSyncDataException {
      return const PageAppearance();
    }
  }

  Future<NoteTypeChoice> _storedTypes(UnlockedVault vault) async {
    try {
      return NoteTypeChoice.fromBytes(
        await widget.keeper.loadSetting(vault, _typesSetting),
      );
    } on MalformedSyncDataException {
      return const NoteTypeChoice();
    }
  }

  NoteTypeSetting _typesOf(UnlockedVault vault, NoteTypeChoice choice) {
    final keeper = widget.keeper;
    return NoteTypeSetting(
      choice,
      persist: (bytes) async {
        try {
          await keeper.saveSetting(vault, _typesSetting, bytes);
        } on VaultLockedException {
          // Locked meanwhile: the change stays on the screen only.
        }
      },
    );
  }

  Future<JournalReminder> _storedJournal(UnlockedVault vault) async {
    try {
      return JournalReminder.fromBytes(
        await widget.keeper.loadSetting(vault, _journalSetting),
      );
    } on MalformedSyncDataException {
      return const JournalReminder();
    }
  }

  JournalReminderSetting _journalOf(
    UnlockedVault vault,
    JournalReminder reminder,
  ) {
    final keeper = widget.keeper;
    return JournalReminderSetting(
      reminder,
      persist: (bytes) async {
        try {
          await keeper.saveSetting(vault, _journalSetting, bytes);
        } on VaultLockedException {
          // Locked meanwhile: the change stays on the screen only.
        }
      },
    );
  }

  /// The app's appearance, while this vault fills it.
  AppearanceSettings? _appearance;

  void _attachAppearance(UnlockedVault vault, PageAppearance page) {
    final keeper = widget.keeper;
    _appearance = AppearanceScope.maybeOf(context)
      ?..attach(
        page,
        persist: (bytes) async {
          try {
            await keeper.saveSetting(vault, _pageSetting, bytes);
          } on VaultLockedException {
            // Locked meanwhile: the change stays on the screen only.
          }
        },
      );
  }

  void _detachAppearance() {
    _appearance?.detach();
    _appearance = null;
  }

  /// A damaged mark still counts: syncing a retired vault again would push
  /// to a workspace the server no longer has.
  Future<bool> _isRetired(UnlockedVault vault) async {
    try {
      return await widget.keeper.loadSetting(vault, _retiredSetting) != null;
    } on MalformedSyncDataException {
      return true;
    }
  }

  void _fail(_Problem problem) {
    if (mounted) setState(() => _problem = problem);
  }

  void _lock() {
    if (_stage case _Open(
      :final vault,
      :final store,
      :final autoLock,
      :final sync,
      :final reminders,
      :final notices,
    )) {
      _stopWatching();
      _detachAppearance();
      // The reminders already set stay with the system.
      reminders?.dispose();
      notices?.dispose();
      // An undo offered on the way out would write with released keys.
      ScaffoldMessenger.maybeOf(context)?.clearSnackBars();
      // The sync stops before the keys it works with are released.
      sync?.dispose();
      autoLock.dispose();
      vault.lock();
      store.dispose();
      setState(() => _stage = const _Locked(exists: true));
      _showLocked();
    }
  }

  /// The encrypted backup, its restore and the Markdown export of the
  /// open vault.
  Future<void> _backup() async {
    final files = widget.files;
    if (files == null) return;
    if (_stage case _Open(:final vault, :final store)) {
      if (!await _confirmed()) return;
      if (!mounted) return;
      final keeper = widget.keeper;
      final l10n = AppLocalizations.of(context);
      final dates = MaterialLocalizations.of(context);
      await showBackupSheet(
        context,
        BackupTools(
          files: files,
          secretFrom: widget.passwordFrom,
          export: (phrase) => keeper.exportBackup(vault, phrase),
          open: keeper.openBackup,
          restore: (backup) async {
            final restored = await keeper.restoreBackup(vault, backup);
            await store.reload();
            return restored;
          },
          markdown: (at) => MarkdownExport(
            schemas: widget.catalog.current,
            labels: SchemaText(l10n),
            recipes: RecipeText(l10n),
            words: (
              untitled: l10n.untitled,
              recording: l10n.markdownRecording,
              picture: l10n.markdownPicture,
              date: dates.formatMediumDate,
            ),
            categories: store.categories,
            categoryOf: store.categoryOf,
          ).archive(store.entries, at: at),
        ),
      );
    }
  }

  /// Sets up or turns off the passkey of the open vault.
  Future<void> _passkeySettings() async {
    final keeper = widget.keeper;
    final factor = widget.secondFactor;
    final active = await keeper.hasPasskey;
    if (!mounted) return;
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.fingerprint),
        title: Text(factor.settings(l10n)),
        content: Text(
          active ? factor.activeBody(l10n) : factor.setupBody(l10n),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.dialogClose),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(
              active ? l10n.passkeyRemoveAction : factor.setupAction(l10n),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    String outcome;
    try {
      if (active) {
        await keeper.removePasskey();
        outcome = factor.removed(l10n);
      } else {
        if (!await _confirmed()) return;
        final (vault, autoLock) = switch (_stage) {
          _Open(:final vault, :final autoLock) => (vault, autoLock),
          _ => throw const VaultLockedException(),
        };
        // The vault stays open while the person is at the authenticator:
        // locking mid-ceremony would forget the passkey just made.
        final release = autoLock.hold();
        try {
          await keeper.enrollPasskey(vault);
        } finally {
          release();
        }
        outcome = factor.ready(l10n);
      }
    } on PasskeyCancelledException {
      outcome = factor.cancelled(l10n);
    } on PasskeyUnsupportedException {
      outcome = factor.unsupported(l10n);
    } on ConfirmationRequiredException {
      // The confirmation ran out while the person read the dialog.
      return;
    } on VaultLockedException {
      // Locked while the user was at the authenticator: nothing was saved.
      return;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(outcome)));
  }

  /// Asks for the passphrase again (or the passkey), unless an earlier
  /// confirmation still lasts.
  Future<bool> _confirmed() async {
    if (_stage case _Open(:final vault, :final autoLock)) {
      return confirmHolder(
        context,
        keeper: widget.keeper,
        vault: vault,
        passwordFrom: widget.passwordFrom,
        factor: widget.secondFactor,
        hold: autoLock.hold,
      );
    }
    return false;
  }

  /// Closes every screen opened over the notes first, so no decrypted
  /// note stays on screen behind the passphrase prompt.
  void _autoLocked() {
    if (!mounted) return;
    Navigator.of(context).popUntil((route) => route.isFirst);
    _lock();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_stage case _Open(:final autoLock, :final sync)) {
      switch (state) {
        case AppLifecycleState.hidden || AppLifecycleState.paused:
          autoLock.hidden();
          // A closed app hears nothing anyway, and mobile systems freeze
          // its sockets.
          sync?.pause();
        case AppLifecycleState.resumed:
          autoLock.shown();
          sync?.resume();
          sync?.syncNow();
        case AppLifecycleState.inactive || AppLifecycleState.detached:
          break;
      }
    }
  }

  // Taps and keys anywhere count as activity, on every route, so they are
  // watched at the bindings rather than through one widget subtree.
  AutoLock? _watched;

  void _watchActivity(AutoLock autoLock) {
    _stopWatching();
    _watched = autoLock;
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  void _stopWatching() {
    if (_watched == null) return;
    _watched = null;
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointer);
    HardwareKeyboard.instance.removeHandler(_onKey);
  }

  void _onPointer(PointerEvent event) {
    // Reading a long note with a wheel or trackpad is activity too.
    if (event is PointerDownEvent ||
        event is PointerScrollEvent ||
        event is PointerPanZoomUpdateEvent) {
      _watched?.touch();
    }
  }

  bool _onKey(KeyEvent event) {
    _watched?.touch();
    return false;
  }

  @override
  Widget build(BuildContext context) => switch (_stage) {
    _Checking() => const Scaffold(
      body: Center(child: CircularProgressIndicator()),
    ),
    _Open(
      :final store,
      :final autoLock,
      :final sync,
      :final journal,
      :final types,
      :final notices,
      :final publishing,
    ) =>
      AutoLockScope(
        autoLock: autoLock,
        child: _withPublishing(
          publishing,
          NoteLibraryScreen(
            schemas: widget.catalog.current,
            store: store,
            notice: notices == null
                ? UnreadableNotice(store: store)
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SecurityBanner(notices: notices, onOpen: _showNotices),
                      UnreadableNotice(store: store),
                    ],
                  ),
            cloud: sync == null
                ? null
                : CloudButton(
                    sync: sync,
                    notices: notices,
                    onLinkDevice: _linkDevice,
                    onInvite: _invite,
                  ),
            onNotices: notices == null ? null : _showNotices,
            onLock: _lock,
            onBackup: widget.files == null ? null : _backup,
            onPasskey: widget.keeper.offersPasskeys ? _passkeySettings : null,
            passkeyLabel: widget.secondFactor.settings(
              AppLocalizations.of(context),
            ),
            journalSettings: journal == null
                ? null
                : () => JournalSettingsSheet.show(context, journal),
            noteTypes: types,
          ),
        ),
      ),
    _Joining() => JoinVaultScreen(
      accept: _accept,
      onJoined: _joined,
      onBack: _stopJoining,
    ),
    _Locked(:final exists, :final passkey) => _form(
      context,
      creating: !exists,
      passkey: passkey,
    ),
  };

  static Widget _withPublishing(PublishingAccess? access, Widget child) =>
      access == null ? child : PublishingScope(access: access, child: child);

  Widget _form(
    BuildContext context, {
    required bool creating,
    required bool passkey,
  }) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final problem = switch (_problem) {
      null => null,
      _Problem.tooShort => l10n.passphraseTooShort(
        PassphrasePolicy.minimumBytes,
      ),
      _Problem.mismatch => l10n.passphraseMismatch,
      _Problem.wrong => l10n.passphraseWrong,
      _Problem.damaged => l10n.vaultDamaged,
      _Problem.passkeyCancelled => widget.secondFactor.cancelled(l10n),
      _Problem.passkeyRejected => widget.secondFactor.rejected(l10n),
      _Problem.passkeyUnsupported => widget.secondFactor.unsupported(l10n),
      _Problem.unexpected => l10n.vaultOpenFailed,
    };
    final submit = _busy || (creating && !_acknowledged)
        ? null
        : () => _submit(creating: creating);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(Spacing.l),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: Extents.xl),
              child: AutofillGroup(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (widget.switcher case final switcher?) ...[
                      IgnorePointer(
                        ignoring: _busy,
                        child: switcher(created: !creating),
                      ),
                      const SizedBox(height: Spacing.l),
                    ],
                    Icon(
                      Icons.lock_outline,
                      size: IconSizes.prominent,
                      color: ModusPalette.of(context).primary,
                    ),
                    const SizedBox(height: Spacing.l),
                    Text(
                      creating ? l10n.vaultCreateTitle : l10n.vaultUnlockTitle,
                      style: theme.textTheme.headlineMedium,
                      textAlign: TextAlign.center,
                    ),
                    if (creating) ...[
                      const SizedBox(height: Spacing.m),
                      Text(
                        l10n.vaultCreateBody,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: ModusPalette.of(context).muted,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                    const SizedBox(height: Spacing.xl),
                    PassphraseField(
                      key: const ValueKey('passphrase'),
                      controller: _passphrase,
                      label: l10n.passphraseLabel,
                      enabled: !_busy,
                      onSubmitted: creating ? null : submit,
                    ),
                    if (creating) ...[
                      const SizedBox(height: Spacing.m),
                      PassphraseField(
                        key: const ValueKey('passphrase-confirm'),
                        controller: _confirmation,
                        label: l10n.passphraseConfirmLabel,
                        enabled: !_busy,
                        onSubmitted: submit,
                      ),
                      const SizedBox(height: Spacing.l),
                      PassphraseWarning(
                        acknowledged: _acknowledged,
                        enabled: !_busy,
                        onChanged: (value) =>
                            setState(() => _acknowledged = value),
                      ),
                    ],
                    if (problem != null) ...[
                      const SizedBox(height: Spacing.m),
                      Semantics(
                        liveRegion: true,
                        child: Text(
                          problem,
                          key: const ValueKey('vault-problem'),
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.error,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                      if (_problem == _Problem.wrong) ...[
                        const SizedBox(height: Spacing.s),
                        Text(
                          l10n.passphraseForgotten,
                          key: const ValueKey('passphrase-forgotten'),
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: ModusPalette.of(context).muted,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ],
                    const SizedBox(height: Spacing.l),
                    FilledButton(
                      onPressed: submit,
                      child: Text(
                        creating
                            ? l10n.vaultCreateAction
                            : l10n.vaultUnlockAction,
                      ),
                    ),
                    if (creating && widget.keeper.offersInvites) ...[
                      const SizedBox(height: Spacing.m),
                      OutlinedButton.icon(
                        key: const ValueKey('join-vault'),
                        onPressed: _busy ? null : _startJoining,
                        icon: const Icon(Icons.devices_outlined),
                        label: Text(l10n.joinVaultAction),
                      ),
                    ],
                    if (passkey && !creating) ...[
                      const SizedBox(height: Spacing.m),
                      OutlinedButton.icon(
                        onPressed: _busy ? null : _unlockWithPasskey,
                        icon: const Icon(Icons.fingerprint),
                        label: Text(widget.secondFactor.unlockAction(l10n)),
                      ),
                    ],
                    if (_busy) ...[
                      const SizedBox(height: Spacing.l),
                      const Center(child: CircularProgressIndicator()),
                      const SizedBox(height: Spacing.s),
                      Text(
                        l10n.vaultOpening,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: ModusPalette.of(context).muted,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The value of a setting that only marks something.
final _present = Uint8List.fromList(const [1]);
