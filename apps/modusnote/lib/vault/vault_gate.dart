import 'dart:convert';

import 'package:blob_storage_media/blob_storage_media.dart';
import 'package:collaboration_access_control/collaboration_access_control.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:offline_sync/offline_sync.dart';
import 'package:offline_sync_adapters/offline_sync_adapters.dart';
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
import '../notes/schema_text.dart';
import '../notes/journal/journal_settings_sheet.dart';
import '../reminders/journal_reminder.dart';
import '../reminders/password_reminders.dart';
import '../sync/blob_sync.dart';
import '../sync/cloud_sheet.dart';
import '../sync/invite_sheet.dart';
import '../sync/link_device_sheet.dart';
import '../sync/sync_controller.dart';
import '../theme/golden_ratio.dart';
import 'auto_lock.dart';
import 'join_vault.dart';
import 'passphrase_warning.dart';
import 'vault_note_store.dart';
import 'vault_shelf_gate.dart';
import '../theme/modus_palette.dart';

/// Moves a UTF-8 passphrase into native memory and wipes the buffer.
typedef PasswordFactory = PasswordSecret Function(Uint8List utf8Bytes);

/// The app's front door: creates the vault on first launch (or joins the
/// vault of another device of the same account), asks for the
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
    this.autoLockFor,
    this.account,
    this.syncFor,
    this.files,
    this.remindersFor,
    this.switcher,
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
  final SharedBlobs Function(SyncEngine engine)? sharedBlobsFor;

  /// Builds the auto-lock of an open vault; tests shorten its times.
  final AutoLock Function(VoidCallback onLock)? autoLockFor;

  /// The sync account; null in a build without a server, which offers no
  /// sign-in and keeps edits queued on the device.
  final SyncAccount? account;

  /// Builds the sync of an open vault; tests shorten its times.
  final SyncController Function(
    SyncEngine engine,
    SyncAccount account,
    Future<void> Function() onPulled,
  )?
  syncFor;

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
  );

  final UnlockedVault vault;
  final VaultNoteStore store;
  final AutoLock autoLock;
  final SyncController? sync;
  final PasswordReminders? reminders;

  /// The journal's daily reminder; null where there are no reminders.
  final JournalReminderSetting? journal;
}

/// The Supabase session, sealed in the vault under the local key: it opens
/// only the account's rows (ciphertext), but it is still a credential.
const _sessionSetting = 'sync.session';

/// Present once the vault's account was deleted (see SyncController.retired).
const _retiredSetting = 'sync.retired';

/// How this device shows the page of a note (width, text size): sealed
/// like everything else in the vault, though it says nothing of the notes.
const _pageSetting = 'ui.page';

/// Whether, and when, this device reminds its person to write in the
/// journal.
const _journalSetting = 'journal.reminder';

enum _Problem {
  tooShort,
  mismatch,
  wrong,
  damaged,
  passkeyCancelled,
  passkeyRejected,
  passkeyUnsupported,
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

  /// The session signed in while joining, before a vault exists to seal it
  /// in; it goes into the new vault the moment there is one.
  SupabaseSession? _joinSession;

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
    )) {
      reminders?.dispose();
      sync?.dispose();
      widget.account?.detach();
      autoLock.dispose();
      vault.lock();
    } else if (_stage is _Joining) {
      widget.account?.detach();
    }
    _joinSession = null;
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
    try {
      final vault = await opening();
      final shared = widget.account == null
          ? null
          : widget.sharedBlobsFor?.call(vault.engine);
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
      );
      if (shared != null) {
        blobs = _blobSync(vault, store, shared);
        store.onRelease = blobs.release;
      }
      final sync = await _connect(vault, store, blobs);
      final page = await _storedPage(vault);
      final daily = widget.remindersFor == null
          ? const JournalReminder()
          : await _storedJournal(vault);
      if (!mounted) {
        sync?.dispose();
        widget.account?.detach();
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
              journal: journal,
            );
      _attachAppearance(vault, page);
      setState(
        () => _stage = _Open(vault, store, autoLock, sync, reminders, journal),
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
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _startJoining() {
    widget.account!.attach(
      null,
      persist: (session) async => _joinSession = session,
    );
    setState(() {
      _problem = null;
      _stage = const _Joining();
    });
  }

  void _stopJoining() {
    widget.account?.detach();
    _joinSession = null;
    setState(() => _stage = const _Locked(exists: false));
  }

  /// Both secrets move into native memory before anything else happens.
  Future<LinkRequest> _join(LinkCode code, Uint8List passphrase) async {
    final password = widget.passwordFrom(passphrase);
    final PasswordSecret secret;
    try {
      secret = widget.passwordFrom(code.toBytes());
    } catch (_) {
      password.dispose();
      rethrow;
    }
    return widget.keeper.join(code: secret, passphrase: password);
  }

  /// As [_join], for an invitation from another person's vault: the
  /// signed-in account is the one the invitation lets in.
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
      account: AccountId.parse(widget.account!.userId!),
      passphrase: password,
    );
  }

  Future<void> _joined(UnlockedVault vault) {
    final session = _joinSession;
    _joinSession = null;
    return _open(() async {
      if (session != null) {
        await widget.keeper.saveSetting(
          vault,
          _sessionSetting,
          session.toBytes(),
        );
      }
      return vault;
    });
  }

  /// Shows a code for another device of this account and admits it.
  Future<void> _linkDevice() async {
    if (_stage case _Open(:final vault, :final sync)) {
      await LinkDeviceSheet.show(
        context,
        offer: (code) =>
            widget.keeper.offerLink(vault, widget.passwordFrom(code.toBytes())),
        onLinked: sync?.syncNow,
      );
    }
  }

  /// Shows a code for another person, with the role they get, and admits
  /// their device.
  Future<void> _invite() async {
    if (_stage case _Open(:final vault, :final sync)) {
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

  /// Restores the account's session from the vault and hands new ones back
  /// to it, sealed. Nothing of the session outlives the unlocked vault.
  Future<SyncController?> _connect(
    UnlockedVault vault,
    VaultNoteStore store,
    BlobSync? blobs,
  ) async {
    final account = widget.account;
    if (account == null) return null;
    final keeper = widget.keeper;
    account.attach(
      await _storedSession(vault),
      persist: (session) async {
        try {
          await keeper.saveSetting(vault, _sessionSetting, session?.toBytes());
        } on VaultLockedException {
          // Locked meanwhile: the session is dropped with the vault.
        }
      },
    );
    final sync =
        widget.syncFor?.call(vault.engine, account, store.reload) ??
        SyncController(
          engine: vault.engine,
          account: account,
          onPulled: store.reload,
          afterSync: blobs?.afterSync,
          retired: await _isRetired(vault),
          retire: () => keeper.saveSetting(
            vault,
            _retiredSetting,
            Uint8List.fromList(const [1]),
          ),
        );
    store.onWrite = sync.changed;
    return sync;
  }

  /// Which blobs the server holds, and which ones to delete there, are
  /// sealed settings, like the session; a damaged one only means checking
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
      canPrune: () => store.unreadable == 0,
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

  /// A session that is missing, damaged or sealed for another vault means
  /// signing in again, never a vault that will not open.
  Future<SupabaseSession?> _storedSession(UnlockedVault vault) async {
    try {
      final stored = await widget.keeper.loadSetting(vault, _sessionSetting);
      return stored == null ? null : SupabaseSession.fromBytes(stored);
    } on MalformedSyncDataException {
      return null;
    }
  }

  /// A damaged mark still counts: syncing a retired vault again would push
  /// to a workspace the server no longer has.
  Future<PageAppearance> _storedPage(UnlockedVault vault) async {
    try {
      return PageAppearance.fromBytes(
        await widget.keeper.loadSetting(vault, _pageSetting),
      );
    } on MalformedSyncDataException {
      return const PageAppearance();
    }
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
    )) {
      _stopWatching();
      _detachAppearance();
      // The reminders already set stay with the system.
      reminders?.dispose();
      // An undo offered on the way out would write with released keys.
      ScaffoldMessenger.maybeOf(context)?.clearSnackBars();
      // The sync stops before the keys it works with are released.
      sync?.dispose();
      widget.account?.detach();
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
    final active = await keeper.hasPasskey;
    if (!mounted) return;
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.fingerprint),
        title: Text(l10n.passkeySettings),
        content: Text(active ? l10n.passkeyActiveBody : l10n.passkeySetupBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.dialogClose),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(
              active ? l10n.passkeyRemoveAction : l10n.passkeySetupAction,
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
        outcome = l10n.passkeyRemoved;
      } else {
        final vault = switch (_stage) {
          _Open(:final vault) => vault,
          _ => throw const VaultLockedException(),
        };
        await keeper.enrollPasskey(vault);
        outcome = l10n.passkeyReady;
      }
    } on PasskeyCancelledException {
      outcome = l10n.passkeyCancelled;
    } on PasskeyUnsupportedException {
      outcome = l10n.passkeyUnsupported;
    } on VaultLockedException {
      // Locked while the user was at the authenticator: nothing was saved.
      return;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(outcome)));
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
        case AppLifecycleState.resumed:
          autoLock.shown();
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
    _Open(:final store, :final autoLock, :final sync, :final journal) =>
      AutoLockScope(
        autoLock: autoLock,
        child: NoteLibraryScreen(
          schemas: widget.catalog.current,
          store: store,
          cloud: sync == null
              ? null
              : CloudButton(
                  sync: sync,
                  onLinkDevice: widget.keeper.offersLinking
                      ? _linkDevice
                      : null,
                  onInvite: widget.keeper.offersInvites ? _invite : null,
                ),
          onLock: _lock,
          onBackup: widget.files == null ? null : _backup,
          onPasskey: widget.keeper.offersPasskeys ? _passkeySettings : null,
          journalSettings: journal == null
              ? null
              : () => JournalSettingsSheet.show(context, journal),
        ),
      ),
    _Joining() => JoinVaultScreen(
      account: widget.account!,
      join: _join,
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
      _Problem.passkeyCancelled => l10n.passkeyCancelled,
      _Problem.passkeyRejected => l10n.passkeyRejected,
      _Problem.passkeyUnsupported => l10n.passkeyUnsupported,
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
                    _PassphraseField(
                      key: const ValueKey('passphrase'),
                      controller: _passphrase,
                      label: l10n.passphraseLabel,
                      enabled: !_busy,
                      onSubmitted: creating ? null : submit,
                    ),
                    if (creating) ...[
                      const SizedBox(height: Spacing.m),
                      _PassphraseField(
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
                      Text(
                        problem,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                        textAlign: TextAlign.center,
                      ),
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
                    if (creating &&
                        widget.keeper.offersLinking &&
                        widget.account != null) ...[
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
                        label: Text(l10n.passkeyUnlockAction),
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

class _PassphraseField extends StatelessWidget {
  const _PassphraseField({
    required this.controller,
    required this.label,
    required this.enabled,
    required this.onSubmitted,
    super.key,
  });

  final TextEditingController controller;
  final String label;
  final bool enabled;
  final VoidCallback? onSubmitted;

  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    enabled: enabled,
    obscureText: true,
    autocorrect: false,
    enableSuggestions: false,
    keyboardType: TextInputType.visiblePassword,
    autofillHints: const [AutofillHints.password],
    decoration: InputDecoration(labelText: label),
    onSubmitted: onSubmitted == null ? null : (_) => onSubmitted!(),
  );
}
