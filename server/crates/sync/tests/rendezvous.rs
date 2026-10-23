mod support;

use crypto::StrictEd25519;
use support::*;
use sync::{Denied, MemoryStore, Rendezvous, RendezvousError};

const LOOKUP: &str = "/api/codes/ABCDEF";

fn rendezvous() -> Rendezvous<MemoryStore, StrictEd25519> {
    Rendezvous::new(MemoryStore::default(), StrictEd25519)
}

#[test]
fn an_offer_keeps_its_lookup_until_it_expires() {
    let alice = Device::new(1);
    let mallory = Device::new(9);
    let mut code = rendezvous();
    code.post_offer(alice.member(), WS, b"sealed offer", NOW).unwrap();

    assert_eq!(code.post_offer(mallory.member(), WS, b"theirs", NOW + 1), Err(RendezvousError::Conflict));
    assert_eq!(code.offer(NOW + 1), Ok(b"sealed offer".to_vec()));
    let expired = NOW + 15 * 60 * 1000;
    assert_eq!(code.offer(expired), Err(RendezvousError::NotFound));
    assert_eq!(code.expires_ms(), Ok(Some(expired)));
    code.post_offer(mallory.member(), WS, b"theirs", expired).unwrap();
}

#[test]
fn at_most_eight_answers_and_only_the_poster_reads_them() {
    let alice = Device::new(1);
    let mallory = Device::new(9);
    let mut code = rendezvous();
    code.post_offer(alice.member(), WS, b"offer", NOW).unwrap();
    for i in 0..8u8 {
        code.post_answer(&[i], NOW).unwrap();
    }

    assert_eq!(code.post_answer(b"ninth", NOW), Err(RendezvousError::Full));
    assert_eq!(
        code.answers(&call(&mallory, "GET", &format!("{LOOKUP}/answers"), b"").request()),
        Err(RendezvousError::Denied(Denied::Forbidden))
    );
    let answers = code.answers(&call(&alice, "GET", &format!("{LOOKUP}/answers"), b"").request()).unwrap();
    assert_eq!(answers, (0..8u8).map(|i| vec![i]).collect::<Vec<_>>());
}

#[test]
fn the_poster_closes_and_an_answer_without_an_offer_has_nowhere_to_go() {
    let alice = Device::new(1);
    let mut code = rendezvous();

    assert_eq!(code.post_answer(b"early", NOW), Err(RendezvousError::NotFound));
    code.post_offer(alice.member(), WS, b"offer", NOW).unwrap();
    code.close(&call(&alice, "DELETE", LOOKUP, b"").request()).unwrap();
    assert_eq!(code.offer(NOW), Err(RendezvousError::NotFound));
}

#[test]
fn an_expired_offer_is_forgotten_with_its_answers() {
    let alice = Device::new(1);
    let mut code = rendezvous();
    code.post_offer(alice.member(), WS, b"offer", NOW).unwrap();
    code.post_answer(b"answer", NOW).unwrap();

    assert_eq!(code.expire(NOW + 1), Ok(false));
    assert_eq!(code.expire(NOW + 15 * 60 * 1000), Ok(true));
    assert_eq!(code.expires_ms(), Ok(None));
}

#[test]
fn empty_or_oversized_messages_are_malformed() {
    let alice = Device::new(1);
    let mut code = rendezvous();

    assert_eq!(code.post_offer(alice.member(), WS, b"", NOW), Err(RendezvousError::Malformed));
    assert_eq!(code.post_offer(alice.member(), WS, &[0; 8193], NOW), Err(RendezvousError::Malformed));
}
