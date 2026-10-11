import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:collaboration_access_control/collaboration_access_control.dart';
import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:meta/meta.dart';

import 'sync_exception.dart';
import 'version_vector.dart';
import 'wire.dart';

/// Opaque, random record identifier: with the workspace id, the only thing
/// about a record the sync server sees in clear.
@immutable
final class RecordId {
  RecordId._(this.hex);

  factory RecordId.parse(String hex) {
    if (!_hex32.hasMatch(hex)) {
      throw const MalformedSyncDataException('malformed record id');
    }
    return RecordId._(hex);
  }

  factory RecordId.random(Random random) => RecordId._(
    List.generate(
      length,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join(),
  );

  static const length = 16;
  static final _hex32 = RegExp(r'^[0-9a-f]{32}$');

  final String hex;

  @override
  bool operator ==(Object other) => other is RecordId && other.hex == hex;

  @override
  int get hashCode => hex.hashCode;

  @override
  String toString() => hex;
}

/// The last membership record the author had verified when writing.
///
/// Citing it by position and signature lets readers notice when the server
/// shows them a shorter or different membership log than it showed the
/// author: the rollback and fork that a single device cannot detect alone.
@immutable
final class LedgerHead {
  const LedgerHead({required this.sequence, required this.signature});

  final int sequence;
  final Signature signature;

  @override
  bool operator ==(Object other) =>
      other is LedgerHead &&
      other.sequence == sequence &&
      other.signature == signature;

  @override
  int get hashCode => Object.hash(sequence, signature);
}

@immutable
sealed class RevisionBody {
  const RevisionBody();
}

/// The serialized record (an entry, a schema, blob metadata), opaque here.
final class RevisionContents extends RevisionBody {
  const RevisionContents(this.bytes);

  final List<int> bytes;

  @override
  bool operator ==(Object other) =>
      other is RevisionContents && _sameBytes(other.bytes, bytes);

  @override
  int get hashCode => Object.hashAll(bytes);
}

/// A deletion is a revision too, so it wins or loses like any edit and a
/// stale copy cannot bring the record back.
final class RevisionDeleted extends RevisionBody {
  const RevisionDeleted();

  @override
  bool operator ==(Object other) => other is RevisionDeleted;

  @override
  int get hashCode => 0;
}

/// One version of a record as its author wrote it. It travels signed and
/// then sealed under the GroupKey, so the server sees none of these fields.
@immutable
final class RecordRevision {
  RecordRevision({
    required this.record,
    required this.workspace,
    required this.version,
    required this.author,
    required this.writtenAt,
    required this.ledgerHead,
    required this.body,
  }) {
    if (!writtenAt.isUtc) {
      throw const MalformedSyncDataException('writtenAt must be UTC');
    }
  }

  static const _label = 'modusnote.revision.v1';

  /// DateTime's own range (±100 000 000 days around the epoch).
  static const _maxMicroseconds = 8640000000000000000;

  final RecordId record;
  final WorkspaceId workspace;
  final VersionVector version;
  final MemberId author;
  final DateTime writtenAt;
  final LedgerHead ledgerHead;
  final RevisionBody body;

  /// The exact bytes the author signs.
  Uint8List get signable {
    final writer = WireWriter()..bytes(ascii.encode(_label));
    _write(writer);
    return writer.take();
  }

  void _write(WireWriter writer) {
    writer
      ..bytes(_hexBytes(record.hex))
      ..bytes(workspace.bytes);
    version.write(writer);
    writer
      ..bytes(author.signingKey.bytes)
      ..int64(writtenAt.microsecondsSinceEpoch)
      ..uint32(ledgerHead.sequence)
      ..bytes(ledgerHead.signature.bytes);
    switch (body) {
      case RevisionContents(:final bytes):
        writer
          ..uint8(1)
          ..blob(bytes);
      case RevisionDeleted():
        writer.uint8(0);
    }
  }

  static RecordRevision _read(WireReader reader) {
    final record = RecordId.parse(_hex(reader.bytes(RecordId.length)));
    final workspace = WorkspaceId.parse(_hex(reader.bytes(WorkspaceId.length)));
    final version = VersionVector.read(reader);
    final author = MemberId(
      PublicSigningKey.fromBytes(reader.bytes(PublicSigningKey.length)),
    );
    final micros = reader.int64();
    if (micros.abs() > _maxMicroseconds) {
      throw const MalformedSyncDataException('writtenAt out of range');
    }
    final writtenAt = DateTime.fromMicrosecondsSinceEpoch(micros, isUtc: true);
    final ledgerHead = LedgerHead(
      sequence: reader.uint32(),
      signature: Signature.fromBytes(reader.bytes(Signature.length)),
    );
    final body = switch (reader.uint8()) {
      0 => const RevisionDeleted(),
      1 => RevisionContents(Uint8List.fromList(reader.blob())),
      _ => throw const MalformedSyncDataException('unknown body kind'),
    };
    return RecordRevision(
      record: record,
      workspace: workspace,
      version: version,
      author: author,
      writtenAt: writtenAt,
      ledgerHead: ledgerHead,
      body: body,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is RecordRevision &&
      other.record == record &&
      other.workspace == workspace &&
      other.version == version &&
      other.author == author &&
      other.writtenAt == writtenAt &&
      other.ledgerHead == ledgerHead &&
      other.body == body;

  @override
  int get hashCode => Object.hash(
    record,
    workspace,
    version,
    author,
    writtenAt,
    ledgerHead,
    body,
  );
}

/// A [RecordRevision] with its author's signature: the plaintext inside a
/// record's `WorkspaceCiphertext`. Wire: `revision | signature`.
@immutable
final class SignedRevision {
  const SignedRevision({required this.revision, required this.signature});

  factory SignedRevision.parse(List<int> wire) {
    final reader = WireReader(wire);
    final revision = RecordRevision._read(reader);
    final signature = Signature.fromBytes(reader.bytes(Signature.length));
    reader.finish();
    return SignedRevision(revision: revision, signature: signature);
  }

  final RecordRevision revision;
  final Signature signature;

  Uint8List toBytes() {
    final writer = WireWriter();
    revision._write(writer);
    writer.bytes(signature.bytes);
    return writer.take();
  }

  @override
  bool operator ==(Object other) =>
      other is SignedRevision &&
      other.revision == revision &&
      other.signature == signature;

  @override
  int get hashCode => Object.hash(revision, signature);
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

String _hex(List<int> bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

Uint8List _hexBytes(String hex) => Uint8List.fromList([
  for (var i = 0; i < hex.length; i += 2)
    int.parse(hex.substring(i, i + 2), radix: 16),
]);
