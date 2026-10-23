//! Who is calling: a request counts only with a valid `MN1` signature, made
//! within [`SKEW_MS`] of the server's clock, by a key the workspace then
//! looks up in its verified log. A write's nonce is remembered for as long
//! as its time is accepted, so a captured write cannot be sent again.

use ledger::{Credential, MemberKey, SignatureCheck, signable_request};

use crate::store::{Store, Unavailable};

/// How far a device's clock may be from the server's. A refusal for time
/// tells the device the server's, and it signs again with the difference.
pub const SKEW_MS: u64 = 120_000;
const NONCES: &str = "nonce/";

/// The parts of an HTTP request that are signed.
#[derive(Clone, Copy, Debug)]
pub struct Request<'a> {
    pub method: &'a str,
    /// With the query, exactly as sent.
    pub path: &'a str,
    pub authorization: Option<&'a str>,
    /// BLAKE2b-256 of the body.
    pub body_digest: [u8; 32],
    pub now_ms: u64,
}

impl Request<'_> {
    /// Reads change nothing, so sending one again gains nothing.
    pub fn writes(&self) -> bool {
        self.method != "GET"
    }
}

/// A key that signed this very request.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Caller {
    pub key: MemberKey,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Denied {
    /// No valid signature (401).
    Unauthenticated,
    /// Signed too far from the server's time (401, with the server's).
    Clock,
    /// A write sent a second time (401).
    Replayed,
    /// Signed, but not by a member who may do this (403).
    Forbidden,
    Unavailable,
}

impl From<Unavailable> for Denied {
    fn from(_: Unavailable) -> Self {
        Self::Unavailable
    }
}

/// Checks the signature and the time, and remembers a write's nonce.
pub fn authenticate(
    store: &mut impl Store,
    check: &impl SignatureCheck,
    request: &Request<'_>,
) -> Result<Caller, Denied> {
    let credential = request.authorization.and_then(Credential::parse).ok_or(Denied::Unauthenticated)?;
    if credential.millis.abs_diff(request.now_ms) > SKEW_MS {
        return Err(Denied::Clock);
    }
    let signable =
        signable_request(request.method, request.path, credential.millis, &credential.nonce, &request.body_digest)
            .map_err(|_| Denied::Unauthenticated)?;
    if !check.verifies(&credential.key, &signable, &credential.signature) {
        return Err(Denied::Unauthenticated);
    }
    if request.writes() {
        remember_nonce(store, &credential.nonce, request.now_ms)?;
    }
    Ok(Caller { key: credential.key })
}

fn remember_nonce(store: &mut impl Store, nonce: &[u8; 16], now_ms: u64) -> Result<(), Denied> {
    for (key, expiry) in store.list(NONCES, None, usize::MAX)? {
        if decode_u64(&expiry) < now_ms {
            store.delete(&key)?;
        }
    }
    let key = format!("{NONCES}{}", ledger_hex(nonce));
    if store.get(&key)?.is_some() {
        return Err(Denied::Replayed);
    }
    // Twice the skew: a signed time can be up to SKEW_MS ahead of now.
    store.put(&key, &(now_ms + 2 * SKEW_MS).to_be_bytes())?;
    Ok(())
}

pub(crate) fn decode_u64(bytes: &[u8]) -> u64 {
    bytes.try_into().map(u64::from_be_bytes).unwrap_or(0)
}

pub(crate) fn ledger_hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}
