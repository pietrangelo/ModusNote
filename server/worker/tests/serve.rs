//! The objects' side of the HTTP surface, on stores in memory: JSON in,
//! use case, JSON out, as `runtime` will run it inside Durable Objects.

#[path = "../../crates/sync/tests/support/mod.rs"]
mod support;

use crypto::StrictEd25519;
use ledger::MemberKey;
use modusnote_server::api::{ApiError, Route};
use modusnote_server::serve::{self, Blake2b, Done, INTERNAL_OFFER, INTERNAL_SPEND, Incoming};
use serde_json::{Value, json};
use support::*;
use sync::{Budget, Guard, Hasher, Limits, MemoryStore, PowPurpose, Rendezvous, pow_satisfied};

/// A call `by` signs, as the object receives it.
fn send<'a>(signed: &'a Call, body: &'a [u8], blob_size: Option<&'a str>) -> Incoming<'a> {
    let (path, query) = match signed.path.split_once('?') {
        Some((path, query)) => (path, Some(query)),
        None => (signed.path.as_str(), None),
    };
    Incoming {
        method: &signed.method,
        path,
        query,
        authorization: signed.header.as_deref(),
        body,
        blob_size,
        now_ms: NOW,
    }
}

fn serve_json(space: &mut Space, by: &Device, method: &str, target: &str, body: Value) -> Result<Done, ApiError> {
    let body = if body.is_null() { Vec::new() } else { body.to_string().into_bytes() };
    let signed = call(by, method, target, &body);
    serve::workspace(space, &Blake2b, &send(&signed, &body, None))
}

fn parsed(done: Done) -> (u16, Value) {
    match done {
        Done::Json(status, text) => (status, serde_json::from_str(&text).unwrap()),
        other => panic!("not JSON: {other:?}"),
    }
}

fn b64(bytes: &[u8]) -> String {
    modusnote_server::api::encode(bytes)
}

fn founded_by(alice: &Device) -> Space {
    let mut space = space(Limits::default());
    let genesis = record(WS, 0, alice, None, Change::Founded(alice));
    let found = json!({"record": b64(&genesis), "pow": {"day": 0, "nonce": b64(&[0; 16])}});
    assert_eq!(parsed(serve_json(&mut space, alice, "POST", &path(""), found.clone()).unwrap()).0, 201);
    let (status, body) = parsed(serve_json(&mut space, alice, "POST", &path(""), found).unwrap());
    assert_eq!((status, body), (200, json!({"created": false})));
    space
}

#[test]
fn rows_go_in_and_come_out_as_json() {
    let alice = Device::new(1);
    let mut space = founded_by(&alice);
    let record = hex::encode([7u8; 16]);
    let push = json!({"rows": [{"record": record, "ciphertext": b64(b"sealed"), "supersedes": 0}]});

    let (status, pushed) = parsed(serve_json(&mut space, &alice, "POST", &path("/rows"), push).unwrap());
    assert_eq!((status, pushed), (201, json!({"positions": [1]})));
    let (_, pulled) = parsed(serve_json(&mut space, &alice, "GET", &path("/rows?after=0"), Value::Null).unwrap());
    assert_eq!(
        pulled,
        json!({"rows": [{"position": 1, "record": record, "ciphertext": b64(b"sealed")}], "more": false})
    );
    let (_, heads) = parsed(serve_json(&mut space, &alice, "GET", &path("/heads"), Value::Null).unwrap());
    assert_eq!(heads, json!({"rows": 1, "bundles": 0, "membership": 1}));
    let (_, log) = parsed(serve_json(&mut space, &alice, "GET", &path("/membership?from=0"), Value::Null).unwrap());
    assert_eq!(log["records"].as_array().unwrap().len(), 1);
}

#[test]
fn a_signature_over_another_body_or_path_counts_for_nothing() {
    let alice = Device::new(1);
    let mut space = founded_by(&alice);
    let body = json!({"rows": []}).to_string().into_bytes();
    let signed = call(&alice, "POST", &path("/rows"), b"{}");

    let swapped = serve::workspace(&mut space, &Blake2b, &send(&signed, &body, None));
    assert_eq!(swapped, Err(ApiError::Unauthenticated));
    let elsewhere = call(&alice, "GET", &path("/heads"), b"");
    let moved = Incoming { path: &path("/rows"), query: Some("after=0"), ..send(&elsewhere, b"", None) };
    assert_eq!(serve::workspace(&mut space, &Blake2b, &moved), Err(ApiError::Unauthenticated));
}

#[test]
fn a_blob_is_reserved_with_its_size_listed_and_released() {
    let alice = Device::new(1);
    let mut space = founded_by(&alice);
    let put = call(&alice, "PUT", &path("/blobs/b1"), b"");

    assert_eq!(serve::workspace(&mut space, &Blake2b, &send(&put, b"", None)), Err(ApiError::LengthRequired));
    let again = call(&alice, "PUT", &path("/blobs/b1"), b"");
    assert_eq!(serve::workspace(&mut space, &Blake2b, &send(&again, b"", Some("40"))).map(parsed).unwrap().0, 200);
    let (_, listed) = parsed(serve_json(&mut space, &alice, "GET", &path("/blobs"), Value::Null).unwrap());
    assert_eq!(listed, json!({"blobs": [{"id": "b1", "size": 40, "uploaded": NOW}]}));
    let read = call(&alice, "GET", &path("/blobs/b1"), b"");
    assert!(serve::workspace(&mut space, &Blake2b, &send(&read, b"", None)).is_ok());
    let released = serve_json(&mut space, &alice, "POST", &path("/blobs/delete"), json!({"ids": ["b1"]}));
    assert_eq!(released, Ok(Done::Released(vec!["b1".into()])));
}

#[test]
fn only_an_owner_posts_an_offer_and_only_they_read_the_answers() {
    let alice = Device::new(1);
    let bob = Device::new(2);
    let mut space = founded_by(&alice);
    let genesis = record(WS, 0, &alice, None, Change::Founded(&alice));
    let invite = record(WS, 1, &alice, Some(signature_of(&genesis)), Change::Invited(&bob, 2));
    serve_json(&mut space, &alice, "POST", &path("/membership"), json!({"record": b64(&invite)})).unwrap();
    let offer = json!({"offer": b64(b"sealed offer")});

    let refused = serve_json(&mut space, &bob, "POST", &path("/codes/ABC123"), offer.clone());
    assert_eq!(refused, Err(ApiError::Forbidden));
    let Done::Offer { poster, sealed } = serve_json(&mut space, &alice, "POST", &path("/codes/ABC123"), offer).unwrap()
    else {
        panic!("no offer")
    };
    assert_eq!((poster, sealed.as_slice()), (alice.member(), b"sealed offer".as_slice()));

    let mut meeting = Rendezvous::new(MemoryStore::default(), StrictEd25519);
    let handed = serve::offer_call(&poster, &WS, &sealed);
    let internal = Incoming {
        method: "POST",
        path: INTERNAL_OFFER,
        query: None,
        authorization: None,
        body: &handed,
        blob_size: None,
        now_ms: NOW,
    };
    assert_eq!(serve::rendezvous(&mut meeting, &Blake2b, &internal), Ok((201, "{}".into())));
    let anyone = Incoming { method: "GET", path: "/api/codes/ABC123", body: b"", ..internal };
    let (_, text) = serve::rendezvous(&mut meeting, &Blake2b, &anyone).unwrap();
    assert_eq!(text, json!({"offer": b64(b"sealed offer")}).to_string());
    let answer = json!({"answer": b64(b"sealed answer"), "pow": {"day": 0, "nonce": b64(&[0; 16])}}).to_string();
    let answering = Incoming { path: "/api/codes/ABC123/answers", body: answer.as_bytes(), ..internal };
    assert_eq!(serve::rendezvous(&mut meeting, &Blake2b, &answering).unwrap().0, 201);

    let by_bob = call(&bob, "GET", "/api/codes/ABC123/answers", b"");
    assert_eq!(serve::rendezvous(&mut meeting, &Blake2b, &send(&by_bob, b"", None)), Err(ApiError::Forbidden));
    let by_alice = call(&alice, "GET", "/api/codes/ABC123/answers", b"");
    let (_, answers) = serve::rendezvous(&mut meeting, &Blake2b, &send(&by_alice, b"", None)).unwrap();
    assert_eq!(answers, json!({"answers": [b64(b"sealed answer")]}).to_string());
    let posting_again = Incoming { body: &serve::offer_call(&MemberKey([9; 32]), &WS, b"x"), ..internal };
    assert_eq!(serve::rendezvous(&mut meeting, &Blake2b, &posting_again), Err(ApiError::Conflict));
}

#[test]
fn founding_and_answering_cost_a_proof_of_work_of_today() {
    const BITS: u32 = 8;
    let day = (NOW / 86_400_000) as u32;
    let lookup = "ABC123".to_owned();
    let mut nonce = [0u8; 16];
    while !pow_satisfied(&Blake2b, PowPurpose::Answer, lookup.as_bytes(), day, &nonce, BITS) {
        nonce[0] = nonce[0].wrapping_add(1);
        nonce[1] += u8::from(nonce[0] == 0);
    }
    let body = |day: u32, nonce: &[u8]| {
        json!({"answer": b64(b"a"), "pow": {"day": day, "nonce": b64(nonce)}}).to_string().into_bytes()
    };
    let answer = Route::Answer(lookup.clone());

    assert_eq!(serve::admit(&answer, &body(day, &nonce), &Blake2b, NOW, BITS), Ok(()));
    assert_eq!(serve::admit(&answer, &body(day - 2, &nonce), &Blake2b, NOW, BITS), Err(ApiError::Work));
    assert_eq!(serve::admit(&Route::Found(WS), &body(day, &nonce), &Blake2b, NOW, BITS), Err(ApiError::BadRequest));
    assert_eq!(serve::admit(&Route::Heads(WS), b"", &Blake2b, NOW, BITS), Ok(()));
    assert_eq!(Blake2b.blake2b_256(b""), crypto::blake2b_256(b""));
}

#[test]
fn the_guard_spends_through_its_internal_call() {
    let mut guard = Guard::new(MemoryStore::default());
    let body = serve::spend_call(Budget::UploadBytes, 60, 100);
    let spend = Incoming {
        method: "POST",
        path: INTERNAL_SPEND,
        query: None,
        authorization: None,
        body: &body,
        blob_size: None,
        now_ms: NOW,
    };

    assert_eq!(serve::guard(&mut guard, &spend), Ok(true));
    assert_eq!(serve::guard(&mut guard, &spend), Ok(false));
    assert_eq!(serve::guard(&mut guard, &Incoming { path: "/api/info", ..spend }), Err(ApiError::NotFound));
}
