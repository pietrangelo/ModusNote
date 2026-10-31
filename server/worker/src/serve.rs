//! What each Durable Object does with a call, without the runtime: the
//! route is parsed again inside the object (it is the same path the device
//! signed), the body's digest is taken there, and the use case answers.
//! `runtime` only moves bytes in and out, and does what needs R2.

use ledger::{Credential, MemberKey, SignatureCheck, WorkspaceId};
use publish::{MediaType, Site};
use serde::Serialize;
use sync::{Budget, Guard, Hasher, Heads, PowPurpose, Rendezvous, Request, Socket, Store, Workspace, pow_satisfied};

use crate::api::{
    self, AnswerBody, AnswersReply, ApiError, BlobReply, BlobsReply, BundleBody, BundleReply, BundlesReply, ClaimBody,
    DeleteBlobsBody, FoundBody, HeadsReply, OfferBody, OfferReply, PositionReply, PositionsReply, PullReply, PushBody,
    RecordBody, RecordsReply, Route, decode, encode, live_token, parse_json, pow_day_ok,
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
/// How the object closes a live socket: its key left the log, the
/// workspace is gone, the key opened a fifth socket, or the device sent
/// something other than `ping`.
pub const CLOSE_REMOVED: u16 = 4403;
pub const CLOSE_GONE: u16 = 4404;
pub const CLOSE_EVICTED: u16 = 4409;
pub const CLOSE_POLICY: u16 = 1008;

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
    /// `Upgrade` and `Sec-WebSocket-Protocol`, for the live channel.
    pub upgrade: Option<&'a str>,
    pub protocols: Option<&'a str>,
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
    /// A write landed: the reply, and who signed it, so that the other
    /// members' live sockets hear of it.
    Wrote {
        status: u16,
        body: String,
        author: MemberKey,
    },
    /// A member's handshake for the live channel, admitted.
    Live(MemberKey),
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

/// A reply to a write, with the key that signed it. The use case has
/// already checked the signature, so the header is there.
fn wrote(incoming: &Incoming<'_>, done: Done) -> Done {
    let author = incoming.authorization.and_then(Credential::parse).map(|credential| credential.key);
    match (done, author) {
        (Done::Json(status, body), Some(author)) => Done::Wrote { status, body, author },
        (done, _) => done,
    }
}

/// What a live socket receives after a write: the same numbers as `GET
/// heads`, a hint to sync now.
pub fn heads_message(heads: Heads) -> String {
    format!(r#"{{"rows":{},"bundles":{},"membership":{}}}"#, heads.rows, heads.bundles, heads.membership)
}

/// A live socket's only tag: its key, in hex (64 characters, well within
/// the platform's limits on tags).
pub fn socket_tag(key: &MemberKey) -> String {
    key.to_hex()
}

/// A socket from its tags, attachment (the time it was accepted; none
/// counts as the oldest) and state, or None if the tags are not ours.
pub fn socket_of(tags: &[String], accepted_ms: Option<u64>, open: bool) -> Option<Socket> {
    match tags {
        [tag] => MemberKey::parse_hex(tag).map(|key| Socket { key, accepted_ms: accepted_ms.unwrap_or(0), open }),
        _ => None,
    }
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
            let records = parse_json::<FoundBody>(body)?
                .records
                .iter()
                .map(|text| decode(text))
                .collect::<Result<Vec<_>, _>>()?;
            let created = space.found(&request, ws, &records)?;
            let reply = Done::Json(if created { 201 } else { 200 }, format!(r#"{{"created":{created}}}"#));
            Ok(if created { wrote(incoming, reply) } else { reply })
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
            Ok(wrote(incoming, empty(201)))
        }
        Route::Bundles(_, after) => {
            let (bundles, more) = space.bundles(&request, after)?;
            let bundles =
                bundles.into_iter().map(|(position, wire)| BundleReply { position, bundle: encode(&wire) }).collect();
            json(200, &BundlesReply { bundles, more })
        }
        Route::AppendBundle(_) => {
            let bundle = decode(&parse_json::<BundleBody>(body)?.bundle)?;
            Ok(wrote(incoming, json(201, &PositionReply { position: space.append_bundle(&request, &bundle)? })?))
        }
        Route::Pull(_, after) => {
            let (rows, more) = space.pull(&request, after)?;
            json(200, &PullReply::new(rows, more))
        }
        Route::Push(_) => {
            let rows = parse_json::<PushBody>(body)?.rows()?;
            Ok(wrote(incoming, json(201, &PositionsReply { positions: space.push(&request, &rows)? })?))
        }
        Route::ListBlobs(_, after) => {
            let (blobs, more) = space.blobs(&request, after.as_deref())?;
            let blobs = blobs
                .into_iter()
                .map(|blob| BlobReply { id: blob.id, size: blob.size, uploaded: blob.uploaded_ms })
                .collect();
            json(200, &BlobsReply { blobs, more })
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
        Route::Live(_) => {
            let token = live_token(incoming.upgrade, incoming.protocols)?;
            Ok(Done::Live(space.live(&request, token)?))
        }
        Route::Info
        | Route::Offer(_)
        | Route::Answer(_)
        | Route::Answers(_)
        | Route::CloseCode(_)
        | Route::ClaimSite(_)
        | Route::PutSettings(_)
        | Route::DeleteSite(_)
        | Route::PutPage(..)
        | Route::DeletePage(..)
        | Route::PutMedia(..)
        | Route::DeleteMedia(..) => Err(ApiError::NotFound),
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
        Route::ClaimSite(site) => (PowPurpose::Site, site.as_bytes().to_vec(), parse_json::<ClaimBody>(body)?.pow),
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

/// Public reads of a site, from the pages Worker on serv.pub (only it
/// reaches these paths: the API Worker never routes a device's path here).
pub const INTERNAL_HOME: &str = "/internal/home";
pub const INTERNAL_STYLE: &str = "/internal/style";
pub const INTERNAL_FEED: &str = "/internal/feed";
pub const INTERNAL_PAGE: &str = "/internal/page/";
pub const INTERNAL_MEDIA: &str = "/internal/media/";

/// What a site's object answers: a JSON reply to the app, or a page, a
/// stylesheet or a file's type to the pages Worker.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SiteDone {
    Json(u16, String),
    Html(String),
    Css(String),
    /// An Atom feed.
    Feed(String),
    MediaType(MediaType),
}

/// Serves a site's object: the signed API calls, and the public reads.
pub fn site<S: Store, C: SignatureCheck>(
    site: &mut Site<S, C>,
    hasher: &impl Hasher,
    incoming: &Incoming<'_>,
) -> Result<SiteDone, ApiError> {
    if incoming.method == "GET" {
        let path = incoming.path;
        return Ok(if path == INTERNAL_HOME {
            SiteDone::Html(site.home_html()?)
        } else if path == INTERNAL_STYLE {
            SiteDone::Css(site.style_css()?)
        } else if path == INTERNAL_FEED {
            SiteDone::Feed(site.feed_xml()?)
        } else if let Some(slug) = path.strip_prefix(INTERNAL_PAGE) {
            SiteDone::Html(site.page_html(slug)?)
        } else if let Some(id) = path.strip_prefix(INTERNAL_MEDIA) {
            SiteDone::MediaType(site.media_type(id)?)
        } else {
            return Err(ApiError::NotFound);
        });
    }
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
    let ok = || SiteDone::Json(200, "{}".into());
    match route {
        Route::ClaimSite(_) => {
            let settings = parse_json::<ClaimBody>(body)?.settings.to_string();
            let created = site.claim(&request, settings.as_bytes())?;
            Ok(SiteDone::Json(if created { 201 } else { 200 }, format!(r#"{{"created":{created}}}"#)))
        }
        Route::PutSettings(_) => {
            site.put_settings(&request, body)?;
            Ok(ok())
        }
        Route::DeleteSite(_) => {
            site.delete(&request)?;
            Ok(ok())
        }
        Route::PutPage(_, slug) => {
            let created = site.put_page(&request, &slug, body)?;
            Ok(SiteDone::Json(if created { 201 } else { 200 }, format!(r#"{{"created":{created}}}"#)))
        }
        Route::DeletePage(_, slug) => {
            site.delete_page(&request, &slug)?;
            Ok(ok())
        }
        Route::PutMedia(_, id, kind) => {
            let kind = MediaType::parse(&kind).ok_or(ApiError::NotFound)?;
            let size = incoming.blob_size.and_then(|s| s.parse().ok()).ok_or(ApiError::LengthRequired)?;
            site.admit_media(&request, &id, kind, size)?;
            Ok(ok())
        }
        Route::DeleteMedia(_, id) => {
            site.delete_media(&request, &id)?;
            Ok(ok())
        }
        _ => Err(ApiError::NotFound),
    }
}
