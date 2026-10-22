//! Devices that sign records, bundles and requests as the Dart app does,
//! with keys derived from a seed so every run is the same.
#![allow(dead_code)]

use crypto::{StrictEd25519, blake2b_256};
use ed25519_dalek::{Signer, SigningKey};
use ledger::{ENCRYPTION_KEY_LENGTH, MemberKey, SEALED_KEY_LENGTH, WorkspaceId};
use sync::{Limits, MemoryStore, Request, Workspace};

pub const WS: WorkspaceId = WorkspaceId([0x6d; 16]);
pub const NOW: u64 = 1_792_700_000_000;

pub struct Device {
    pub key: SigningKey,
}

impl Device {
    pub fn new(seed: u8) -> Self {
        Self { key: SigningKey::from_bytes(&[seed; 32]) }
    }

    pub fn member(&self) -> MemberKey {
        MemberKey(self.key.verifying_key().to_bytes())
    }

    pub fn identity(&self) -> Vec<u8> {
        let mut identity = self.key.verifying_key().to_bytes().to_vec();
        identity.extend(std::iter::repeat_n(0x42, ENCRYPTION_KEY_LENGTH));
        identity
    }

    pub fn sign(&self, message: &[u8]) -> [u8; 64] {
        self.key.sign(message).to_bytes()
    }
}

pub enum Change<'a> {
    Founded(&'a Device),
    Invited(&'a Device, u8),
    Revoked(&'a Device),
    RoleChanged(&'a Device, u8),
}

/// A membership record as `MembershipRecord.toBytes` writes it.
pub fn record(
    ws: WorkspaceId,
    sequence: u32,
    author: &Device,
    previous: Option<[u8; 64]>,
    change: Change<'_>,
) -> Vec<u8> {
    let mut body = vec![1];
    body.extend_from_slice(&ws.0);
    body.extend_from_slice(&sequence.to_be_bytes());
    body.extend_from_slice(&author.member().0);
    match previous {
        None => body.push(0),
        Some(signature) => {
            body.push(1);
            body.extend_from_slice(&signature);
        }
    }
    match change {
        Change::Founded(founder) => {
            body.push(0);
            body.extend(founder.identity());
        }
        Change::Invited(invitee, role) => {
            body.push(1);
            body.extend(invitee.identity());
            body.push(role);
        }
        Change::Revoked(member) => {
            body.push(2);
            body.extend_from_slice(&member.member().0);
        }
        Change::RoleChanged(member, role) => {
            body.push(3);
            body.extend_from_slice(&member.member().0);
            body.push(role);
        }
    }
    let signature = author.sign(&[b"modusnote.membership.v1".as_slice(), &body].concat());
    body.extend_from_slice(&signature);
    body
}

pub fn signature_of(wire: &[u8]) -> [u8; 64] {
    wire[wire.len() - 64..].try_into().unwrap()
}

/// A key bundle as `KeyBundle.toBytes` writes it, with sealed keys that
/// only have the right shape: the server never opens them.
pub fn bundle(ws: WorkspaceId, at: u32, issuer: &Device, grants: &[(u32, &Device)]) -> Vec<u8> {
    let mut body = vec![1];
    body.extend_from_slice(&ws.0);
    body.extend_from_slice(&at.to_be_bytes());
    body.extend_from_slice(&issuer.member().0);
    body.extend_from_slice(&(grants.len() as u16).to_be_bytes());
    for (epoch, recipient) in grants {
        body.extend_from_slice(&epoch.to_be_bytes());
        body.extend_from_slice(&recipient.member().0);
        let mut sealed = vec![0x55; SEALED_KEY_LENGTH];
        sealed[1120] = 1;
        body.extend(sealed);
    }
    let signature = issuer.sign(&[b"modusnote.keybundle.v1".as_slice(), &body].concat());
    body.extend_from_slice(&signature);
    body
}

/// A request signed as `SignedRequest` and `RequestCredential` do.
pub struct Call {
    pub method: String,
    pub path: String,
    pub header: Option<String>,
    pub digest: [u8; 32],
    pub now: u64,
}

impl Call {
    pub fn request(&self) -> Request<'_> {
        Request {
            method: &self.method,
            path: &self.path,
            authorization: self.header.as_deref(),
            body_digest: self.digest,
            now_ms: self.now,
        }
    }
}

static NONCE: std::sync::atomic::AtomicU8 = std::sync::atomic::AtomicU8::new(0);

pub fn call(by: &Device, method: &str, path: &str, body: &[u8]) -> Call {
    call_at(by, method, path, body, NOW, NOW)
}

pub fn call_at(by: &Device, method: &str, path: &str, body: &[u8], signed_at: u64, now: u64) -> Call {
    let digest = blake2b_256(body);
    let mut nonce = [0u8; 16];
    nonce[0] = NONCE.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    nonce[1..].copy_from_slice(&by.member().0[..15]);
    let signable = ledger::signable_request(method, path, signed_at, &nonce, &digest).unwrap();
    let header = format!("MN1 {}.{}.{}.{}", b64(&by.member().0), signed_at, b64(&nonce), b64(&by.sign(&signable)));
    Call { method: method.into(), path: path.into(), header: Some(header), digest, now }
}

fn b64(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    let mut out = String::new();
    for chunk in bytes.chunks(3) {
        let n = chunk.iter().enumerate().fold(0u32, |n, (i, b)| n | u32::from(*b) << (16 - 8 * i));
        for i in 0..=chunk.len() {
            out.push(ALPHABET[(n >> (18 - 6 * i) & 63) as usize] as char);
        }
    }
    out
}

pub type Space = Workspace<MemoryStore, StrictEd25519>;

pub fn space(limits: Limits) -> Space {
    Workspace::new(MemoryStore::default(), StrictEd25519, limits)
}

/// A workspace founded by `founder`, with its first record.
pub fn founded(founder: &Device, limits: Limits) -> (Space, Vec<u8>) {
    let mut space = space(limits);
    let genesis = record(WS, 0, founder, None, Change::Founded(founder));
    let path = format!("/api/w/{}", WS.to_hex());
    assert!(space.found(&call(founder, "POST", &path, &genesis).request(), WS, &genesis).unwrap());
    (space, genesis)
}

pub fn path(tail: &str) -> String {
    format!("/api/w/{}{tail}", WS.to_hex())
}
