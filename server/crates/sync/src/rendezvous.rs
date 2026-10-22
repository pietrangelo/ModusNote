//! Where an owner's sealed offer under a code's lookup meets the sealed
//! answers of the devices that know the whole code, for fifteen minutes.
//!
//! The Worker lets an offer in only after the workspace's own object has
//! checked that an owner signed it, so a lookup cannot be taken over: the
//! first offer keeps it until it expires or its poster closes it. Answers
//! need only the lookup (and the Worker's proof of work); at most
//! [`MAX_ANSWERS`] are kept, and only the poster reads or closes them.

use ledger::{MemberKey, SignatureCheck, WorkspaceId};

use crate::auth::{Caller, Denied, Request, authenticate, decode_u64};
use crate::store::{Store, Unavailable};

pub const LIFETIME_MS: u64 = 15 * 60 * 1000;
pub const MAX_ANSWERS: usize = 8;
pub const MAX_MESSAGE: usize = 8 * 1024;
const OFFER: &str = "offer";
const ANSWERS: &str = "answer/";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RendezvousError {
    Denied(Denied),
    NotFound,
    /// The lookup is taken (409).
    Conflict,
    /// Enough answers already (429).
    Full,
    Malformed,
    Unavailable,
}

impl From<Unavailable> for RendezvousError {
    fn from(_: Unavailable) -> Self {
        Self::Unavailable
    }
}

impl From<Denied> for RendezvousError {
    fn from(denied: Denied) -> Self {
        match denied {
            Denied::Unavailable => Self::Unavailable,
            other => Self::Denied(other),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct Offer {
    poster: MemberKey,
    created_ms: u64,
    workspace: WorkspaceId,
    sealed: Vec<u8>,
}

impl Offer {
    fn load(store: &impl Store, now_ms: u64) -> Result<Option<Self>, Unavailable> {
        let Some(bytes) = store.get(OFFER)? else { return Ok(None) };
        if bytes.len() < 56 {
            return Ok(None);
        }
        let offer = Self {
            poster: MemberKey(bytes[..32].try_into().expect("32 bytes")),
            created_ms: decode_u64(&bytes[32..40]),
            workspace: WorkspaceId(bytes[40..56].try_into().expect("16 bytes")),
            sealed: bytes[56..].to_vec(),
        };
        Ok((now_ms < offer.created_ms + LIFETIME_MS).then_some(offer))
    }
}

#[derive(Debug)]
pub struct Rendezvous<S, C> {
    store: S,
    check: C,
}

impl<S: Store, C: SignatureCheck> Rendezvous<S, C> {
    pub fn new(store: S, check: C) -> Self {
        Self { store, check }
    }

    /// Takes the lookup for `poster`, whom the workspace's object has
    /// already checked to be an owner of `workspace`.
    pub fn post_offer(
        &mut self,
        poster: MemberKey,
        workspace: WorkspaceId,
        sealed: &[u8],
        now_ms: u64,
    ) -> Result<(), RendezvousError> {
        if sealed.is_empty() || sealed.len() > MAX_MESSAGE {
            return Err(RendezvousError::Malformed);
        }
        if Offer::load(&self.store, now_ms)?.is_some() {
            return Err(RendezvousError::Conflict);
        }
        self.store.transaction(|store| {
            store.clear()?;
            let mut bytes = poster.0.to_vec();
            bytes.extend_from_slice(&now_ms.to_be_bytes());
            bytes.extend_from_slice(&workspace.0);
            bytes.extend_from_slice(sealed);
            store.put(OFFER, &bytes)?;
            Ok(())
        })
    }

    /// The offer under this lookup, while it lasts.
    pub fn offer(&mut self, now_ms: u64) -> Result<Vec<u8>, RendezvousError> {
        Ok(Offer::load(&self.store, now_ms)?.ok_or(RendezvousError::NotFound)?.sealed)
    }

    pub fn post_answer(&mut self, sealed: &[u8], now_ms: u64) -> Result<(), RendezvousError> {
        if sealed.is_empty() || sealed.len() > MAX_MESSAGE {
            return Err(RendezvousError::Malformed);
        }
        Offer::load(&self.store, now_ms)?.ok_or(RendezvousError::NotFound)?;
        let count = self.store.list(ANSWERS, None, MAX_ANSWERS)?.len();
        if count >= MAX_ANSWERS {
            return Err(RendezvousError::Full);
        }
        self.store.put(&format!("{ANSWERS}{count:02}"), sealed)?;
        Ok(())
    }

    /// The answers, oldest first, for the offer's poster only.
    pub fn answers(&mut self, request: &Request<'_>) -> Result<Vec<Vec<u8>>, RendezvousError> {
        self.poster(request)?;
        Ok(self.store.list(ANSWERS, None, MAX_ANSWERS)?.into_iter().map(|(_, sealed)| sealed).collect())
    }

    /// Frees the lookup, for the offer's poster only.
    pub fn close(&mut self, request: &Request<'_>) -> Result<(), RendezvousError> {
        self.poster(request)?;
        self.store.clear()?;
        Ok(())
    }

    /// When the offer expires, for the object's alarm.
    pub fn expires_ms(&self) -> Result<Option<u64>, RendezvousError> {
        let Some(bytes) = self.store.get(OFFER)? else { return Ok(None) };
        Ok(bytes.get(32..40).map(|t| decode_u64(t) + LIFETIME_MS))
    }

    /// Forgets an expired offer and its answers; true when it did.
    pub fn expire(&mut self, now_ms: u64) -> Result<bool, RendezvousError> {
        if self.store.get(OFFER)?.is_some() && Offer::load(&self.store, now_ms)?.is_none() {
            self.store.clear()?;
            return Ok(true);
        }
        Ok(false)
    }

    fn poster(&mut self, request: &Request<'_>) -> Result<(), RendezvousError> {
        let offer = Offer::load(&self.store, request.now_ms)?.ok_or(RendezvousError::NotFound)?;
        let Caller { key } = authenticate(&mut self.store, &self.check, request)?;
        if key == offer.poster { Ok(()) } else { Err(RendezvousError::Denied(Denied::Forbidden)) }
    }
}
