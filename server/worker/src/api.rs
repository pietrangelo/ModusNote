//! The HTTP surface, without the runtime: routes, request and response
//! bodies, and how outcomes become status codes. Everything here runs
//! natively in the tests; `runtime` wires it to Workers.
//!
//! All binary values travel as standard base64 inside JSON, except blobs,
//! which are raw bodies.

use std::net::IpAddr;

use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use ledger::WorkspaceId;
use serde::{Deserialize, Serialize};
use sync::{Denied, RendezvousError, SyncError};

/// What a body may weigh, as JSON: a push or a bundle (rows of up to
/// 1 MiB, grants of every epoch to every member, in base64), or anything
/// else. Larger pushes go in several requests.
pub const MAX_BULK_BODY: u64 = 8 << 20;
pub const MAX_SMALL_BODY: u64 = 64 << 10;
/// What proof of work founding a workspace or answering a code costs: about
/// a million BLAKE2b hashes, a second or two on a phone.
pub const POW_BITS: u32 = 20;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Route {
    Info,
    Found(WorkspaceId),
    DeleteWorkspace(WorkspaceId),
    Heads(WorkspaceId),
    Membership(WorkspaceId, u32),
    AppendRecord(WorkspaceId),
    Bundles(WorkspaceId, u64),
    AppendBundle(WorkspaceId),
    Pull(WorkspaceId, u64),
    Push(WorkspaceId),
    ListBlobs(WorkspaceId, Option<String>),
    PutBlob(WorkspaceId, String),
    GetBlob(WorkspaceId, String),
    DeleteBlobs(WorkspaceId),
    PostOffer(WorkspaceId, String),
    /// The live channel: a WebSocket that hears of every write.
    Live(WorkspaceId),
    Offer(String),
    Answer(String),
    Answers(String),
    CloseCode(String),
}

impl Route {
    /// The workspace whose object answers, if any.
    pub fn workspace(&self) -> Option<WorkspaceId> {
        match self {
            Self::Found(ws)
            | Self::DeleteWorkspace(ws)
            | Self::Heads(ws)
            | Self::Membership(ws, _)
            | Self::AppendRecord(ws)
            | Self::Bundles(ws, _)
            | Self::AppendBundle(ws)
            | Self::Pull(ws, _)
            | Self::Push(ws)
            | Self::ListBlobs(ws, _)
            | Self::PutBlob(ws, _)
            | Self::GetBlob(ws, _)
            | Self::DeleteBlobs(ws)
            | Self::PostOffer(ws, _)
            | Self::Live(ws) => Some(*ws),
            _ => None,
        }
    }

    /// The code whose object answers, if any.
    pub fn lookup(&self) -> Option<&str> {
        match self {
            Self::PostOffer(_, lookup)
            | Self::Offer(lookup)
            | Self::Answer(lookup)
            | Self::Answers(lookup)
            | Self::CloseCode(lookup) => Some(lookup),
            _ => None,
        }
    }

    /// Whether the body is JSON to read (a blob's is streamed to R2).
    pub fn takes_json(&self) -> bool {
        matches!(
            self,
            Self::Found(_)
                | Self::AppendRecord(_)
                | Self::AppendBundle(_)
                | Self::Push(_)
                | Self::DeleteBlobs(_)
                | Self::PostOffer(..)
                | Self::Answer(_)
        )
    }

    /// The largest body the route reads, refused before it is read.
    pub fn max_body(&self) -> u64 {
        match self {
            Self::Push(_) | Self::AppendBundle(_) | Self::Found(_) => MAX_BULK_BODY,
            _ => MAX_SMALL_BODY,
        }
    }

    /// A request that changes something; it is throttled more and its
    /// nonce is remembered. So is the live channel's handshake: a socket
    /// costs more than a read, and its nonce is remembered too.
    pub fn writes(&self) -> bool {
        !matches!(
            self,
            Self::Info
                | Self::Heads(_)
                | Self::Membership(..)
                | Self::Bundles(..)
                | Self::Pull(..)
                | Self::ListBlobs(..)
                | Self::GetBlob(..)
                | Self::Offer(_)
                | Self::Answers(_)
        )
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ApiError {
    NotFound,
    MethodNotAllowed,
    BadRequest,
    Unauthenticated,
    /// The device's clock is off; the body tells the server's time.
    Clock,
    Forbidden,
    Conflict,
    Unprocessable,
    TooLarge,
    LengthRequired,
    RateLimited,
    CrossOrigin,
    /// The proof of work is missing, stale or short.
    Work,
    /// Not a WebSocket upgrade to [`LIVE_PROTOCOL`].
    UpgradeRequired,
    Unavailable,
}

impl ApiError {
    pub fn status(self) -> u16 {
        match self {
            Self::NotFound => 404,
            Self::MethodNotAllowed => 405,
            Self::BadRequest => 400,
            Self::Unauthenticated | Self::Clock => 401,
            Self::Forbidden | Self::CrossOrigin | Self::Work => 403,
            Self::Conflict => 409,
            Self::LengthRequired => 411,
            Self::TooLarge => 413,
            Self::Unprocessable => 422,
            Self::UpgradeRequired => 426,
            Self::RateLimited => 429,
            Self::Unavailable => 503,
        }
    }

    /// Fixed bodies: nothing from the request is echoed back.
    pub fn body(self, now_ms: u64) -> String {
        let code = match self {
            Self::NotFound => "not_found",
            Self::MethodNotAllowed => "method_not_allowed",
            Self::BadRequest => "bad_request",
            Self::Unauthenticated => "unauthenticated",
            Self::Clock => return format!(r#"{{"error":"clock","now":{now_ms}}}"#),
            Self::Forbidden => "forbidden",
            Self::Conflict => "conflict",
            Self::Unprocessable => "refused",
            Self::TooLarge => "too_large",
            Self::LengthRequired => "length_required",
            Self::RateLimited => "rate_limited",
            Self::CrossOrigin => "cross_origin",
            Self::Work => "proof_of_work",
            Self::UpgradeRequired => "upgrade_required",
            Self::Unavailable => "unavailable",
        };
        format!(r#"{{"error":"{code}"}}"#)
    }
}

impl From<SyncError> for ApiError {
    fn from(error: SyncError) -> Self {
        match error {
            SyncError::Denied(denied) => denied.into(),
            SyncError::NotFound => Self::NotFound,
            SyncError::Conflict => Self::Conflict,
            SyncError::Refused(_) => Self::Unprocessable,
            SyncError::Malformed(_) => Self::BadRequest,
            SyncError::Full => Self::TooLarge,
            SyncError::Throttled => Self::RateLimited,
            SyncError::Unavailable => Self::Unavailable,
        }
    }
}

impl From<Denied> for ApiError {
    fn from(denied: Denied) -> Self {
        match denied {
            Denied::Unauthenticated | Denied::Replayed => Self::Unauthenticated,
            Denied::Clock => Self::Clock,
            Denied::Forbidden => Self::Forbidden,
            Denied::Unavailable => Self::Unavailable,
        }
    }
}

impl From<RendezvousError> for ApiError {
    fn from(error: RendezvousError) -> Self {
        match error {
            RendezvousError::Denied(denied) => denied.into(),
            RendezvousError::NotFound => Self::NotFound,
            RendezvousError::Conflict => Self::Conflict,
            RendezvousError::Full => Self::RateLimited,
            RendezvousError::Malformed => Self::BadRequest,
            RendezvousError::Unavailable => Self::Unavailable,
        }
    }
}

/// Maps method, path and query to a route. Anything unexpected is a 404,
/// or a 405 for a known path.
pub fn route(method: &str, path: &str, query: Option<&str>) -> Result<Route, ApiError> {
    let segments: Vec<&str> = path.strip_prefix("/api/").ok_or(ApiError::NotFound)?.split('/').collect();
    let query = query.unwrap_or("");
    let (allowed, route): (&str, Route) = match segments.as_slice() {
        ["info"] => ("GET", Route::Info),
        ["w", ws] => {
            let ws = workspace(ws)?;
            match method {
                "DELETE" => ("DELETE", Route::DeleteWorkspace(ws)),
                _ => ("POST", Route::Found(ws)),
            }
        }
        ["w", ws, "heads"] => ("GET", Route::Heads(workspace(ws)?)),
        ["w", ws, "membership"] => {
            let ws = workspace(ws)?;
            match method {
                "GET" => ("GET", Route::Membership(ws, number(query, "from")?)),
                _ => ("POST", Route::AppendRecord(ws)),
            }
        }
        ["w", ws, "bundles"] => {
            let ws = workspace(ws)?;
            match method {
                "GET" => ("GET", Route::Bundles(ws, number(query, "after")?)),
                _ => ("POST", Route::AppendBundle(ws)),
            }
        }
        ["w", ws, "rows"] => {
            let ws = workspace(ws)?;
            match method {
                "GET" => ("GET", Route::Pull(ws, number(query, "after")?)),
                _ => ("POST", Route::Push(ws)),
            }
        }
        ["w", ws, "blobs"] => {
            let after = match query {
                "" => None,
                q => Some(blob_id(q.strip_prefix("after=").ok_or(ApiError::NotFound)?)?),
            };
            ("GET", Route::ListBlobs(workspace(ws)?, after))
        }
        ["w", ws, "blobs", "delete"] => ("POST", Route::DeleteBlobs(workspace(ws)?)),
        ["w", ws, "blobs", id] => {
            let (ws, id) = (workspace(ws)?, blob_id(id)?);
            match method {
                "PUT" => ("PUT", Route::PutBlob(ws, id)),
                _ => ("GET", Route::GetBlob(ws, id)),
            }
        }
        ["w", ws, "codes", lookup] => ("POST", Route::PostOffer(workspace(ws)?, code_lookup(lookup)?)),
        ["w", ws, "live"] => ("GET", Route::Live(workspace(ws)?)),
        ["codes", lookup] => {
            let lookup = code_lookup(lookup)?;
            match method {
                "DELETE" => ("DELETE", Route::CloseCode(lookup)),
                _ => ("GET", Route::Offer(lookup)),
            }
        }
        ["codes", lookup, "answers"] => {
            let lookup = code_lookup(lookup)?;
            match method {
                "GET" => ("GET", Route::Answers(lookup)),
                _ => ("POST", Route::Answer(lookup)),
            }
        }
        _ => return Err(ApiError::NotFound),
    };
    if method != allowed {
        return Err(ApiError::MethodNotAllowed);
    }
    let takes_query =
        matches!(route, Route::Membership(..) | Route::Bundles(..) | Route::Pull(..) | Route::ListBlobs(..));
    if !takes_query && !query.is_empty() {
        return Err(ApiError::NotFound);
    }
    Ok(route)
}

fn workspace(segment: &str) -> Result<WorkspaceId, ApiError> {
    WorkspaceId::parse_hex(segment).ok_or(ApiError::NotFound)
}

/// `name=N` in canonical decimal, and nothing else.
fn number<T: std::str::FromStr>(query: &str, name: &str) -> Result<T, ApiError> {
    let value = query.strip_prefix(name).and_then(|rest| rest.strip_prefix('=')).ok_or(ApiError::NotFound)?;
    let canonical = !value.is_empty()
        && value.len() <= 16
        && value.bytes().all(|b| b.is_ascii_digit())
        && (value == "0" || !value.starts_with('0'));
    value.parse().ok().filter(|_| canonical).ok_or(ApiError::NotFound)
}

/// A blob id as `BlobId` allows it: 1 to 128 of `A-Z a-z 0-9 - _`.
fn blob_id(segment: &str) -> Result<String, ApiError> {
    let ok = !segment.is_empty()
        && segment.len() <= 128
        && segment.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_');
    if ok { Ok(segment.to_owned()) } else { Err(ApiError::NotFound) }
}

/// The six public symbols of an `InviteCode`, in its Crockford alphabet.
fn code_lookup(segment: &str) -> Result<String, ApiError> {
    const ALPHABET: &[u8] = b"0123456789ABCDEFGHJKMNPQRSTVWXYZ";
    let ok = segment.len() == 6 && segment.bytes().all(|b| ALPHABET.contains(&b));
    if ok { Ok(segment.to_owned()) } else { Err(ApiError::NotFound) }
}

/// Refuses calls from pages of other origins: browsers attach `Origin` to
/// cross-origin requests and same-origin POSTs, so a page elsewhere cannot
/// use its visitors as a botnet. The apps send none.
pub fn check_origin(origin: Option<&str>, own_origin: &str) -> Result<(), ApiError> {
    match origin {
        Some(origin) if origin != own_origin => Err(ApiError::CrossOrigin),
        _ => Ok(()),
    }
}

/// The live channel's subprotocol, the one the server answers with.
pub const LIVE_PROTOCOL: &str = "modusnote.live.v1";
/// How the credential is spelled among the offered subprotocols.
const LIVE_TOKEN: &str = "mn1.";

/// The credential of a live channel's handshake: a WebSocket upgrade that
/// offers [`LIVE_PROTOCOL`] and exactly one `mn1.` token in
/// `Sec-WebSocket-Protocol` (a browser cannot set `Authorization` there).
pub fn live_token<'a>(upgrade: Option<&str>, protocols: Option<&'a str>) -> Result<&'a str, ApiError> {
    let offered: Vec<&str> = protocols.map_or_else(Vec::new, |list| list.split(',').map(str::trim).collect());
    if !upgrade.is_some_and(|value| value.trim().eq_ignore_ascii_case("websocket")) || !offered.contains(&LIVE_PROTOCOL)
    {
        return Err(ApiError::UpgradeRequired);
    }
    match offered.iter().filter(|value| value.starts_with(LIVE_TOKEN)).collect::<Vec<_>>().as_slice() {
        [token] => Ok(token),
        _ => Err(ApiError::Unauthenticated),
    }
}

/// The key a client address is throttled under: IPv4 as is, IPv6 by its
/// /64. Anything unparsable shares one bucket.
pub fn limiter_key(address: &str) -> String {
    match address.trim().parse::<IpAddr>() {
        Ok(IpAddr::V4(v4)) => v4.to_string(),
        Ok(IpAddr::V6(v6)) => match v6.to_ipv4_mapped() {
            Some(v4) => v4.to_string(),
            None => {
                let s = v6.segments();
                format!("{:x}:{:x}:{:x}:{:x}::/64", s[0], s[1], s[2], s[3])
            }
        },
        Err(_) => "unknown".into(),
    }
}

/// The /48 an IPv6 client sits in, for a second, larger allowance.
pub fn network_key(address: &str) -> Option<String> {
    match address.trim().parse::<IpAddr>() {
        Ok(IpAddr::V6(v6)) if v6.to_ipv4_mapped().is_none() => {
            let s = v6.segments();
            Some(format!("{:x}:{:x}:{:x}::/48", s[0], s[1], s[2]))
        }
        _ => None,
    }
}

/// Whether a limiter's verdict stops the call: a write is refused when the
/// limiter cannot answer, a read goes on.
pub fn throttled(write: bool, admitted: Option<bool>) -> bool {
    match admitted {
        Some(admitted) => !admitted,
        None => write,
    }
}

/// The part of a blob a `Range` header asks for: `bytes=a-b` or `bytes=a-`,
/// as offset and inclusive end. Anything else, several ranges included, is
/// ignored and the whole blob is sent, as HTTP allows.
pub fn byte_range(header: Option<&str>) -> Option<(u64, Option<u64>)> {
    let spec = header?.trim().strip_prefix("bytes=")?;
    let (first, last) = spec.split_once('-')?;
    let digits = |s: &str| !s.is_empty() && s.len() <= 16 && s.bytes().all(|b| b.is_ascii_digit());
    if !digits(first) {
        return None;
    }
    let first: u64 = first.parse().ok()?;
    if last.is_empty() {
        return Some((first, None));
    }
    let last: u64 = if digits(last) { last.parse().ok()? } else { return None };
    (last >= first).then_some((first, Some(last)))
}

/// A positive whole number from the Worker's configuration, or `default`.
pub fn setting(value: Option<&str>, default: u64) -> u64 {
    value.and_then(|v| v.trim().parse().ok()).filter(|v| *v > 0).unwrap_or(default)
}

/// The declared length of a body, which must be there and fit.
pub fn declared_length(content_length: Option<&str>, max: u64) -> Result<u64, ApiError> {
    let declared = content_length.map(str::trim).filter(|v| !v.is_empty() && v.bytes().all(|b| b.is_ascii_digit()));
    match declared.map(str::parse::<u64>) {
        Some(Ok(n)) if n <= max => Ok(n),
        Some(_) => Err(ApiError::TooLarge),
        None => Err(ApiError::LengthRequired),
    }
}

pub fn decode(text: &str) -> Result<Vec<u8>, ApiError> {
    STANDARD.decode(text).map_err(|_| ApiError::BadRequest)
}

pub fn encode(bytes: &[u8]) -> String {
    STANDARD.encode(bytes)
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Pow {
    pub day: u32,
    pub nonce: String,
}

impl Pow {
    pub fn nonce(&self) -> Result<[u8; 16], ApiError> {
        decode(&self.nonce)?.try_into().map_err(|_| ApiError::BadRequest)
    }
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct FoundBody {
    pub records: Vec<String>,
    pub pow: Pow,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RecordBody {
    pub record: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BundleBody {
    pub bundle: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PushBody {
    pub rows: Vec<PushRow>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PushRow {
    pub record: String,
    pub ciphertext: String,
    pub supersedes: u64,
}

impl PushBody {
    pub fn rows(self) -> Result<Vec<sync::PushedRow>, ApiError> {
        self.rows
            .into_iter()
            .map(|row| {
                Ok(sync::PushedRow {
                    record: ledger_hex16(&row.record)?,
                    ciphertext: decode(&row.ciphertext)?,
                    supersedes: row.supersedes,
                })
            })
            .collect()
    }
}

fn ledger_hex16(text: &str) -> Result<[u8; 16], ApiError> {
    WorkspaceId::parse_hex(text).map(|id| id.0).ok_or(ApiError::BadRequest)
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DeleteBlobsBody {
    pub ids: Vec<String>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct OfferBody {
    pub offer: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AnswerBody {
    pub answer: String,
    pub pow: Pow,
}

#[derive(Debug, Serialize)]
pub struct HeadsReply {
    pub rows: u64,
    pub bundles: u64,
    pub membership: u64,
}

impl From<sync::Heads> for HeadsReply {
    fn from(heads: sync::Heads) -> Self {
        Self { rows: heads.rows, bundles: heads.bundles, membership: heads.membership }
    }
}

#[derive(Debug, Serialize)]
pub struct RecordsReply {
    pub records: Vec<String>,
}

#[derive(Debug, Serialize)]
pub struct BundleReply {
    pub position: u64,
    pub bundle: String,
}

#[derive(Debug, Serialize)]
pub struct BundlesReply {
    pub bundles: Vec<BundleReply>,
    pub more: bool,
}

#[derive(Debug, Serialize)]
pub struct PositionReply {
    pub position: u64,
}

#[derive(Debug, Serialize)]
pub struct PositionsReply {
    pub positions: Vec<u64>,
}

#[derive(Debug, Serialize)]
pub struct BlobReply {
    pub id: String,
    pub size: u64,
    pub uploaded: u64,
}

#[derive(Debug, Serialize)]
pub struct BlobsReply {
    pub blobs: Vec<BlobReply>,
    pub more: bool,
}

#[derive(Debug, Serialize)]
pub struct OfferReply {
    pub offer: String,
}

#[derive(Debug, Serialize)]
pub struct AnswersReply {
    pub answers: Vec<String>,
}

#[derive(Debug, Serialize)]
pub struct InfoReply<'a> {
    /// Changes only with a new server, whose data starts empty: a device
    /// that sees another id publishes its vault again.
    pub server: &'a str,
    pub pow: u32,
}

#[derive(Debug, Serialize)]
pub struct PulledRowReply {
    pub position: u64,
    pub record: String,
    pub ciphertext: String,
}

#[derive(Debug, Serialize)]
pub struct PullReply {
    pub rows: Vec<PulledRowReply>,
    pub more: bool,
}

impl PullReply {
    pub fn new(rows: Vec<sync::PulledRow>, more: bool) -> Self {
        Self {
            rows: rows
                .into_iter()
                .map(|row| PulledRowReply {
                    position: row.position,
                    record: WorkspaceId(row.record).to_hex(),
                    ciphertext: encode(&row.ciphertext),
                })
                .collect(),
            more,
        }
    }
}

pub fn parse_json<'a, T: Deserialize<'a>>(body: &'a [u8]) -> Result<T, ApiError> {
    serde_json::from_slice(body).map_err(|_| ApiError::BadRequest)
}

/// Days since the Unix epoch, UTC: what a proof of work is bound to. Today
/// and yesterday are accepted, so work done just before midnight counts.
pub fn pow_day_ok(day: u32, now_ms: u64) -> bool {
    let today = now_ms / 86_400_000;
    u64::from(day) == today || u64::from(day) + 1 == today
}

#[cfg(test)]
mod tests {
    use super::*;

    const WS: &str = "6d6f6475736e6f746573766563746f72";

    fn ws() -> WorkspaceId {
        WorkspaceId::parse_hex(WS).unwrap()
    }

    #[test]
    fn routes_the_api() {
        let at = |m: &str, p: &str, q: Option<&str>| route(m, &format!("/api/w/{WS}{p}"), q);
        assert_eq!(route("GET", "/api/info", None), Ok(Route::Info));
        assert_eq!(at("POST", "", None), Ok(Route::Found(ws())));
        assert_eq!(at("DELETE", "", None), Ok(Route::DeleteWorkspace(ws())));
        assert_eq!(at("GET", "/heads", None), Ok(Route::Heads(ws())));
        assert_eq!(at("GET", "/membership", Some("from=3")), Ok(Route::Membership(ws(), 3)));
        assert_eq!(at("POST", "/membership", None), Ok(Route::AppendRecord(ws())));
        assert_eq!(at("GET", "/bundles", Some("after=0")), Ok(Route::Bundles(ws(), 0)));
        assert_eq!(at("POST", "/rows", None), Ok(Route::Push(ws())));
        assert_eq!(at("GET", "/rows", Some("after=12")), Ok(Route::Pull(ws(), 12)));
        assert_eq!(at("GET", "/blobs", None), Ok(Route::ListBlobs(ws(), None)));
        assert_eq!(at("GET", "/blobs", Some("after=a_b-9")), Ok(Route::ListBlobs(ws(), Some("a_b-9".into()))));
        assert_eq!(at("PUT", "/blobs/x1", None), Ok(Route::PutBlob(ws(), "x1".into())));
        assert_eq!(at("GET", "/blobs/x1", None), Ok(Route::GetBlob(ws(), "x1".into())));
        assert_eq!(at("POST", "/blobs/delete", None), Ok(Route::DeleteBlobs(ws())));
        assert_eq!(at("POST", "/codes/ABC123", None), Ok(Route::PostOffer(ws(), "ABC123".into())));
        assert_eq!(route("GET", "/api/codes/ABC123", None), Ok(Route::Offer("ABC123".into())));
        assert_eq!(route("DELETE", "/api/codes/ABC123", None), Ok(Route::CloseCode("ABC123".into())));
        assert_eq!(route("POST", "/api/codes/ABC123/answers", None), Ok(Route::Answer("ABC123".into())));
        assert_eq!(route("GET", "/api/codes/ABC123/answers", None), Ok(Route::Answers("ABC123".into())));
    }

    #[test]
    fn anything_else_is_not_found_or_not_allowed() {
        let at = |m: &str, p: &str, q: Option<&str>| route(m, &format!("/api/w/{WS}{p}"), q);
        assert_eq!(route("GET", "/info", None), Err(ApiError::NotFound));
        assert_eq!(route("GET", "/api/w/ABCDEF", None), Err(ApiError::NotFound));
        assert_eq!(at("GET", "/rows", None), Err(ApiError::NotFound));
        assert_eq!(at("GET", "/rows", Some("after=01")), Err(ApiError::NotFound));
        assert_eq!(at("GET", "/rows", Some("after=1&x=2")), Err(ApiError::NotFound));
        assert_eq!(at("GET", "/heads", Some("x=1")), Err(ApiError::NotFound));
        assert_eq!(at("POST", "/heads", None), Err(ApiError::MethodNotAllowed));
        assert_eq!(at("PATCH", "/rows", None), Err(ApiError::MethodNotAllowed));
        assert_eq!(at("GET", "/blobs/..", None), Err(ApiError::NotFound));
        assert_eq!(route("GET", "/api/codes/abc123", None), Err(ApiError::NotFound));
        assert_eq!(route("GET", "/api/codes/ABCI23", None), Err(ApiError::NotFound));
        assert_eq!(route("GET", "/api/w", None), Err(ApiError::NotFound));
    }

    #[test]
    fn the_live_channel_is_a_get_upgrade_throttled_as_a_write() {
        let live = route("GET", &format!("/api/w/{WS}/live"), None);

        assert_eq!(live, Ok(Route::Live(ws())));
        assert_eq!(live.as_ref().map(Route::workspace), Ok(Some(ws())));
        assert!(live.as_ref().is_ok_and(|live| live.writes() && !live.takes_json()));
        assert_eq!(route("POST", &format!("/api/w/{WS}/live"), None), Err(ApiError::MethodNotAllowed));
        assert_eq!(route("GET", &format!("/api/w/{WS}/live"), Some("t=1")), Err(ApiError::NotFound));
    }

    #[test]
    fn the_handshake_offers_our_protocol_and_exactly_one_token() {
        let token = "mn1.k.1.n.s";
        fn ours(protocols: &str) -> Result<&str, ApiError> {
            live_token(Some("websocket"), Some(protocols))
        }

        assert_eq!(ours("modusnote.live.v1, mn1.k.1.n.s"), Ok(token));
        assert_eq!(ours("mn1.k.1.n.s,modusnote.live.v1"), Ok(token));
        assert_eq!(live_token(Some("WebSocket"), Some("modusnote.live.v1, mn1.k.1.n.s")), Ok(token));
        assert_eq!(live_token(None, Some("modusnote.live.v1, mn1.k.1.n.s")), Err(ApiError::UpgradeRequired));
        assert_eq!(live_token(Some("h2c"), Some("modusnote.live.v1, mn1.k.1.n.s")), Err(ApiError::UpgradeRequired));
        assert_eq!(live_token(Some("websocket"), None), Err(ApiError::UpgradeRequired));
        assert_eq!(ours("mn1.k.1.n.s"), Err(ApiError::UpgradeRequired));
        assert_eq!(ours("modusnote.live.v2, mn1.k.1.n.s"), Err(ApiError::UpgradeRequired));
        assert_eq!(ours("modusnote.live.v1"), Err(ApiError::Unauthenticated));
        assert_eq!(ours("modusnote.live.v1, mn1.a, mn1.b"), Err(ApiError::Unauthenticated));
        assert_eq!(ApiError::UpgradeRequired.status(), 426);
        assert_eq!(ApiError::UpgradeRequired.body(0), r#"{"error":"upgrade_required"}"#);
    }

    #[test]
    fn errors_have_fixed_bodies_and_the_clock_tells_the_time() {
        assert_eq!(ApiError::Forbidden.body(5), r#"{"error":"forbidden"}"#);
        assert_eq!(ApiError::Clock.body(1792700000000), r#"{"error":"clock","now":1792700000000}"#);
        assert_eq!(ApiError::from(SyncError::Full).status(), 413);
        assert_eq!(ApiError::from(SyncError::Denied(Denied::Replayed)).status(), 401);
    }

    #[test]
    fn origins_and_addresses() {
        assert!(check_origin(None, "https://modus.serv.run").is_ok());
        assert!(check_origin(Some("https://modus.serv.run"), "https://modus.serv.run").is_ok());
        assert_eq!(check_origin(Some("https://evil.example"), "https://modus.serv.run"), Err(ApiError::CrossOrigin));
        assert_eq!(limiter_key("2001:db8:1:2:3:4:5:6"), "2001:db8:1:2::/64");
        assert_eq!(network_key("2001:db8:1:2:3:4:5:6"), Some("2001:db8:1::/48".into()));
        assert_eq!(limiter_key("::ffff:1.2.3.4"), "1.2.3.4");
        assert_eq!(network_key("1.2.3.4"), None);
    }

    #[test]
    fn lengths_and_days() {
        assert_eq!(declared_length(Some("10"), 10), Ok(10));
        assert_eq!(declared_length(Some("11"), 10), Err(ApiError::TooLarge));
        assert_eq!(declared_length(None, 10), Err(ApiError::LengthRequired));
        assert_eq!(declared_length(Some("-1"), 10), Err(ApiError::LengthRequired));
        let now = 20_000 * 86_400_000 + 5;
        assert!(pow_day_ok(20_000, now));
        assert!(pow_day_ok(19_999, now));
        assert!(!pow_day_ok(19_998, now));
        assert!(!pow_day_ok(20_001, now));
    }

    #[test]
    fn ranges_limiters_and_settings() {
        assert_eq!(byte_range(Some("bytes=0-99")), Some((0, Some(99))));
        assert_eq!(byte_range(Some("bytes=100-")), Some((100, None)));
        assert_eq!(byte_range(Some("bytes=9-3")), None);
        assert_eq!(byte_range(Some("bytes=-5")), None);
        assert_eq!(byte_range(Some("bytes=0-1,4-5")), None);
        assert_eq!(byte_range(Some("items=0-1")), None);
        assert_eq!(byte_range(None), None);
        assert!(throttled(true, None));
        assert!(!throttled(false, None));
        assert!(throttled(false, Some(false)));
        assert_eq!(setting(Some(" 12 "), 5), 12);
        assert_eq!(setting(Some("0"), 5), 5);
        assert_eq!(setting(Some("x"), 5), 5);
        assert_eq!(setting(None, 5), 5);
    }

    #[test]
    fn bodies_parse_strictly() {
        let push: PushBody =
            parse_json(format!(r#"{{"rows":[{{"record":"{WS}","ciphertext":"AQI=","supersedes":3}}]}}"#).as_bytes())
                .unwrap();
        let rows = push.rows().unwrap();
        assert_eq!((rows[0].ciphertext.clone(), rows[0].supersedes), (vec![1, 2], 3));
        assert!(parse_json::<PushBody>(br#"{"rows":[],"extra":1}"#).is_err());
        let bad: PushBody = parse_json(br#"{"rows":[{"record":"zz","ciphertext":"AQI=","supersedes":0}]}"#).unwrap();
        assert_eq!(bad.rows().unwrap_err(), ApiError::BadRequest);
    }
}
