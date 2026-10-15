import 'dart:convert';
import 'dart:typed_data';

import 'package:collaboration_access_control/collaboration_access_control.dart';
import 'package:identity_cryptography/identity_cryptography.dart';
import 'package:identity_cryptography_adapters/identity_cryptography_adapters.dart';
import 'package:offline_sync/offline_sync.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:test/test.dart';

import 'fakes.dart';
import 'support.dart' show workspaceId;

late SodiumSumo sodium;
late IdentityService identities;
late WorkspaceAdministration administration;
late MembershipLedger ledgers;

Uint8List text(String value) => Uint8List.fromList(utf8.encode(value));

/// One device with its own local database and sync engine.
final class Device {
  Device(this.server, this.clock) : identity = identities.generateIdentity();

  final FakeSyncServer server;
  final FakeClock clock;
  final IdentityKeyPair identity;
  final SymmetricKey localKey = SodiumEnvelopeEncryptor(sodium).generateKey();
  final store = FakeLocalStore();
  late SyncEngine engine;
  late GroupKeyring keyring;

  MemberId get id => MemberId.of(identity.publicIdentity);

  void start(VerifiedLedger ledger, GroupKeyring keyring) {
    this.keyring = keyring;
    engine = SyncEngine(
      server: server,
      store: store,
      identities: identities,
      administration: administration,
      contents: WorkspaceContentCipher(SodiumEnvelopeEncryptor(sodium)),
      envelopes: SodiumEnvelopeEncryptor(sodium),
      localKey: localKey,
      clock: clock,
      me: identity,
      ledger: ledger,
      keyring: keyring,
    );
  }

  Future<String?> read(RecordId id) async => switch (await engine.read(id)) {
    RevisionContents(:final bytes) => utf8.decode(bytes),
    RevisionDeleted() => '<deleted>',
    null => null,
  };

  void dispose() {
    identity.dispose();
    localKey.dispose();
    keyring.dispose();
  }

  /// Seals [signed] as this device could, bypassing its own client checks:
  /// what a malicious member holding the GroupKey can put on the server.
  WorkspaceCiphertext sealDirectly(SignedRevision signed, {KeyEpoch? epoch}) {
    final at = epoch ?? keyring.epochs.last;
    return WorkspaceCiphertext(
      epoch: at,
      envelope: SodiumEnvelopeEncryptor(sodium).seal(
        signed.toBytes(),
        key: keyring.keyFor(at),
        associatedData: WorkspaceCiphertext.associatedData(
          workspaceId,
          at,
          signed.revision.record.hex,
        ),
      ),
    );
  }
}

void main() {
  late FakeSyncServer server;
  late FakeClock clock;
  late Device alice;
  late Device bob;
  late Invitation invitation;
  final note = RecordId.parse('0123456789abcdef0123456789abcdef');
  final other = RecordId.parse('fedcba9876543210fedcba9876543210');

  setUpAll(() async {
    sodium = await SodiumSumoInit.init();
    identities = SodiumIdentityService(sodium);
    ledgers = MembershipLedger(identities);
    administration = WorkspaceAdministration(
      identities: identities,
      encapsulation: SodiumKeyEncapsulation(sodium),
      envelopes: SodiumEnvelopeEncryptor(sodium),
    );
  });

  void publish(MembershipUpdate update) {
    server.membershipLog.add(update.record);
    if (update.bundle case final bundle?) server.bundles.add(bundle);
  }

  /// Alice founds the workspace and invites Bob with [role].
  setUp(() async {
    server = FakeSyncServer();
    clock = FakeClock(DateTime.utc(2026, 10, 11, 9));
    alice = Device(server, clock);
    bob = Device(server, clock);

    final founded = administration.found(workspaceId, founder: alice.identity);
    publish(founded);
    invitation = founded.invitation;
    final invited = administration.invite(
      founded.ledger,
      founded.keyring,
      owner: alice.identity,
      invitee: bob.identity.publicIdentity,
      role: Role.editor,
    );
    publish(invited);
    alice.start(invited.ledger, founded.keyring);
    bob.start(
      ledgers.verify(server.membershipLog, invitation: invitation),
      GroupKeyring(workspaceId),
    );
    await bob.engine.sync();
  });

  tearDown(() {
    alice.dispose();
    bob.dispose();
  });

  test('only the founder registers the workspace on the server', () async {
    expect(server.createdWorkspaces, isEmpty, reason: 'Bob synced first');

    await alice.engine.sync();

    expect(server.createdWorkspaces, [workspaceId]);
    expect(
      server.membershipLog,
      hasLength(2),
      reason: 'nothing appended twice',
    );
  });

  group('offline first', () {
    test('a write is readable at once, with no server at all', () async {
      server.online = false;
      await alice.engine.write(note, RevisionContents(text('Ritornello')));

      expect(await alice.read(note), 'Ritornello');
      expect(alice.store.outbox.pending, hasLength(1));
    });

    test('syncing offline loses nothing and reports it', () async {
      server.online = false;
      await alice.engine.write(note, RevisionContents(text('Ritornello')));

      final report = await alice.engine.sync();

      expect(report.offline, isTrue);
      expect(alice.store.outbox.pending, hasLength(1));
      expect(server.rows, isEmpty);
    });

    test('queued edits are pushed in order when the network returns', () async {
      server.online = false;
      await alice.engine.write(note, RevisionContents(text('uno')));
      await alice.engine.write(other, RevisionContents(text('due')));
      await alice.engine.write(note, RevisionContents(text('tre')));
      server.online = true;

      final report = await alice.engine.sync();

      expect(report.pushed, 2, reason: 'the two edits of a note coalesce');
      expect(server.rows.map((row) => row.record), [note, other]);
      expect(alice.store.outbox.pending, isEmpty);
    });

    test('the engine says whether edits still wait for the server', () async {
      expect(await alice.engine.hasUnsentWrites(), isFalse);
      server.online = false;
      await alice.engine.write(note, RevisionContents(text('uno')));
      await alice.engine.sync();
      expect(await alice.engine.hasUnsentWrites(), isTrue);

      server.online = true;
      await alice.engine.sync();

      expect(await alice.engine.hasUnsentWrites(), isFalse);
    });
  });

  group('between devices', () {
    test('what one device writes, the other reads after syncing', () async {
      await alice.engine.write(note, RevisionContents(text('Sogno del faro')));
      await alice.engine.sync();

      final report = await bob.engine.sync();

      expect(report.pulled, 1);
      expect(await bob.read(note), 'Sogno del faro');
    });

    test('a later edit replaces an earlier one on every device', () async {
      await alice.engine.write(note, RevisionContents(text('v1')));
      await alice.engine.sync();
      await bob.engine.sync();
      await bob.engine.write(note, RevisionContents(text('v2')));
      await bob.engine.sync();

      await alice.engine.sync();

      expect(await alice.read(note), 'v2');
      expect(await bob.read(note), 'v2');
    });

    test('concurrent offline edits converge on the same winner', () async {
      await alice.engine.write(note, RevisionContents(text('base')));
      await alice.engine.sync();
      await bob.engine.sync();
      server.online = false;

      await alice.engine.write(note, RevisionContents(text('di Alice')));
      clock.advance();
      await bob.engine.write(note, RevisionContents(text('di Bob')));
      server.online = true;

      await alice.engine.sync();
      final report = await bob.engine.sync();
      await alice.engine.sync();

      expect(report.conflicts, 1);
      expect(await alice.read(note), 'di Bob');
      expect(await bob.read(note), 'di Bob');
    });

    test('an edit made after seeing a conflict replaces both sides', () async {
      await alice.engine.write(note, RevisionContents(text('base')));
      await alice.engine.sync();
      await bob.engine.sync();
      server.online = false;
      await alice.engine.write(note, RevisionContents(text('A')));
      await bob.engine.write(note, RevisionContents(text('B')));
      server.online = true;
      await alice.engine.sync();
      await bob.engine.sync();
      await alice.engine.sync();

      await alice.engine.write(note, RevisionContents(text('risolto')));
      await alice.engine.sync();
      await bob.engine.sync();

      expect(await bob.read(note), 'risolto');
    });

    test('a deletion propagates and a stale copy cannot revive it', () async {
      await alice.engine.write(note, RevisionContents(text('v1')));
      await alice.engine.sync();
      await bob.engine.sync();
      final stale = server.rows.first;

      await alice.engine.write(note, const RevisionDeleted());
      await alice.engine.sync();
      await bob.engine.sync();
      server.rows.add(stale);
      await bob.engine.sync();

      expect(await bob.read(note), '<deleted>');
    });

    test('key bundles are picked up during sync', () async {
      expect(bob.keyring.epochs, [KeyEpoch.initial]);
    });
  });

  group('heads', () {
    test('a sync with nothing new asks the server one question', () async {
      await alice.engine.write(note, RevisionContents(text('v1')));
      await alice.engine.sync();
      await alice.engine.sync();
      server.reads.clear();

      final report = await alice.engine.sync();

      expect(server.reads, ['heads']);
      expect(report.pulled, 0);
      expect(report.offline, isFalse);
    });

    test('only the streams that moved are read', () async {
      await alice.engine.sync();
      await bob.engine.sync();
      await alice.engine.write(note, RevisionContents(text('nuova')));
      await alice.engine.sync();
      server.reads.clear();

      final report = await bob.engine.sync();

      expect(server.reads, ['heads', 'rows']);
      expect(report.pulled, 1);
      expect(await bob.read(note), 'nuova');
    });

    test('a new key bundle or membership record is still picked up', () async {
      await bob.engine.sync();
      final carol = identities.generateIdentity();
      addTearDown(carol.dispose);
      publish(
        administration.invite(
          alice.engine.ledger,
          alice.keyring,
          owner: alice.identity,
          invitee: carol.publicIdentity,
          role: Role.editor,
        ),
      );
      server.reads.clear();

      await bob.engine.sync();

      expect(server.reads, ['heads', 'membership', 'bundles']);
      expect(bob.engine.ledger.records, hasLength(server.membershipLog.length));
    });

    test('a server without heads gets every question, as before', () async {
      await alice.engine.write(note, RevisionContents(text('v1')));
      await alice.engine.sync();
      server
        ..headless = true
        ..reads.clear();

      await bob.engine.sync();

      expect(server.reads, ['heads', 'membership', 'bundles', 'rows']);
      expect(await bob.read(note), 'v1');
    });

    test('adversary: heads that lie low only delay what the server could '
        'already withhold', () async {
      await alice.engine.write(note, RevisionContents(text('v1')));
      await alice.engine.sync();
      server.lieLow = true;

      expect((await bob.engine.sync()).pulled, 0);

      server.lieLow = false;
      expect((await bob.engine.sync()).pulled, 1);
      expect(await bob.read(note), 'v1');
    });
  });

  group('compaction', () {
    /// A device admitted after everything else happened: it sees only what
    /// the server still holds.
    Future<Device> latecomer() async {
      final carol = Device(server, clock);
      addTearDown(carol.dispose);
      publish(
        administration.invite(
          alice.engine.ledger,
          alice.keyring,
          owner: alice.identity,
          invitee: carol.identity.publicIdentity,
          role: Role.editor,
        ),
      );
      carol.start(
        ledgers.verify(server.membershipLog, invitation: invitation),
        GroupKeyring(workspaceId),
      );
      await carol.engine.sync();
      return carol;
    }

    SignedRevision stored(SealedRow row) => SignedRevision.parse(
      WorkspaceContentCipher(
        SodiumEnvelopeEncryptor(sodium),
      ).open(row.ciphertext, keyring: alice.keyring, recordId: row.record.hex),
    );

    test('an edit removes the revisions its writer had already seen', () async {
      await alice.engine.write(note, RevisionContents(text('v1')));
      await alice.engine.sync();
      await alice.engine.write(note, RevisionContents(text('v2')));
      await alice.engine.sync();
      await bob.engine.sync();
      await bob.engine.write(note, RevisionContents(text('v3')));
      await bob.engine.write(other, RevisionContents(text('altra')));
      await bob.engine.sync();

      expect(server.rows, hasLength(4));
      expect(server.live.map((row) => row.record), [note, other]);
      expect(await (await latecomer()).read(note), 'v3');
      await alice.engine.sync();
      expect(await alice.read(note), 'v3');
    });

    test('a new record and a first edit remove nothing', () async {
      await alice.engine.write(note, RevisionContents(text('v1')));
      await alice.engine.sync();
      await bob.engine.sync();
      await bob.engine.write(other, RevisionContents(text('altra')));
      await bob.engine.sync();

      expect(server.compacted, isEmpty);
    });

    test('concurrent edits both survive and every device agrees', () async {
      await alice.engine.write(note, RevisionContents(text('base')));
      await alice.engine.sync();
      await bob.engine.sync();
      server.online = false;
      await alice.engine.write(note, RevisionContents(text('di Alice')));
      clock.advance();
      await bob.engine.write(note, RevisionContents(text('di Bob')));
      server.online = true;

      await alice.engine.sync();
      await bob.engine.sync();
      await alice.engine.sync();

      expect(server.live, hasLength(2), reason: 'only the base is gone');
      final carol = await latecomer();
      expect(await alice.read(note), 'di Bob');
      expect(await bob.read(note), 'di Bob');
      expect(await carol.read(note), 'di Bob');
    });

    test('an edit made while a pull is in flight keeps what that pull '
        'brings', () async {
      await alice.engine.write(note, RevisionContents(text('base')));
      await alice.engine.sync();
      await bob.engine.sync();
      clock.advance(const Duration(hours: 1));
      await bob.engine.write(note, RevisionContents(text('di Bob, dopo')));
      await bob.engine.sync();
      clock.advance(const Duration(hours: -1));

      // Alice saves while her sync is between its push and its pull: her
      // edit has not seen Bob's, so it must not remove it.
      server.onPull = () async {
        server.onPull = null;
        await alice.engine.write(note, RevisionContents(text('di Alice')));
      };
      await alice.engine.sync();
      await alice.engine.sync();
      await bob.engine.sync();

      expect(server.live, hasLength(2));
      final carol = await latecomer();
      final winner = await bob.read(note);
      expect(await alice.read(note), winner);
      expect(await carol.read(note), winner);
    });

    test('a row the writer could not open is never removed', () async {
      await alice.engine.write(note, RevisionContents(text('v1')));
      await alice.engine.sync();
      // Sealed under an epoch Bob has not been granted (yet).
      final sealed = server.rows.single.ciphertext;
      server.rows.add(
        SealedRow(
          record: note,
          ciphertext: WorkspaceCiphertext(
            epoch: KeyEpoch(7),
            envelope: sealed.envelope,
          ),
        ),
      );
      await alice.engine.write(other, RevisionContents(text('dopo')));
      await alice.engine.sync();

      final report = await bob.engine.sync();
      await bob.engine.write(note, RevisionContents(text('v2')));
      await bob.engine.sync();

      expect(report.undecryptable, 1);
      expect(server.compacted, {
        1,
      }, reason: 'v1 goes, the unreadable row stays');
    });

    test('a revision is always later than every revision its writer saw, '
        'whatever the clock says', () async {
      await alice.engine.write(note, RevisionContents(text('v1')));
      await alice.engine.sync();
      await bob.engine.sync();
      final seen = stored(server.rows.single).revision.writtenAt;

      clock.advance(const Duration(hours: -5));
      await bob.engine.write(note, RevisionContents(text('v2')));
      await bob.engine.sync();

      expect(stored(server.rows.last).revision.writtenAt.isAfter(seen), isTrue);
    });

    test('a skewed clock cannot make a latecomer disagree', () async {
      // d at 10:00; X at 07:00 by Carol, who has not seen d; D by Bob, who
      // has seen d but not X, on a clock five hours behind. D removes d. A
      // device holding d keeps it against X, then takes D; one that never
      // saw d would weigh X against D by time alone and, without monotonic
      // times, pick X.
      final carol = await latecomer();
      clock.current = DateTime.utc(2026, 10, 11, 10);
      await alice.engine.write(note, RevisionContents(text('d')));
      await alice.engine.sync();
      await bob.engine.sync();
      clock.current = DateTime.utc(2026, 10, 11, 7);
      await carol.engine.write(note, RevisionContents(text('X')));
      await carol.engine.sync();
      clock.current = DateTime.utc(2026, 10, 11, 5);
      await bob.engine.write(note, RevisionContents(text('D')));
      await bob.engine.sync();
      await carol.engine.sync();
      await alice.engine.sync();

      expect(server.compacted, {1});
      final late = await latecomer();
      expect(await alice.read(note), 'D');
      expect(await bob.read(note), 'D');
      expect(await carol.read(note), 'D');
      expect(await late.read(note), 'D');
    });
  });

  group('zero knowledge', () {
    test('neither the server nor the local database holds plaintext', () async {
      await alice.engine.write(note, RevisionContents(text('SEGRETISSIMO')));
      await alice.engine.sync();
      await bob.engine.sync();
      final stored = [...server.rows].map((row) => row.ciphertext.toBytes());
      final local = [
        ...alice.store.records.values,
        ...bob.store.records.values,
        for (final row in alice.store.outbox.pending) row.ciphertext.envelope,
      ].map((envelope) => envelope.toBytes());

      expect(
        [...stored, ...local].map(latin1.decode),
        everyElement(isNot(contains('SEGRETISSIMO'))),
      );
      expect(alice.store.records, isNotEmpty);
      expect(bob.store.records, isNotEmpty);
    });

    test('local records are bound to their id: swapping them fails', () async {
      await alice.engine.write(note, RevisionContents(text('una')));
      await alice.engine.write(other, RevisionContents(text('altra')));
      final a = alice.store.records[note]!;
      alice.store.records[note] = alice.store.records[other]!;
      alice.store.records[other] = a;

      await expectLater(
        alice.engine.read(note),
        throwsA(isA<AuthenticationTagMismatchException>()),
      );
    });
  });

  group('adversary', () {
    test(
      'the server swapping ciphertexts between records gains nothing',
      () async {
        await alice.engine.write(note, RevisionContents(text('nota')));
        await alice.engine.sync();
        server.rows[0] = SealedRow(
          record: other,
          ciphertext: server.rows[0].ciphertext,
        );

        final report = await bob.engine.sync();

        expect(report.rejected, 1);
        expect(await bob.read(other), isNull);
      },
    );

    test('a member cannot forge a revision in someone else\'s name', () async {
      await bob.engine.sync();
      final forged = SignedRevision(
        revision: RecordRevision(
          record: note,
          workspace: workspaceId,
          version: VersionVector.empty.increment(alice.id),
          author: alice.id,
          writtenAt: clock.now(),
          ledgerHead: bob.engine.ledgerHead,
          body: RevisionContents(text('falso')),
        ),
        signature: identities.sign(Uint8List(1), signer: bob.identity),
      );
      server.rows.add(
        SealedRow(record: note, ciphertext: bob.sealDirectly(forged)),
      );

      final report = await alice.engine.sync();

      expect(report.rejected, 1);
      expect(await alice.read(note), isNull);
    });

    test('a viewer with the GroupKey still cannot write', () async {
      final demoted = administration.changeRole(
        alice.engine.ledger,
        owner: alice.identity,
        member: bob.id,
        role: Role.viewer,
      );
      publish(demoted);
      await bob.engine.sync();
      await alice.engine.sync();

      // Bob bypasses his own client's check and signs a revision himself.
      final revision = RecordRevision(
        record: note,
        workspace: workspaceId,
        version: VersionVector.empty.increment(bob.id),
        author: bob.id,
        writtenAt: clock.now(),
        ledgerHead: bob.engine.ledgerHead,
        body: RevisionContents(text('da viewer')),
      );
      server.rows.add(
        SealedRow(
          record: note,
          ciphertext: bob.sealDirectly(
            SignedRevision(
              revision: revision,
              signature: identities.sign(
                revision.signable,
                signer: bob.identity,
              ),
            ),
          ),
        ),
      );

      final report = await alice.engine.sync();

      expect(report.rejected, 1);
      expect(await alice.read(note), isNull);
    });

    test(
      'a revoked member\'s later writes are refused, old key or not',
      () async {
        final bobsOldLedgerHead = bob.engine.ledgerHead;
        final revoked = administration.revoke(
          alice.engine.ledger,
          alice.keyring,
          owner: alice.identity,
          member: bob.id,
        );
        publish(revoked);
        await alice.engine.sync();

        // Bob writes as if nothing happened: old ledger head, epoch-0 key.
        final revision = RecordRevision(
          record: note,
          workspace: workspaceId,
          version: VersionVector.empty.increment(bob.id),
          author: bob.id,
          writtenAt: clock.now(),
          ledgerHead: bobsOldLedgerHead,
          body: RevisionContents(text('dopo la revoca')),
        );
        server.rows.add(
          SealedRow(
            record: note,
            ciphertext: bob.sealDirectly(
              SignedRevision(
                revision: revision,
                signature: identities.sign(
                  revision.signable,
                  signer: bob.identity,
                ),
              ),
            ),
          ),
        );

        final report = await alice.engine.sync();

        expect(report.rejected, 1);
        expect(await alice.read(note), isNull);
      },
    );

    test(
      'after a rotation, nothing new is accepted under the old key',
      () async {
        final revoked = administration.revoke(
          alice.engine.ledger,
          alice.keyring,
          owner: alice.identity,
          member: bob.id,
        );
        publish(revoked);
        await alice.engine.sync();

        // A buggy or malicious client of a current member seals a revision
        // written after the rotation under epoch 0, which Bob still holds.
        final revision = RecordRevision(
          record: note,
          workspace: workspaceId,
          version: VersionVector.empty.increment(alice.id),
          author: alice.id,
          writtenAt: clock.now(),
          ledgerHead: alice.engine.ledgerHead,
          body: RevisionContents(text('leggibile da Bob')),
        );
        server.rows.add(
          SealedRow(
            record: note,
            ciphertext: alice.sealDirectly(
              SignedRevision(
                revision: revision,
                signature: identities.sign(
                  revision.signable,
                  signer: alice.identity,
                ),
              ),
              epoch: KeyEpoch.initial,
            ),
          ),
        );

        final report = await alice.engine.sync();

        expect(report.rejected, 1);
        expect(await alice.read(note), isNull);
      },
    );

    test('a removed member pulling new revisions cannot open them', () async {
      final revoked = administration.revoke(
        alice.engine.ledger,
        alice.keyring,
        owner: alice.identity,
        member: bob.id,
      );
      publish(revoked);
      await alice.engine.sync();
      await alice.engine.write(note, RevisionContents(text('dopo')));
      await alice.engine.sync();

      final report = await bob.engine.sync();

      expect(report.undecryptable, 1);
      expect(await bob.read(note), isNull);
    });

    test(
      'a server hiding membership records that a writer saw is caught',
      () async {
        final carol = identities.generateIdentity();
        addTearDown(carol.dispose);
        final invitedCarol = administration.invite(
          alice.engine.ledger,
          alice.keyring,
          owner: alice.identity,
          invitee: carol.publicIdentity,
          role: Role.viewer,
        );
        publish(invitedCarol);
        await alice.engine.sync();
        await alice.engine.write(note, RevisionContents(text('dopo Carol')));
        await alice.engine.sync();

        // The server now shows Bob a log without Carol's invitation.
        server.withholdMembershipAfter = 2;

        await expectLater(
          bob.engine.sync(),
          throwsA(isA<LedgerRollbackException>()),
        );
        expect(await bob.read(note), isNull);
      },
    );

    test('a fork of the membership log is caught', () async {
      final revision = RecordRevision(
        record: note,
        workspace: workspaceId,
        version: VersionVector.empty.increment(alice.id),
        author: alice.id,
        writtenAt: clock.now(),
        ledgerHead: LedgerHead(
          sequence: alice.engine.ledgerHead.sequence,
          signature: identities.sign(Uint8List(1), signer: alice.identity),
        ),
        body: RevisionContents(text('altra storia')),
      );
      server.rows.add(
        SealedRow(
          record: note,
          ciphertext: alice.sealDirectly(
            SignedRevision(
              revision: revision,
              signature: identities.sign(
                revision.signable,
                signer: alice.identity,
              ),
            ),
          ),
        ),
      );

      await expectLater(
        bob.engine.sync(),
        throwsA(isA<LedgerRollbackException>()),
      );
    });

    test(
      'garbage rows are counted and skipped, never crash the sync',
      () async {
        server.rows.add(
          SealedRow(
            record: note,
            ciphertext: WorkspaceCiphertext(
              epoch: KeyEpoch.initial,
              envelope: EncryptedEnvelope(
                nonce: Nonce.fromBytes(Uint8List(Nonce.length)),
                ciphertext: Uint8List(40),
              ),
            ),
          ),
        );
        await alice.engine.write(other, RevisionContents(text('valida')));
        await alice.engine.sync();

        final report = await bob.engine.sync();

        expect(report.rejected, 1);
        expect(await bob.read(other), 'valida');
      },
    );
  });
}
