//! What each Durable Object does with a call, without the runtime: the
//! route is parsed again inside the object (it is the same path the device
//! signed), the body's digest is taken there, and the use case answers.
//! `runtime` only moves bytes in and out, and does what needs R2.

use ledger::{MemberKey, SignatureCheck, WorkspaceId};
use serde::Serialize;
use sync::{Budget, Guard, Hasher, PowPurpose, Rendezvous, Request, Store, Workspace, pow_satisfied};

use crate::api::{
    self, AnswerBody, AnswersReply, ApiError, BlobReply, BlobsReply, BundleBody, BundleReply, BundlesReply,
    DeleteBlobsBody, FoundBody, HeadsReply, OfferBody, OfferReply, PositionReply, PositionsReply, PullReply, PushBody,
    RecordBody, RecordsReply, Route, decode, encode, parse_json, pow_day_ok,
};

/// Where the Worker hands an owner's offer, already checked by the
/// workspace's object, to the code's object. Only the Worker reaches the
/// objects, and it never routes a device's path here.
pub const INTERNAL_OFFER: &str = "/internal/offer";
/// Where the Worker spends from the guard's daily ceilings.
pub const INTERNAL_SPEND: &str = "/internal/spend";
/// The size of a blob about to be uploaded, from the Worker (the device's
/// `Content-Length`): the upload's body goes to R2, not to the object.
pub const BLOB_SIZE: &str = "X-Blob-Size";

/// BLAKE2b-256 for the use cases, as libsodium computes it.
#[derive(Clone, Copy, Debug, Default)]
pub struct Blake2b;

impl Hasher for Blake2b {
    fn blake2b_256(&self, bytes: &[u8]) -> [u8; 32] {
        crypto::blake2b_256(bytes)
    }
}

/// A call as an object receives it.
#[derive(Clone, Copy, Debug)]
pub struct Incoming<'a> {
    pub method: &'a str,
    pub path: &'a str,
    pub query: Option<&'a str>,
    pub authorization: Option<&'a str>,
    pub body: &'a [u8],
    pub blob_size: Option<&'a str>,
    pub now_ms: u64,
}

impl Incoming<'_> {
    /// The path with its query, as the device signed it.
    fn target(&self) -> String {
        match self.query {
            Some(query) => format!("{}?{query}", self.path),
            None => self.path.to_owned(),
        }
    }
}

/// What a workspace's object answers, and what is left for the runtime.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Done {
    Json(u16, String),
    /// The workspace is gone; its blobs in R2 follow.
    Deleted,
    /// These blobs were released; their objects in R2 follow.
    Released(Vec<String>),
    /// An owner's offer, for the code's object.
    Offer {
        poster: MemberKey,
        sealed: Vec<u8>,
    },
}

fn json(status: u16, body: &impl Serialize) -> Result<Done, ApiError> {
    serde_json::to_string(body).map(|text| Done::Json(status, text)).map_err(|_| ApiError::Unavailable)
}

fn empty(status: u16) -> Done {
    Done::Json(status, "{}".into())
}

/// Serves one call in a workspace's object.
pub fn workspace<S: Store, C: SignatureCheck>(
    space: &mut Workspace<S, C>,
    hasher: &impl Hasher,
    incoming: &Incoming<'_>,
) -> Result<Done, ApiError> {
    let route = api::route(incoming.method, incoming.path, incoming.query)?;
    let target = incoming.target();
    let request = Request {
        method: incoming.method,
        path: &target,
        authorization: incoming.authorization,
        body_digest: hasher.blake2b_256(incoming.body),
        now_ms: incoming.now_ms,
    };
    let body = incoming.body;
    match route {
        Route::Found(ws) => {
            let record = decode(&parse_json::<FoundBody>(body)?.record)?;
            let created = space.found(&request, ws, &record)?;
            Ok(Done::Json(if created { 201 } else { 200 }, format!(r#"{{"created":{created}}}"#)))
        }
        Route::DeleteWorkspace(_) => {
            space.delete(&request)?;
            Ok(Done::Deleted)
        }
        Route::Heads(_) => json(200, &HeadsReply::from(space.heads(&request)?)),
        Route::Membership(_, from) => {
            let records = space.membership(&request, from)?.iter().map(|wire| encode(wire)).collect();
            json(200, &RecordsReply { records })
        }
        Route::AppendRecord(_) => {
            let record = decode(&parse_json::<RecordBody>(body)?.record)?;
            space.append_record(&request, &record)?;
            Ok(empty(201))
        }
        Route::Bundles(_, after) => {
            let (bundles, more) = space.bundles(&request, after)?;
            let bundles =
                bundles.into_iter().map(|(position, wire)| BundleReply { position, bundle: encode(&wire) }).collect();
            json(200, &BundlesReply { bundles, more })
        }
        Route::AppendBundle(_) => {
            let bundle = decode(&parse_json::<BundleBody>(body)?.bundle)?;
            json(201, &PositionReply { position: space.append_bundle(&request, &bundle)? })
        }
        Route::Pull(_, after) => {
            let (rows, more) = space.pull(&request, after)?;
            json(200, &PullReply::new(rows, more))
        }
        Route::Push(_) => {
            let rows = parse_json::<PushBody>(body)?.rows()?;
            json(201, &PositionsReply { positions: space.push(&request, &rows)? })
        }
        Route::ListBlobs(_, after) => {
            let blobs = space
                .blobs(&request, after.as_deref())?
                .into_iter()
                .map(|blob| BlobReply { id: blob.id, size: blob.size, uploaded: blob.uploaded_ms })
                .collect();
            json(200, &BlobsReply { blobs })
        }
        Route::PutBlob(_, id) => {
            let size = incoming.blob_size.and_then(|v| v.parse().ok()).ok_or(ApiError::LengthRequired)?;
            space.reserve_blob(&request, &id, size)?;
            Ok(empty(200))
        }
        Route::GetBlob(..) => {
            space.may_read(&request)?;
            Ok(empty(200))
        }
        Route::DeleteBlobs(_) => {
            let ids = parse_json::<DeleteBlobsBody>(body)?.ids;
            space.release_blobs(&request, &ids)?;
            Ok(Done::Released(ids))
        }
        Route::PostOffer(..) => {
            let sealed = decode(&parse_json::<OfferBody>(body)?.offer)?;
            let poster = space.owner(&request)?;
            Ok(Done::Offer { poster, sealed })
        }
        Route::Info | Route::Offer(_) | Route::Answer(_) | Route::Answers(_) | Route::CloseCode(_) => {
            Err(ApiError::NotFound)
        }
    }
}

/// The body of [`INTERNAL_OFFER`]: poster, workspace, sealed offer.
pub fn offer_call(poster: &MemberKey, workspace: &WorkspaceId, sealed: &[u8]) -> Vec<u8> {
    [poster.0.as_slice(), &workspace.0, sealed].concat()
}

/// Serves one call in a code's object.
pub fn rendezvous<S: Store, C: SignatureCheck>(
    meeting: &mut Rendezvous<S, C>,
    hasher: &impl Hasher,
    incoming: &Incoming<'_>,
) -> Result<(u16, String), ApiError> {
    let now = incoming.now_ms;
    if incoming.path == INTERNAL_OFFER && incoming.method == "POST" {
        let body = incoming.body;
        if body.len() < 48 {
            return Err(ApiError::BadRequest);
        }
        let poster = MemberKey(body[..32].try_into().map_err(|_| ApiError::BadRequest)?);
        let workspace = WorkspaceId(body[32..48].try_into().map_err(|_| ApiError::BadRequest)?);
        meeting.post_offer(poster, workspace, &body[48..], now)?;
        return Ok((201, "{}".into()));
    }
    let route = api::route(incoming.method, incoming.path, incoming.query)?;
    let target = incoming.target();
    let request = Request {
        method: incoming.method,
        path: &target,
        authorization: incoming.authorization,
        body_digest: hasher.blake2b_256(incoming.body),
        now_ms: now,
    };
    match route {
        Route::Offer(_) => text(&OfferReply { offer: encode(&meeting.offer(now)?) }),
        Route::Answer(_) => {
            meeting.post_answer(&decode(&parse_json::<AnswerBody>(incoming.body)?.answer)?, now)?;
            Ok((201, "{}".into()))
        }
        Route::Answers(_) => {
            let answers = meeting.answers(&request)?.iter().map(|sealed| encode(sealed)).collect();
            text(&AnswersReply { answers })
        }
        Route::CloseCode(_) => {
            meeting.close(&request)?;
            Ok((200, "{}".into()))
        }
        _ => Err(ApiError::NotFound),
    }
}

fn text(body: &impl Serialize) -> Result<(u16, String), ApiError> {
    serde_json::to_string(body).map(|text| (200, text)).map_err(|_| ApiError::Unavailable)
}

/// Checks the proof of work of a call that founds a workspace or answers a
/// code, before anything else spends on it. Other calls need none.
pub fn admit(route: &Route, body: &[u8], hasher: &impl Hasher, now_ms: u64, bits: u32) -> Result<(), ApiError> {
    let (purpose, target, pow) = match route {
        Route::Found(ws) => (PowPurpose::Found, ws.0.to_vec(), parse_json::<FoundBody>(body)?.pow),
        Route::Answer(lookup) => (PowPurpose::Answer, lookup.as_bytes().to_vec(), parse_json::<AnswerBody>(body)?.pow),
        _ => return Ok(()),
    };
    let nonce = pow.nonce()?;
    if pow_day_ok(pow.day, now_ms) && pow_satisfied(hasher, purpose, &target, pow.day, &nonce, bits) {
        Ok(())
    } else {
        Err(ApiError::Work)
    }
}

/// The body of [`INTERNAL_SPEND`]: budget, amount, ceiling.
pub fn spend_call(budget: Budget, amount: u64, ceiling: u64) -> Vec<u8> {
    let code = match budget {
        Budget::Workspaces => 1u8,
        Budget::UploadBytes => 2,
    };
    [[code].as_slice(), &amount.to_be_bytes(), &ceiling.to_be_bytes()].concat()
}

/// Serves [`INTERNAL_SPEND`] in the guard's object: true when admitted.
pub fn guard<S: Store>(guard: &mut Guard<S>, incoming: &Incoming<'_>) -> Result<bool, ApiError> {
    let body = incoming.body;
    if incoming.path != INTERNAL_SPEND || incoming.method != "POST" || body.len() != 17 {
        return Err(ApiError::NotFound);
    }
    let budget = match body[0] {
        1 => Budget::Workspaces,
        2 => Budget::UploadBytes,
        _ => return Err(ApiError::BadRequest),
    };
    let number = |range: std::ops::Range<usize>| body[range].try_into().map(u64::from_be_bytes);
    let (amount, ceiling) = (number(1..9), number(9..17));
    let (Ok(amount), Ok(ceiling)) = (amount, ceiling) else { return Err(ApiError::BadRequest) };
    guard.spend(budget, amount, ceiling, incoming.now_ms).map_err(|_| ApiError::Unavailable)
}
