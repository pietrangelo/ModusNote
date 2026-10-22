mod support;

use ledger::{Refused, WorkspaceId};
use support::*;
use sync::{Denied, Heads, Limits, PushedRow, SKEW_MS, SyncError};

const OWNER: u8 = 1;
const EDITOR: u8 = 2;
const VIEWER: u8 = 3;

fn forbidden<T: std::fmt::Debug>(outcome: Result<T, SyncError>) {
    assert_eq!(outcome.unwrap_err(), SyncError::Denied(Denied::Forbidden));
}

/// Alice founds, then invites Bob with `role`.
fn with_bob(role: u8, limits: Limits) -> (Space, Device, Device, Vec<u8>) {
    let alice = Device::new(1);
    let bob = Device::new(2);
    let (mut space, genesis) = founded(&alice, limits);
    let invite = record(WS, 1, &alice, Some(signature_of(&genesis)), Change::Invited(&bob, role));
    space.append_record(&call(&alice, "POST", &path("/membership"), &invite).request(), &invite).unwrap();
    (space, alice, bob, invite)
}

fn row(record: u8, size: usize, supersedes: u64) -> PushedRow {
    PushedRow { record: [record; 16], ciphertext: vec![0xc1; size], supersedes }
}

mod founding {
    use super::*;

    #[test]
    fn the_founder_registers_once_and_the_same_record_again_is_fine() {
        let alice = Device::new(1);
        let (mut space, genesis) = founded(&alice, Limits::default());
        let again = call(&alice, "POST", &path(""), &genesis);

        assert_eq!(space.found(&again.request(), WS, &genesis), Ok(false));
        let heads = space.heads(&call(&alice, "GET", &path("/heads"), b"").request()).unwrap();
        assert_eq!(heads, Heads { rows: 0, bundles: 0, membership: 1 });
    }

    #[test]
    fn another_first_record_cannot_take_the_id() {
        let alice = Device::new(1);
        let mallory = Device::new(9);
        let (mut space, _) = founded(&alice, Limits::default());
        let theirs = record(WS, 0, &mallory, None, Change::Founded(&mallory));

        assert_eq!(
            space.found(&call(&mallory, "POST", &path(""), &theirs).request(), WS, &theirs),
            Err(SyncError::Conflict)
        );
    }

    #[test]
    fn only_the_founder_named_in_the_record_registers_it() {
        let alice = Device::new(1);
        let mallory = Device::new(9);
        let genesis = record(WS, 0, &alice, None, Change::Founded(&alice));
        let mut space = space(Limits::default());

        forbidden(space.found(&call(&mallory, "POST", &path(""), &genesis).request(), WS, &genesis));
        let other = WorkspaceId([7; 16]);
        assert_eq!(
            space.found(&call(&alice, "POST", &path(""), &genesis).request(), other, &genesis),
            Err(SyncError::Malformed("record of another workspace"))
        );
    }

    #[test]
    fn a_first_record_founding_someone_else_is_refused() {
        let alice = Device::new(1);
        let bob = Device::new(2);
        let genesis = record(WS, 0, &alice, None, Change::Founded(&bob));
        let mut space = space(Limits::default());

        assert!(matches!(
            space.found(&call(&alice, "POST", &path(""), &genesis).request(), WS, &genesis),
            Err(SyncError::Refused(Refused::Tampered(_)))
        ));
    }
}

mod who_may_call {
    use super::*;

    #[test]
    fn an_unknown_workspace_is_not_found() {
        let alice = Device::new(1);
        let mut space = space(Limits::default());

        assert_eq!(space.heads(&call(&alice, "GET", &path("/heads"), b"").request()), Err(SyncError::NotFound));
    }

    #[test]
    fn someone_outside_the_log_is_forbidden_even_with_a_valid_signature() {
        let alice = Device::new(1);
        let mallory = Device::new(9);
        let (mut space, _) = founded(&alice, Limits::default());

        forbidden(space.pull(&call(&mallory, "GET", &path("/rows?after=0"), b"").request(), 0));
    }

    #[test]
    fn no_signature_or_a_wrong_one_is_unauthenticated() {
        let alice = Device::new(1);
        let (mut space, _) = founded(&alice, Limits::default());
        let mut unsigned = call(&alice, "GET", &path("/heads"), b"");
        unsigned.header = None;
        let mut other_path = call(&alice, "GET", &path("/heads"), b"");
        other_path.path = path("/rows?after=0");
        let mut other_body = call(&alice, "POST", &path("/rows"), b"{}");
        other_body.digest[0] ^= 1;

        for call in [unsigned, other_path, other_body] {
            assert_eq!(space.heads(&call.request()), Err(SyncError::Denied(Denied::Unauthenticated)));
        }
    }

    #[test]
    fn a_clock_too_far_off_is_told_so() {
        let alice = Device::new(1);
        let (mut space, _) = founded(&alice, Limits::default());
        let late = call_at(&alice, "GET", &path("/heads"), b"", NOW - SKEW_MS - 1, NOW);
        let early = call_at(&alice, "GET", &path("/heads"), b"", NOW + SKEW_MS + 1, NOW);
        let edge = call_at(&alice, "GET", &path("/heads"), b"", NOW - SKEW_MS, NOW);

        assert_eq!(space.heads(&late.request()), Err(SyncError::Denied(Denied::Clock)));
        assert_eq!(space.heads(&early.request()), Err(SyncError::Denied(Denied::Clock)));
        assert!(space.heads(&edge.request()).is_ok());
    }

    #[test]
    fn a_write_sent_again_is_refused_a_read_is_not() {
        let alice = Device::new(1);
        let (mut space, _) = founded(&alice, Limits::default());
        let push = call(&alice, "POST", &path("/rows"), b"rows");
        let read = call(&alice, "GET", &path("/heads"), b"");

        space.push(&push.request(), &[row(1, 10, 0)]).unwrap();
        assert_eq!(space.push(&push.request(), &[row(1, 10, 0)]), Err(SyncError::Denied(Denied::Replayed)));
        space.heads(&read.request()).unwrap();
        space.heads(&read.request()).unwrap();
    }

    #[test]
    fn remembered_nonces_are_forgotten_once_their_time_is_past() {
        let alice = Device::new(1);
        let (mut space, _) = founded(&alice, Limits::default());
        for i in 0..5 {
            let at = NOW + i * 3 * SKEW_MS;
            space.push(&call_at(&alice, "POST", &path("/rows"), b"r", at, at).request(), &[row(1, 10, 0)]).unwrap();
        }

        let nonces = space.store().keys().filter(|key| key.starts_with("nonce/")).count();
        assert_eq!(nonces, 1);
    }

    #[test]
    fn a_viewer_reads_but_does_not_write() {
        let (mut space, _, bob, _) = with_bob(VIEWER, Limits::default());

        space.pull(&call(&bob, "GET", &path("/rows?after=0"), b"").request(), 0).unwrap();
        forbidden(space.push(&call(&bob, "POST", &path("/rows"), b"r").request(), &[row(1, 10, 0)]));
        forbidden(space.reserve_blob(&call(&bob, "POST", &path("/blobs/a"), b"").request(), "a", 10));
        forbidden(space.release_blobs(&call(&bob, "DELETE", &path("/blobs"), b"").request(), &["a".into()]));
    }

    #[test]
    fn a_removed_member_is_out_with_the_next_request() {
        let (mut space, alice, bob, invite) = with_bob(EDITOR, Limits::default());
        space.push(&call(&bob, "POST", &path("/rows"), b"r").request(), &[row(1, 10, 0)]).unwrap();
        let revoke = record(WS, 2, &alice, Some(signature_of(&invite)), Change::Revoked(&bob));
        space.append_record(&call(&alice, "POST", &path("/membership"), &revoke).request(), &revoke).unwrap();

        forbidden(space.push(&call(&bob, "POST", &path("/rows"), b"r").request(), &[row(1, 10, 0)]));
        forbidden(space.pull(&call(&bob, "GET", &path("/rows?after=0"), b"").request(), 0));
        forbidden(space.heads(&call(&bob, "GET", &path("/heads"), b"").request()));
        // The log alone stays readable, so the device learns why.
        let log = space.membership(&call(&bob, "GET", &path("/membership?from=2"), b"").request(), 2).unwrap();
        assert_eq!(log, vec![revoke]);
    }

    #[test]
    fn a_stranger_reads_not_even_the_log() {
        let (mut space, _, _, _) = with_bob(EDITOR, Limits::default());
        let mallory = Device::new(9);

        forbidden(space.membership(&call(&mallory, "GET", &path("/membership?from=0"), b"").request(), 0));
    }

    #[test]
    fn only_an_owner_deletes_the_workspace() {
        let (mut space, alice, bob, _) = with_bob(EDITOR, Limits::default());

        forbidden(space.delete(&call(&bob, "DELETE", &path(""), b"").request()));
        space.delete(&call(&alice, "DELETE", &path(""), b"").request()).unwrap();
        assert!(space.store().is_empty());
        assert_eq!(space.heads(&call(&alice, "GET", &path("/heads"), b"").request()), Err(SyncError::NotFound));
    }
}

mod membership_log {
    use super::*;

    #[test]
    fn records_extend_the_verified_log_and_come_back_as_sent() {
        let (mut space, alice, bob, invite) = with_bob(EDITOR, Limits::default());

        let records = space.membership(&call(&bob, "GET", &path("/membership?from=1"), b"").request(), 1).unwrap();
        assert_eq!(records, vec![invite]);
        let heads = space.heads(&call(&alice, "GET", &path("/heads"), b"").request()).unwrap();
        assert_eq!(heads.membership, 2);
    }

    #[test]
    fn a_record_against_the_rules_never_enters() {
        let (mut space, _, bob, invite) = with_bob(EDITOR, Limits::default());
        let mallory = Device::new(9);
        let by_editor = record(WS, 2, &bob, Some(signature_of(&invite)), Change::Invited(&mallory, OWNER));

        assert!(matches!(
            space.append_record(&call(&bob, "POST", &path("/membership"), &by_editor).request(), &by_editor),
            Err(SyncError::Refused(Refused::Tampered(_)))
        ));
        let heads = space.heads(&call(&bob, "GET", &path("/heads"), b"").request()).unwrap();
        assert_eq!(heads.membership, 2);
    }

    #[test]
    fn a_record_that_does_not_parse_or_does_not_chain_is_refused() {
        let (mut space, alice, _, invite) = with_bob(EDITOR, Limits::default());
        let carol = Device::new(3);
        let unchained = record(WS, 2, &alice, Some([0; 64]), Change::Invited(&carol, VIEWER));
        let mut bad_signature = record(WS, 2, &alice, Some(signature_of(&invite)), Change::Invited(&carol, VIEWER));
        let last = bad_signature.len() - 1;
        bad_signature[last] ^= 1;

        for wire in [vec![1, 2, 3], unchained, bad_signature] {
            assert!(matches!(
                space.append_record(&call(&alice, "POST", &path("/membership"), &wire).request(), &wire),
                Err(SyncError::Refused(_))
            ));
        }
    }

    #[test]
    fn a_sequence_already_held_is_a_conflict() {
        let (mut space, alice, _, invite) = with_bob(EDITOR, Limits::default());

        assert_eq!(
            space.append_record(&call(&alice, "POST", &path("/membership"), &invite).request(), &invite),
            Err(SyncError::Conflict)
        );
    }
}

mod key_bundles {
    use super::*;

    #[test]
    fn a_genuine_bundle_gets_the_next_position() {
        let (mut space, alice, bob, _) = with_bob(EDITOR, Limits::default());
        let first = bundle(WS, 0, &alice, &[(0, &alice)]);
        let second = bundle(WS, 1, &alice, &[(0, &bob)]);

        assert_eq!(space.append_bundle(&call(&alice, "POST", &path("/bundles"), &first).request(), &first), Ok(1));
        assert_eq!(space.append_bundle(&call(&alice, "POST", &path("/bundles"), &second).request(), &second), Ok(2));
        let listed = space.bundles(&call(&bob, "GET", &path("/bundles?after=1"), b"").request(), 1).unwrap();
        assert_eq!(listed, (vec![(2, second)], false));
    }

    #[test]
    fn bundles_come_a_page_at_a_time() {
        let limits = Limits { pull_rows: 2, ..Limits::default() };
        let (mut space, alice, _, _) = with_bob(EDITOR, limits);
        for _ in 0..3 {
            let wire = bundle(WS, 1, &alice, &[(0, &alice)]);
            space.append_bundle(&call(&alice, "POST", &path("/bundles"), &wire).request(), &wire).unwrap();
        }

        let get = |after: u64| call(&alice, "GET", &path(&format!("/bundles?after={after}")), b"");
        let (first, more) = space.bundles(&get(0).request(), 0).unwrap();
        assert_eq!((first.iter().map(|(p, _)| *p).collect::<Vec<_>>(), more), (vec![1, 2], true));
        let (rest, more) = space.bundles(&get(2).request(), 2).unwrap();
        assert_eq!((rest.iter().map(|(p, _)| *p).collect::<Vec<_>>(), more), (vec![3], false));
    }

    #[test]
    fn adversary_a_bundle_naming_a_record_the_log_does_not_have_never_enters() {
        // The attack of 2026-10-22: one such bundle held back every bundle
        // after it, on every device, without an error.
        let (mut space, alice, _, _) = with_bob(OWNER, Limits::default());
        let beyond = bundle(WS, 0xffff_ffff, &alice, &[]);

        assert_eq!(
            space.append_bundle(&call(&alice, "POST", &path("/bundles"), &beyond).request(), &beyond),
            Err(SyncError::Refused(Refused::Tampered("unknown log position")))
        );
    }

    #[test]
    fn bundles_from_an_editor_or_beyond_the_epoch_never_enter() {
        let (mut space, alice, bob, _) = with_bob(EDITOR, Limits::default());
        let by_editor = bundle(WS, 1, &bob, &[(0, &bob)]);
        let ahead = bundle(WS, 1, &alice, &[(1, &bob)]);
        let to_stranger = bundle(WS, 1, &alice, &[(0, &Device::new(9))]);

        for wire in [by_editor, ahead, to_stranger] {
            assert!(matches!(
                space.append_bundle(&call(&alice, "POST", &path("/bundles"), &wire).request(), &wire),
                Err(SyncError::Refused(Refused::Tampered(_)))
            ));
        }
    }
}

mod rows {
    use super::*;

    #[test]
    fn rows_come_back_in_order_after_the_cursor() {
        let alice = Device::new(1);
        let (mut space, _) = founded(&alice, Limits::default());
        let positions =
            space.push(&call(&alice, "POST", &path("/rows"), b"r").request(), &[row(1, 10, 0), row(2, 20, 0)]).unwrap();

        assert_eq!(positions, vec![1, 2]);
        let (rows, more) = space.pull(&call(&alice, "GET", &path("/rows?after=1"), b"").request(), 1).unwrap();
        assert!(!more);
        assert_eq!(rows.len(), 1);
        assert_eq!((rows[0].position, rows[0].record, rows[0].ciphertext.len()), (2, [2; 16], 20));
    }

    #[test]
    fn a_row_drops_the_rows_of_its_record_it_supersedes_and_only_those() {
        let alice = Device::new(1);
        let (mut space, _) = founded(&alice, Limits::default());
        let push = |space: &mut Space, rows: &[PushedRow]| {
            space.push(&call(&alice, "POST", &path("/rows"), b"r").request(), rows).unwrap()
        };
        push(&mut space, &[row(1, 10, 0), row(2, 10, 0), row(1, 10, 0)]);
        // Supersedes up to 9: only rows of record 1 below its own position go.
        push(&mut space, &[row(1, 10, 9)]);

        let (rows, _) = space.pull(&call(&alice, "GET", &path("/rows?after=0"), b"").request(), 0).unwrap();
        let left: Vec<(u64, u8)> = rows.iter().map(|row| (row.position, row.record[0])).collect();
        assert_eq!(left, vec![(2, 2), (4, 1)]);
        assert!(!space.store().keys().any(|key| key.contains("/0000000000000001")));
    }

    #[test]
    fn the_quota_counts_what_is_kept_so_an_edit_passes_when_full() {
        let limits = Limits { workspace_bytes: 2_000, ..Limits::default() };
        let alice = Device::new(1);
        let (mut space, genesis) = founded(&alice, limits);
        let room = 2_000 - genesis.len() - 16;
        space.push(&call(&alice, "POST", &path("/rows"), b"r").request(), &[row(1, room, 0)]).unwrap();

        assert_eq!(
            space.push(&call(&alice, "POST", &path("/rows"), b"r").request(), &[row(2, 1, 0)]),
            Err(SyncError::Full)
        );
        space.push(&call(&alice, "POST", &path("/rows"), b"r").request(), &[row(1, room, 1)]).unwrap();
        let (rows, _) = space.pull(&call(&alice, "GET", &path("/rows?after=0"), b"").request(), 0).unwrap();
        // The refused push took no position.
        assert_eq!(rows.iter().map(|row| row.position).collect::<Vec<_>>(), vec![2]);
    }

    #[test]
    fn a_refused_push_leaves_nothing_behind() {
        let limits = Limits { workspace_bytes: 1_500, ..Limits::default() };
        let alice = Device::new(1);
        let (mut space, _) = founded(&alice, limits);
        let before: Vec<String> = space.store().keys().filter(|k| !k.starts_with("nonce/")).cloned().collect();

        assert_eq!(
            space.push(&call(&alice, "POST", &path("/rows"), b"r").request(), &[row(1, 10, 0), row(2, 2_000, 0)]),
            Err(SyncError::Full)
        );
        let after: Vec<String> = space.store().keys().filter(|k| !k.starts_with("nonce/")).cloned().collect();
        assert_eq!(after, before);
    }

    #[test]
    fn pulls_come_in_pages() {
        let limits = Limits { pull_rows: 2, pull_bytes: 100, ..Limits::default() };
        let alice = Device::new(1);
        let (mut space, _) = founded(&alice, limits);
        space
            .push(&call(&alice, "POST", &path("/rows"), b"r").request(), &[row(1, 10, 0), row(2, 10, 0), row(3, 90, 0)])
            .unwrap();

        let (first, more) = space.pull(&call(&alice, "GET", &path("/rows?after=0"), b"").request(), 0).unwrap();
        assert_eq!((first.len(), more), (2, true));
        let (second, more) = space.pull(&call(&alice, "GET", &path("/rows?after=2"), b"").request(), 2).unwrap();
        assert_eq!((second.len(), more), (1, false));
    }

    #[test]
    fn empty_oversized_or_too_many_rows_are_malformed() {
        let limits = Limits { row_bytes: 100, rows_per_push: 2, ..Limits::default() };
        let alice = Device::new(1);
        let (mut space, _) = founded(&alice, limits);

        for rows in [vec![], vec![row(1, 0, 0)], vec![row(1, 101, 0)], vec![row(1, 1, 0); 3]] {
            assert!(matches!(
                space.push(&call(&alice, "POST", &path("/rows"), b"r").request(), &rows),
                Err(SyncError::Malformed(_))
            ));
        }
    }
}

mod blobs {
    use super::*;

    #[test]
    fn a_blob_counts_once_against_space_and_the_days_budget() {
        let limits = Limits { workspace_blob_bytes: 100, daily_upload_bytes: 60, ..Limits::default() };
        let alice = Device::new(1);
        let (mut space, _) = founded(&alice, limits);
        let reserve = |space: &mut Space, id: &str, size| {
            space.reserve_blob(&call(&alice, "POST", &path("/blobs"), b"").request(), id, size)
        };

        assert_eq!(reserve(&mut space, "a", 50), Ok(true));
        assert_eq!(reserve(&mut space, "a", 50), Ok(false));
        assert_eq!(reserve(&mut space, "a", 51), Err(SyncError::Conflict), "another size was never counted");
        assert_eq!(reserve(&mut space, "b", 20), Err(SyncError::Throttled));
        let tomorrow = NOW + 86_400_000;
        let next_day = call_at(&alice, "POST", &path("/blobs"), b"", tomorrow, tomorrow);
        assert_eq!(space.reserve_blob(&next_day.request(), "b", 50), Ok(true));
        let later = call_at(&alice, "POST", &path("/blobs"), b"", tomorrow, tomorrow);
        assert_eq!(space.reserve_blob(&later.request(), "c", 1), Err(SyncError::Full));
    }

    #[test]
    fn released_blobs_give_their_space_back_and_leave_the_listing() {
        let limits = Limits { workspace_blob_bytes: 100, ..Limits::default() };
        let alice = Device::new(1);
        let (mut space, _) = founded(&alice, limits);
        space.reserve_blob(&call(&alice, "POST", &path("/blobs"), b"").request(), "a", 100).unwrap();
        space
            .release_blobs(&call(&alice, "DELETE", &path("/blobs"), b"").request(), &["a".into(), "zz".into()])
            .unwrap();

        assert_eq!(space.reserve_blob(&call(&alice, "POST", &path("/blobs"), b"").request(), "b", 100), Ok(true));
        let (listed, more) = space.blobs(&call(&alice, "GET", &path("/blobs"), b"").request(), None).unwrap();
        assert!(!more);
        assert_eq!(listed.iter().map(|b| b.id.as_str()).collect::<Vec<_>>(), vec!["b"]);
        assert_eq!((listed[0].size, listed[0].uploaded_ms), (100, NOW));
    }

    #[test]
    fn ids_and_sizes_out_of_shape_are_refused() {
        let alice = Device::new(1);
        let (mut space, _) = founded(&alice, Limits::default());
        let too_big = Limits::default().blob_bytes + 1;

        for (id, size) in [("../x", 1), ("", 1), ("a", 0), ("a", too_big)] {
            assert!(space.reserve_blob(&call(&alice, "POST", &path("/blobs"), b"").request(), id, size).is_err());
        }
    }
}

mod retention {
    use super::*;

    #[test]
    fn a_workspace_nobody_uses_deletes_itself() {
        let limits = Limits { idle_days: 10, ..Limits::default() };
        let alice = Device::new(1);
        let (mut space, _) = founded(&alice, limits);

        assert_eq!(space.expire(NOW + 9 * 86_400_000), Ok(false));
        assert_eq!(space.expire(NOW + 10 * 86_400_000), Ok(true));
        assert!(space.store().is_empty());
    }

    #[test]
    fn a_signed_request_keeps_it_alive() {
        let limits = Limits { idle_days: 10, ..Limits::default() };
        let alice = Device::new(1);
        let (mut space, _) = founded(&alice, limits);
        let later = NOW + 9 * 86_400_000;
        space.heads(&call_at(&alice, "GET", &path("/heads"), b"", later, later).request()).unwrap();

        assert_eq!(space.expire(NOW + 10 * 86_400_000), Ok(false));
        assert_eq!(space.last_seen_ms(), Ok(Some(later)));
    }
}
