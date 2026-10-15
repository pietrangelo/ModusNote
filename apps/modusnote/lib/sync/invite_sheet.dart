import 'dart:math';

import 'package:collaboration_access_control/collaboration_access_control.dart';
import 'package:flutter/material.dart';
import 'package:offline_sync/offline_sync.dart';

import '../l10n/generated/app_localizations.dart';
import '../theme/golden_ratio.dart';
import '../theme/modus_colors.dart';
import 'link_device_sheet.dart';

/// Invites another person: the owner picks what they may do, then shows a
/// one-time code that the person types on their own device, signed in to
/// their own account. Their device is admitted with that role and their
/// account let into the workspace.
///
/// Like [LinkDeviceSheet], the vault stays open while the sheet is up and
/// closing it withdraws the code.
class InviteSheet extends StatefulWidget {
  const InviteSheet({
    required this.offer,
    this.onInvited,
    this.pollEvery = const Duration(seconds: 2),
    super.key,
  });

  /// Posts the invitation for [code]; see [VaultKeeper.offerInvite].
  final Future<InviteOffering> Function(InviteCode code, Role role) offer;

  /// Called once the person was admitted, to sync them the keys at once.
  final VoidCallback? onInvited;
  final Duration pollEvery;

  static Future<void> show(
    BuildContext context, {
    required Future<InviteOffering> Function(InviteCode code, Role role) offer,
    VoidCallback? onInvited,
  }) => showHeldSheet(context, InviteSheet(offer: offer, onInvited: onInvited));

  @override
  State<InviteSheet> createState() => _InviteSheetState();
}

class _InviteSheetState extends State<InviteSheet> {
  var _role = Role.editor;
  var _started = false;

  Future<CodeAdmission> _start() async {
    final code = InviteCode.random(Random.secure());
    final offering = await widget.offer(code, _role);
    return (code: code.display, poll: offering.poll, cancel: offering.cancel);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final muted = Theme.of(context).textTheme.bodyMedium
        ?.copyWith(color: ModusColors.dustSilver);
    return CodeSheetFrame(
      title: l10n.inviteTitle,
      child: _started
          ? CodeAdmissionPanel(
              start: _start,
              onAdmitted: widget.onInvited,
              pollEvery: widget.pollEvery,
              texts: (
                instructions: l10n.inviteInstructions,
                waiting: l10n.inviteWaiting,
                done: l10n.inviteDone,
                refused: l10n.inviteRefused,
                untrusted: l10n.inviteUntrusted,
              ),
            )
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(l10n.inviteBody, style: muted),
                const SizedBox(height: Spacing.l),
                SegmentedButton<Role>(
                  key: const ValueKey('invite-role'),
                  showSelectedIcon: false,
                  segments: [
                    ButtonSegment(
                      value: Role.viewer,
                      label: Text(l10n.membersRoleViewer),
                    ),
                    ButtonSegment(
                      value: Role.editor,
                      label: Text(l10n.membersRoleEditor),
                    ),
                    ButtonSegment(
                      value: Role.owner,
                      label: Text(l10n.membersRoleOwner),
                    ),
                  ],
                  selected: {_role},
                  onSelectionChanged: (roles) =>
                      setState(() => _role = roles.single),
                ),
                const SizedBox(height: Spacing.m),
                Text(switch (_role) {
                  Role.viewer => l10n.inviteRoleViewer,
                  Role.editor => l10n.inviteRoleEditor,
                  Role.owner => l10n.inviteRoleOwner,
                }, style: muted),
                const SizedBox(height: Spacing.l),
                FilledButton(
                  key: const ValueKey('invite-create'),
                  onPressed: () => setState(() => _started = true),
                  child: Text(l10n.inviteCreate),
                ),
              ],
            ),
    );
  }
}
