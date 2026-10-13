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

import '../audio/note_playback.dart';
import '../audio/note_recorder.dart';
import '../l10n/generated/app_localizations.dart';
import '../notes/note_library.dart';
import '../sync/blob_sync.dart';
import '../sync/cloud_sheet.dart';
import '../sync/sync_controller.dart';
import '../theme/golden_ratio.dart';
import '../theme/modus_colors.dart';
import 'auto_lock.dart';
import 'vault_note_store.dart';

/// Moves a UTF-8 passphrase into native memory and wipes the buffer.
typedef PasswordFactory = PasswordSecret Function(Uint8List utf8Bytes);

/// The app's front door: creates the vault on first launch, asks for the
/// passphrase (or the passkey, where one is set up) afterwards, and shows
/// the notes only while it is unlocked.
class VaultGate extends StatefulWidget {
  const VaultGate({
    required this.keeper,
    required this.passwordFrom,
    required this.catalog,
    this.recorderFor,
    this.playbackFor,
    this.replicationFor,
    this.autoLockFor,
    this.account,
    this.syncFor,
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
    Future<void> Function(KeyedRecording take)? ensureLocal,
  )?
  playbackFor;

  /// Connects the open vault's recordings to the workspace's shared
  /// storage; null without a server, which keeps them on the device.
  final BlobReplication Function(SyncEngine engine)? replicationFor;

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

final class _Open extends _Stage {
  const _Open(this.vault, this.store, this.autoLock, this.sync);

  final UnlockedVault vault;
  final VaultNoteStore store;
  final AutoLock autoLock;
  final SyncController? sync;
}

/// The Supabase session, sealed in the vault under the local key: it opens
/// only the account's rows (ciphertext), but it is still a credential.
const _sessionSetting = 'sync.session';

/// The recordings already in the workspace's shared storage.
const _sentBlobsSetting = 'sync.blobs-sent';

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
    if (_stage case _Open(:final vault, :final autoLock, :final sync)) {
      sync?.dispose();
      widget.account?.detach();
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
    setState(() {
      _busy = true;
      _problem = null;
    });
    // Let the progress indicator paint before Argon2id holds the isolate.
    await Future<void>.delayed(Duration.zero);
    try {
      final vault = await opening();
      final replication = widget.account == null
          ? null
          : widget.replicationFor?.call(vault.engine);
      BlobSync? blobs;
      final store = await VaultNoteStore.open(
        vault.engine,
        catalog: widget.catalog,
        recorder: widget.recorderFor?.call(vault.engine),
        playback: widget.playbackFor?.call(
          vault.engine,
          replication == null ? null : (take) => blobs!.ensureLocal(take),
        ),
      );
      if (replication != null) {
        blobs = _blobSync(vault, store, replication);
      }
      final sync = await _connect(vault, store, blobs);
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
      setState(() => _stage = _Open(vault, store, autoLock, sync));
      sync?.start();
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
          afterSync: blobs?.uploadPending,
        );
    store.onWrite = sync.changed;
    return sync;
  }

  /// Which recordings the server holds is a sealed setting, like the
  /// session; a damaged one only means checking them again.
  BlobSync _blobSync(
    UnlockedVault vault,
    VaultNoteStore store,
    BlobReplication replication,
  ) {
    final keeper = widget.keeper;
    return BlobSync(
      replication: replication,
      recordings: () => store.recordings,
      load: () async {
        try {
          return await keeper.loadSetting(vault, _sentBlobsSetting);
        } on MalformedSyncDataException {
          return null;
        }
      },
      save: (value) => keeper.saveSetting(vault, _sentBlobsSetting, value),
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

  void _fail(_Problem problem) {
    if (mounted) setState(() => _problem = problem);
  }

  void _lock() {
    if (_stage case _Open(
      :final vault,
      :final store,
      :final autoLock,
      :final sync,
    )) {
      _stopWatching();
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
    if (event is PointerDownEvent) _watched?.touch();
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
    _Open(:final store, :final autoLock, :final sync) => AutoLockScope(
      autoLock: autoLock,
      child: NoteLibraryScreen(
        schemas: widget.catalog.current,
        store: store,
        cloud: sync == null ? null : CloudButton(sync: sync),
        onLock: _lock,
        onPasskey: widget.keeper.offersPasskeys ? _passkeySettings : null,
      ),
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
    final submit = _busy ? null : () => _submit(creating: creating);
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
                    Icon(
                      Icons.lock_outline,
                      size: IconSizes.prominent,
                      color: ModusColors.aureoGold,
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
                          color: ModusColors.dustSilver,
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
                          color: ModusColors.dustSilver,
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
