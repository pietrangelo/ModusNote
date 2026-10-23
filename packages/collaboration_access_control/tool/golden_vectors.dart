// Writes server/vectors/ledger.json: membership logs and key bundles, good
// and bad, each with the verdict it is built to have. The Dart domain
// (test/golden_vectors_test.dart) and the Rust server check the same file,
// so neither can start accepting what the other refuses.
//
//   dart run tool/golden_vectors.dart ../../server/vectors/ledger.json
//
// Signatures and X-Wing ciphertexts are random, so every run writes a new
// file with the same cases; the file is committed and only rewritten when a
// case is added.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:collaboration_access_control/collaboration_access_control.dart';
import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:identity_cryptography_adapters/identity_cryptography_adapters.dart';
import 'package:sodium/sodium_sumo.dart';

late IdentityService identities;
late WorkspaceAdministration administration;

final workspace = WorkspaceId.parse('6d6f6475736e6f746573766563746f72');
final otherWorkspace = WorkspaceId.parse('0123456789abcdef0123456789abcdef');

Future<void> main(List<String> args) async {
  if (args.length != 1) {
    stderr.writeln('usage: dart run tool/golden_vectors.dart <out.json>');
    exit(64);
  }
  final sodium = await SodiumSumoInit.init();
  identities = SodiumIdentityService(sodium);
  administration = WorkspaceAdministration(
    identities: identities,
    encapsulation: SodiumKeyEncapsulation(sodium),
    envelopes: SodiumEnvelopeEncryptor(sodium),
  );
  final cases = _cases();
  final json = const JsonEncoder.withIndent(' ').convert({
    'about':
        'Membership logs and key bundles with the verdict each is built to '
        'have. accepted: how many records, from the first, a verifier '
        'accepts before it refuses the next one. members and epoch: the '
        'state after them. Each bundle is checked against that state.',
    'cases': cases,
  });
  File(args.single).writeAsStringSync('$json\n');
  stdout.writeln('${cases.length} cases written to ${args.single}');
}

/// A log under construction: the records as the server would store them,
/// signed by whoever the case says.
final class Log {
  Log(this.founder, {WorkspaceId? id}) {
    final founded = administration.found(id ?? workspace, founder: founder);
    ledger = founded.ledger;
    keyring = founded.keyring;
    records.add(founded.record);
    bundles.add(founded.bundle!);
  }

  final IdentityKeyPair founder;
  late VerifiedLedger ledger;
  late GroupKeyring keyring;
  final records = <MembershipRecord>[];
  final bundles = <KeyBundle>[];

  void invite(PublicIdentity invitee, Role role, {IdentityKeyPair? by}) {
    final update = administration.invite(
      ledger,
      keyring,
      owner: by ?? founder,
      invitee: invitee,
      role: role,
    );
    _take(update);
  }

  void revoke(MemberId member) => _take(
    administration.revoke(ledger, keyring, owner: founder, member: member),
  );

  void leave(IdentityKeyPair member) =>
      _take(administration.leave(ledger, member: member));

  void changeRole(MemberId member, Role role) => _take(
    administration.changeRole(
      ledger,
      owner: founder,
      member: member,
      role: role,
    ),
  );

  void _take(MembershipUpdate update) {
    ledger = update.ledger;
    records.add(update.record);
    if (update.bundle case final bundle?) bundles.add(bundle);
  }

  /// The record that would come next, signed by [author] with whatever
  /// fields the case overrides; no rule is checked.
  MembershipRecord next(
    MembershipChange change, {
    required IdentityKeyPair author,
    WorkspaceId? workspace,
    int? sequence,
    Signature? previous,
  }) {
    final last = records.last;
    final fields = (
      workspace: workspace ?? last.workspace,
      sequence: sequence ?? last.sequence + 1,
      author: MemberId.of(author.publicIdentity),
      previous: previous ?? last.signature,
    );
    return MembershipRecord(
      workspace: fields.workspace,
      sequence: fields.sequence,
      author: fields.author,
      previous: fields.previous,
      change: change,
      signature: identities.sign(
        MembershipRecord.signable(
          workspace: fields.workspace,
          sequence: fields.sequence,
          author: fields.author,
          previous: fields.previous,
          change: change,
        ),
        signer: author,
      ),
    );
  }
}

/// [wire] with the byte at [flip] changed and signed again by [issuer]:
/// a bundle the issuer really signed, whose content is out of shape.
Uint8List resigned(
  Uint8List wire,
  IdentityKeyPair issuer, {
  required int flip,
}) {
  final body = Uint8List.fromList(wire.sublist(0, wire.length - 64));
  body[flip] ^= 0x03;
  final signature = identities.sign(
    Uint8List.fromList([...utf8.encode('modusnote.keybundle.v1'), ...body]),
    signer: issuer,
  );
  return Uint8List.fromList([...body, ...signature.bytes]);
}

KeyBundle signedBundle(
  IdentityKeyPair issuer, {
  required int atSequence,
  required List<GroupKeyGrant> grants,
  WorkspaceId? id,
}) {
  final issuerId = MemberId.of(issuer.publicIdentity);
  final ws = id ?? workspace;
  return KeyBundle(
    workspace: ws,
    atSequence: atSequence,
    issuer: issuerId,
    grants: grants,
    signature: identities.sign(
      KeyBundle.signable(
        workspace: ws,
        atSequence: atSequence,
        issuer: issuerId,
        grants: grants,
      ),
      signer: issuer,
    ),
  );
}

/// The Ed25519 group order, little-endian: a signature whose S has it added
/// verifies in the group but is not canonical, and libsodium refuses it.
final _order = BigInt.parse(
  '7237005577332262213973186563042994240857116359379907606001950938285454250989',
);

Uint8List withNonCanonicalS(Uint8List wire) {
  final out = Uint8List.fromList(wire);
  final s = out.length - 32;
  var value = BigInt.zero;
  for (var i = 31; i >= 0; i--) {
    value = (value << 8) | BigInt.from(out[s + i]);
  }
  value += _order;
  for (var i = 0; i < 32; i++) {
    out[s + i] = (value >> (8 * i) & BigInt.from(0xff)).toInt();
  }
  return out;
}

/// The neutral point, canonical and as y = p + 1: a key of small order, which
/// libsodium refuses whatever the signature.
final smallOrderKeys = {
  'canonical': Uint8List(32)..[0] = 1,
  'non-canonical': Uint8List.fromList([0xee, ...List.filled(30, 0xff), 0x7f]),
};

String hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Map<String, Object> describe(
  String name,
  List<Uint8List> records, {
  required int accepted,
  VerifiedLedger? state,
  List<(KeyBundle, bool)> bundles = const [],
  List<(Uint8List, bool)> rawBundles = const [],
}) {
  final workspace = state?.workspace;
  return {
    'name': name,
    'records': [for (final record in records) hex(record)],
    'accepted': accepted,
    if (workspace != null) ...{
      'members': [
        for (final member in workspace.members.values)
          {'key': member.id.hex, 'role': member.role.wireCode},
      ],
      'epoch': workspace.epoch.value,
    },
    'bundles': [
      for (final (bundle, valid) in bundles)
        {'bundle': hex(bundle.toBytes()), 'valid': valid},
      for (final (wire, valid) in rawBundles)
        {'bundle': hex(wire), 'valid': valid},
    ],
  };
}

List<Map<String, Object>> _cases() {
  final alice = identities.generateIdentity();
  final bob = identities.generateIdentity();
  final carol = identities.generateIdentity();
  final dave = identities.generateIdentity();
  MemberId id(IdentityKeyPair pair) => MemberId.of(pair.publicIdentity);
  List<Uint8List> wire(List<MembershipRecord> records) => [
    for (final record in records) record.toBytes(),
  ];
  final cases = <Map<String, Object>>[];

  // A whole history: invite, role change, revoke with rotation, leave.
  final full = Log(alice)
    ..invite(bob.publicIdentity, Role.editor)
    ..invite(carol.publicIdentity, Role.viewer)
    ..changeRole(id(bob), Role.owner)
    ..revoke(id(carol))
    ..leave(bob);
  final sealedToBob = full.bundles[1].grants.first.sealedKey;
  cases.add(
    describe(
      'a whole history: invite, role change, revoke, leave',
      wire(full.records),
      accepted: full.records.length,
      state: full.ledger,
      bundles: [
        for (final bundle in full.bundles) (bundle, true),
        // Bob, an owner at record 3, grants epoch 1, which began at record 4.
        (
          signedBundle(
            bob,
            atSequence: 3,
            grants: [
              GroupKeyGrant(
                recipient: id(bob),
                epoch: KeyEpoch(1),
                sealedKey: sealedToBob,
              ),
            ],
          ),
          false,
        ),
        // Carol was a viewer: she grants nothing.
        (
          signedBundle(
            carol,
            atSequence: 2,
            grants: [
              GroupKeyGrant(
                recipient: id(carol),
                epoch: KeyEpoch.initial,
                sealedKey: sealedToBob,
              ),
            ],
          ),
          false,
        ),
        // Dave never was a member.
        (
          signedBundle(
            alice,
            atSequence: 5,
            grants: [
              GroupKeyGrant(
                recipient: id(dave),
                epoch: KeyEpoch(2),
                sealedKey: sealedToBob,
              ),
            ],
          ),
          false,
        ),
        // A record the log does not have.
        (signedBundle(alice, atSequence: 6, grants: const []), false),
        // Another workspace.
        (
          signedBundle(
            alice,
            atSequence: 0,
            grants: const [],
            id: otherWorkspace,
          ),
          false,
        ),
        // A flipped bit in the signature.
        (
          KeyBundle.parse(
            full.bundles.first.toBytes()
              ..[full.bundles.first.toBytes().length - 1] ^= 1,
          ),
          false,
        ),
        // Not canonical: S + L.
        (
          KeyBundle.parse(withNonCanonicalS(full.bundles.first.toBytes())),
          false,
        ),
        // An empty bundle from an owner says nothing, but is genuine.
        (signedBundle(alice, atSequence: 0, grants: const []), true),
      ],
      rawBundles: [
        // Signed by an owner, but the sealed key's envelope is of a version
        // no device opens: refused before anyone stores it.
        (
          resigned(
            signedBundle(
              alice,
              atSequence: 0,
              grants: [
                GroupKeyGrant(
                  recipient: id(alice),
                  epoch: KeyEpoch.initial,
                  sealedKey: sealedToBob,
                ),
              ],
            ).toBytes(),
            alice,
            // Header (55 bytes), epoch and recipient (36), then byte 1120
            // of the sealed key: its envelope version.
            flip: 55 + 36 + 1120,
          ),
          false,
        ),
      ],
    ),
  );

  final founded = Log(alice);
  cases.add(
    describe(
      'founded only',
      wire(founded.records),
      accepted: 1,
      state: founded.ledger,
      bundles: [(founded.bundles.single, true)],
    ),
  );

  List<Uint8List> afterFounding(MembershipRecord second) => [
    founded.records.single.toBytes(),
    second.toBytes(),
  ];
  final invite = MemberInvited(bob.publicIdentity, Role.editor);

  final badSignature = founded.next(invite, author: alice).toBytes();
  badSignature[badSignature.length - 1] ^= 1;
  cases
    ..add(
      describe(
        'a flipped bit in the signature',
        [founded.records.single.toBytes(), badSignature],
        accepted: 1,
        state: founded.ledger,
      ),
    )
    ..add(
      describe(
        'a signature with a non-canonical S',
        [
          founded.records.single.toBytes(),
          withNonCanonicalS(founded.next(invite, author: alice).toBytes()),
        ],
        accepted: 1,
        state: founded.ledger,
      ),
    )
    ..add(
      describe(
        'signed by someone who is not a member',
        afterFounding(founded.next(invite, author: dave)),
        accepted: 1,
        state: founded.ledger,
      ),
    )
    ..add(
      describe(
        'a broken chain',
        afterFounding(
          founded.next(
            invite,
            author: alice,
            previous: Signature.fromBytes(Uint8List(64)),
          ),
        ),
        accepted: 1,
        state: founded.ledger,
      ),
    )
    ..add(
      describe(
        'a skipped sequence',
        afterFounding(founded.next(invite, author: alice, sequence: 2)),
        accepted: 1,
        state: founded.ledger,
      ),
    )
    ..add(
      describe(
        'a record of another workspace',
        afterFounding(
          founded.next(invite, author: alice, workspace: otherWorkspace),
        ),
        accepted: 1,
        state: founded.ledger,
      ),
    )
    ..add(
      describe(
        'the last owner removed',
        afterFounding(founded.next(MemberRevoked(id(alice)), author: alice)),
        accepted: 1,
        state: founded.ledger,
      ),
    )
    ..add(
      describe(
        'the last owner made an editor',
        afterFounding(
          founded.next(RoleChanged(id(alice), Role.editor), author: alice),
        ),
        accepted: 1,
        state: founded.ledger,
      ),
    )
    ..add(
      describe(
        'a second founding',
        afterFounding(
          founded.next(WorkspaceFounded(bob.publicIdentity), author: alice),
        ),
        accepted: 1,
        state: founded.ledger,
      ),
    )
    ..add(
      describe(
        'inviting a member again',
        afterFounding(
          founded.next(
            MemberInvited(alice.publicIdentity, Role.editor),
            author: alice,
          ),
        ),
        accepted: 1,
        state: founded.ledger,
      ),
    )
    ..add(
      describe(
        'removing someone who is not a member',
        afterFounding(founded.next(MemberRevoked(id(dave)), author: alice)),
        accepted: 1,
        state: founded.ledger,
      ),
    );

  final withEditor = Log(alice)..invite(bob.publicIdentity, Role.editor);
  cases
    ..add(
      describe(
        'an editor invites',
        [
          ...wire(withEditor.records),
          withEditor
              .next(
                MemberInvited(carol.publicIdentity, Role.viewer),
                author: bob,
              )
              .toBytes(),
        ],
        accepted: 2,
        state: withEditor.ledger,
      ),
    )
    ..add(
      describe(
        'an editor makes themselves an owner',
        [
          ...wire(withEditor.records),
          withEditor
              .next(RoleChanged(id(bob), Role.owner), author: bob)
              .toBytes(),
        ],
        accepted: 2,
        state: withEditor.ledger,
      ),
    )
    ..add(
      describe(
        'an editor removes an owner',
        [
          ...wire(withEditor.records),
          withEditor.next(MemberRevoked(id(alice)), author: bob).toBytes(),
        ],
        accepted: 2,
        state: withEditor.ledger,
      ),
    );
  final left = withEditor.next(MemberRevoked(id(bob)), author: bob);
  final afterLeaving = Log(alice)..invite(bob.publicIdentity, Role.editor);
  afterLeaving.records.add(left);
  cases.add(
    describe('an editor leaves, then signs again', [
      ...wire(afterLeaving.records),
      afterLeaving
          .next(MemberInvited(bob.publicIdentity, Role.owner), author: bob)
          .toBytes(),
    ], accepted: 3)..addAll({
      'members': [
        {'key': id(alice).hex, 'role': Role.owner.wireCode},
      ],
      'epoch': 1,
    }),
  );

  // The first record: who founds is whoever the server first stores, but the
  // record must say so of itself.
  final genesis = founded.records.single;
  MembershipRecord genesisWith({
    MembershipChange? change,
    IdentityKeyPair? author,
    int sequence = 0,
  }) {
    final signer = author ?? alice;
    final authorId = MemberId.of(signer.publicIdentity);
    final body = change ?? WorkspaceFounded(alice.publicIdentity);
    final previous = sequence == 0 ? null : genesis.signature;
    return MembershipRecord(
      workspace: workspace,
      sequence: sequence,
      author: authorId,
      previous: previous,
      change: body,
      signature: identities.sign(
        MembershipRecord.signable(
          workspace: workspace,
          sequence: sequence,
          author: authorId,
          previous: previous,
          change: body,
        ),
        signer: signer,
      ),
    );
  }

  cases
    ..add(
      describe('the first record is not a founding', [
        genesisWith(change: MemberInvited(bob.publicIdentity, Role.owner))
            .toBytes(),
      ], accepted: 0),
    )
    ..add(
      describe('the first record founds someone else', [
        genesisWith(author: bob).toBytes(),
      ], accepted: 0),
    )
    ..add(
      describe('the first record does not start the log', [
        genesisWith(sequence: 1).toBytes(),
      ], accepted: 0),
    );
  final badGenesis = genesis.toBytes();
  badGenesis[badGenesis.length - 1] ^= 1;
  cases.add(
    describe('the first record\'s signature is broken', [
      badGenesis,
    ], accepted: 0),
  );
  for (final MapEntry(key: name, value: key) in smallOrderKeys.entries) {
    final founder = PublicIdentity(
      signingKey: PublicSigningKey.fromBytes(key),
      encryptionKey: alice.publicIdentity.encryptionKey,
    );
    final record = MembershipRecord(
      workspace: workspace,
      sequence: 0,
      author: MemberId.of(founder),
      previous: null,
      change: WorkspaceFounded(founder),
      // The neutral point verifies R == [S]B when S is 0 and R is the
      // neutral point too: only a check for small order refuses it.
      signature: Signature.fromBytes(Uint8List(64)..[0] = 1),
    );
    cases.add(
      describe('founded by a key of small order ($name)', [
        record.toBytes(),
      ], accepted: 0),
    );
  }

  // Bytes that do not parse.
  final good = genesis.toBytes();
  cases
    ..add(
      describe('a truncated record', [
        Uint8List.sublistView(good, 0, good.length - 1),
      ], accepted: 0),
    )
    ..add(
      describe('a trailing byte', [
        Uint8List.fromList([...good, 0]),
      ], accepted: 0),
    )
    ..add(
      describe('an unknown version', [
        Uint8List.fromList(good)..[0] = 2,
      ], accepted: 0),
    );
  final unknownRole = withEditor.records[1].toBytes();
  // The role is the byte before the signature.
  unknownRole[unknownRole.length - 65] = 9;
  cases.add(
    describe(
      'an unknown role',
      [withEditor.records.first.toBytes(), unknownRole],
      accepted: 1,
      state: founded.ledger,
    ),
  );
  return cases;
}
