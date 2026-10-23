import 'dart:typed_data';

import 'package:identity_cryptography/identity_cryptography.dart';

import '../core/collaboration_exception.dart';
import '../core/identifiers.dart';
import '../core/workspace.dart';
import '../core/workspace_ciphertext.dart';
import 'group_keyring.dart';

/// Use case: seals record payloads (entries, schemas, blob metadata) under
/// the workspace's current GroupKey and opens them under whichever epoch
/// they were written in.
final class WorkspaceContentCipher {
  WorkspaceContentCipher(this._envelopes);

  final EnvelopeEncryptor _envelopes;

  /// Always the current epoch: after a departure nothing new is written
  /// until an owner has issued the next key ([MissingGroupKeyException]).
  WorkspaceCiphertext seal(
    Uint8List plaintext, {
    required Workspace workspace,
    required MemberId author,
    required GroupKeyring keyring,
    required String recordId,
  }) {
    if (!(workspace.member(author)?.role.writesContent ?? false)) {
      throw const NotAuthorizedException();
    }
    final epoch = workspace.epoch;
    return WorkspaceCiphertext(
      epoch: epoch,
      envelope: _envelopes.seal(
        plaintext,
        key: keyring.keyFor(epoch),
        associatedData: WorkspaceCiphertext.associatedData(
          keyring.workspace,
          epoch,
          recordId,
        ),
      ),
    );
  }

  /// Seals again, under [epoch], a payload that was first sealed then: a
  /// revision already signed by its author, carried to a new server. It
  /// adds nothing a member could not already read under that epoch.
  /// Throws [MissingGroupKeyException] when this device lacks the key.
  WorkspaceCiphertext sealAt(
    Uint8List plaintext, {
    required KeyEpoch epoch,
    required GroupKeyring keyring,
    required String recordId,
  }) => WorkspaceCiphertext(
    epoch: epoch,
    envelope: _envelopes.seal(
      plaintext,
      key: keyring.keyFor(epoch),
      associatedData: WorkspaceCiphertext.associatedData(
        keyring.workspace,
        epoch,
        recordId,
      ),
    ),
  );

  Uint8List open(
    WorkspaceCiphertext ciphertext, {
    required GroupKeyring keyring,
    required String recordId,
  }) => _envelopes.open(
    ciphertext.envelope,
    key: keyring.keyFor(ciphertext.epoch),
    associatedData: WorkspaceCiphertext.associatedData(
      keyring.workspace,
      ciphertext.epoch,
      recordId,
    ),
  );
}
