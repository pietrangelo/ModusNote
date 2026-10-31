//! The Workers runtime: the request door, the three Durable Objects and R2.
//!
//! The Worker routes, checks the origin, throttles by address, reads a JSON
//! body only once its declared length fits, checks a proof of work where
//! one is due and spends from the guard's daily ceilings; then it hands the
//! device's own request (method, path, `Authorization`, body) to the object
//! that owns it, which verifies the signature against its log. Blob bodies
//! never pass through an object: once the workspace's object has said yes,
//! the Worker streams them between the device and R2.
//!
//! The live channel is the one call the Worker hands over as it came, with
//! its upgrade headers: the workspace's object accepts the WebSocket with
//! the Hibernation API (the key as its tag, the time in its attachment, the
//! `ping` answered without waking it) and, after every write, tells the
//! other members' sockets the heads; nothing about them is kept in memory.

use std::cell::RefCell;

use crypto::StrictEd25519;
use js_sys::{Array, Object, Reflect, Uint8Array};
use ledger::{MemberKey, WorkspaceId};
use publish::{MediaType, Site, SiteLimits};
use sync::{Budget, Guard, Limits, Rendezvous, Socket, Store, Unavailable, Workspace, admit_socket};
use wasm_bindgen::prelude::*;
use worker::{
    Bucket, Context, Data, Date, DurableObject, Env, Headers, Method, ObjectNamespace, Range, Request, RequestInit,
    Response, ResponseBody, ResponseBuilder, Result, ScheduledTime, State, Stub, WebSocket, WebSocketIncomingMessage,
    WebSocketPair, WebSocketRequestResponsePair, durable_object, event,
};

use crate::api::{self, ApiError, InfoReply, LIVE_PROTOCOL, POW_BITS, Route};
use crate::serve::{
    self, BLOB_SIZE, Blake2b, CLOSE_EVICTED, CLOSE_GONE, CLOSE_POLICY, CLOSE_REMOVED, Done, INTERNAL_OFFER,
    INTERNAL_SPEND, Incoming, SiteDone,
};

/// Every object is created in the EU.
const JURISDICTION: &str = "eu";
const WORKSPACES: &str = "WORKSPACES";
const CODES: &str = "CODES";
const GUARD: &str = "GUARD";
const GUARD_NAME: &str = "guard";
const BLOBS: &str = "BLOBS";
const SITES: &str = "SITES";
/// The workspace an object holds, kept beside the use case's keys so the
/// alarm knows which prefix of R2 to clear.
const NAME: &str = "name";
/// Present while a deleted workspace's blobs are still in R2; the object
/// answers 503 until they are gone, so nothing new lands under the prefix.
const PURGE: &str = "purge";
const DAY_MS: u64 = 86_400_000;
/// How often a purge that did not finish tries again.
const RETRY_MS: u64 = 60_000;
/// Rounds of 1000 objects one purge deletes before it yields.
const PURGE_ROUNDS: usize = 20;

#[wasm_bindgen]
extern "C" {
    /// `ctx.storage` of a SQLite-backed Durable Object.
    #[derive(Clone)]
    type SyncStorage;

    #[wasm_bindgen(method, getter)]
    fn kv(this: &SyncStorage) -> SyncKv;

    #[wasm_bindgen(method, catch, js_name = transactionSync)]
    fn transaction_sync(
        this: &SyncStorage,
        step: &mut dyn FnMut() -> std::result::Result<JsValue, JsValue>,
    ) -> std::result::Result<JsValue, JsValue>;

    /// `ctx.storage.kv`: synchronous, so a run of calls is one write.
    #[derive(Clone)]
    type SyncKv;

    #[wasm_bindgen(method, catch)]
    fn get(this: &SyncKv, key: &str) -> std::result::Result<JsValue, JsValue>;

    #[wasm_bindgen(method, catch)]
    fn put(this: &SyncKv, key: &str, value: &Uint8Array) -> std::result::Result<(), JsValue>;

    #[wasm_bindgen(method, catch)]
    fn delete(this: &SyncKv, key: &str) -> std::result::Result<bool, JsValue>;

    #[wasm_bindgen(method, catch)]
    fn list(this: &SyncKv, options: &Object) -> std::result::Result<JsValue, JsValue>;
}

fn unavailable<E>(_: E) -> Unavailable {
    Unavailable
}

/// A Durable Object's own storage, through its synchronous API: the port
/// [`Store`] of the use cases.
struct DurableKv {
    storage: SyncStorage,
    kv: SyncKv,
}

impl std::fmt::Debug for DurableKv {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("DurableKv")
    }
}

impl DurableKv {
    fn new(state: &State) -> Self {
        let raw: JsValue = AsRef::<JsValue>::as_ref(state.storage().as_raw()).clone();
        let storage: SyncStorage = raw.unchecked_into();
        let kv = storage.kv();
        Self { storage, kv }
    }

    fn text(&self, key: &str) -> Option<String> {
        self.get(key).ok().flatten().and_then(|bytes| String::from_utf8(bytes).ok())
    }
}

impl Store for DurableKv {
    fn get(&self, key: &str) -> std::result::Result<Option<Vec<u8>>, Unavailable> {
        let value = self.kv.get(key).map_err(unavailable)?;
        if value.is_undefined() {
            return Ok(None);
        }
        Ok(Some(Uint8Array::new(&value).to_vec()))
    }

    fn put(&mut self, key: &str, value: &[u8]) -> std::result::Result<(), Unavailable> {
        self.kv.put(key, &Uint8Array::from(value)).map_err(unavailable)
    }

    fn delete(&mut self, key: &str) -> std::result::Result<(), Unavailable> {
        self.kv.delete(key).map(drop).map_err(unavailable)
    }

    fn list(
        &self,
        prefix: &str,
        start_after: Option<&str>,
        limit: usize,
    ) -> std::result::Result<Vec<(String, Vec<u8>)>, Unavailable> {
        let options = Object::new();
        Reflect::set(&options, &"prefix".into(), &prefix.into()).map_err(unavailable)?;
        if let Some(after) = start_after {
            Reflect::set(&options, &"startAfter".into(), &after.into()).map_err(unavailable)?;
        }
        if limit < u32::MAX as usize {
            Reflect::set(&options, &"limit".into(), &(limit as f64).into()).map_err(unavailable)?;
        }
        let listed = self.kv.list(&options).map_err(unavailable)?;
        let entries = js_sys::try_iter(&listed).map_err(unavailable)?.ok_or(Unavailable)?;
        let mut out = Vec::new();
        for entry in entries {
            let pair: Array = entry.map_err(unavailable)?.unchecked_into();
            let key = pair.get(0).as_string().ok_or(Unavailable)?;
            out.push((key, Uint8Array::new(&pair.get(1)).to_vec()));
        }
        Ok(out)
    }

    fn transaction<T, E: From<Unavailable>>(
        &mut self,
        step: impl FnOnce(&mut Self) -> std::result::Result<T, E>,
    ) -> std::result::Result<T, E> {
        let storage = self.storage.clone();
        let mut step = Some(step);
        let mut outcome = None;
        let committed = {
            let mut run = || {
                let result = step.take().map(|step| step(self));
                let failed = !matches!(result, Some(Ok(_)));
                outcome = result;
                // Throwing is how a transaction is rolled back.
                if failed { Err(JsValue::from_str("rolled back")) } else { Ok(JsValue::UNDEFINED) }
            };
            storage.transaction_sync(&mut run)
        };
        match (outcome, committed) {
            (Some(Ok(value)), Ok(_)) => Ok(value),
            (Some(Err(error)), _) => Err(error),
            _ => Err(Unavailable.into()),
        }
    }

    fn clear(&mut self) -> std::result::Result<(), Unavailable> {
        loop {
            let page = self.list("", None, 256)?;
            if page.is_empty() {
                return Ok(());
            }
            for (key, _) in page {
                self.delete(&key)?;
            }
        }
    }
}

fn now_ms() -> u64 {
    Date::now().as_millis()
}

fn at(ms: u64) -> ScheduledTime {
    ScheduledTime::new(js_sys::Date::new(&JsValue::from_f64(ms as f64)))
}

fn plain_headers(headers: &Headers, content_type: &str) -> Result<()> {
    headers.set("Content-Type", content_type)?;
    headers.set("Cache-Control", "no-store")?;
    headers.set("X-Content-Type-Options", "nosniff")?;
    headers.set("Referrer-Policy", "no-referrer")?;
    Ok(())
}

fn respond(status: u16, body: String) -> Result<Response> {
    let mut response = Response::ok(body)?.with_status(status);
    plain_headers(response.headers_mut(), "application/json")?;
    Ok(response)
}

fn fail(error: ApiError) -> Result<Response> {
    respond(error.status(), error.body(now_ms()))
}

impl From<worker::Error> for ApiError {
    fn from(_: worker::Error) -> Self {
        Self::Unavailable
    }
}

/// Where the objects live: in the EU. `OBJECT_PLACEMENT = "local"` exists
/// only for `wrangler dev`, whose runtime has no jurisdictions.
fn stub(env: &Env, binding: &str, name: &str) -> Result<Stub> {
    let namespace = env.durable_object(binding)?;
    if env.var("OBJECT_PLACEMENT").is_ok_and(|v| v.to_string() == "local") {
        return namespace.get_by_name(name);
    }
    let jurisdiction = Reflect::get(namespace.as_ref(), &"jurisdiction".into())?;
    let restricted =
        jurisdiction.unchecked_into::<js_sys::Function>().call1(namespace.as_ref(), &JURISDICTION.into())?;
    restricted.unchecked_into::<ObjectNamespace>().get_by_name(name)
}

/// Hands a call to an object. The host means nothing: a stub's fetch never
/// leaves Cloudflare.
async fn relay(
    stub: &Stub,
    method: &str,
    target: &str,
    authorization: Option<&str>,
    body: &[u8],
    blob_size: Option<u64>,
) -> Result<Response> {
    let headers = Headers::new();
    if let Some(authorization) = authorization {
        headers.set("Authorization", authorization)?;
    }
    if let Some(size) = blob_size {
        headers.set(BLOB_SIZE, &size.to_string())?;
    }
    let mut init = RequestInit::new();
    init.with_method(Method::from(method.to_owned())).with_headers(headers);
    if !body.is_empty() {
        init.with_body(Some(Uint8Array::from(body).into()));
    }
    stub.fetch_with_request(Request::new_with_init(&format!("https://object{target}"), &init)?).await
}

/// What an object received, read once.
struct Received {
    method: String,
    path: String,
    query: Option<String>,
    authorization: Option<String>,
    blob_size: Option<String>,
    upgrade: Option<String>,
    protocols: Option<String>,
    body: Vec<u8>,
}

impl Received {
    async fn read(mut req: Request) -> Result<Self> {
        let url = req.url()?;
        Ok(Self {
            method: req.method().to_string(),
            path: url.path().to_owned(),
            query: url.query().map(str::to_owned),
            authorization: req.headers().get("Authorization")?,
            blob_size: req.headers().get(BLOB_SIZE)?,
            upgrade: req.headers().get("Upgrade")?,
            protocols: req.headers().get("Sec-WebSocket-Protocol")?,
            body: req.bytes().await?,
        })
    }

    fn incoming(&self, now_ms: u64) -> Incoming<'_> {
        Incoming {
            method: &self.method,
            path: &self.path,
            query: self.query.as_deref(),
            authorization: self.authorization.as_deref(),
            body: &self.body,
            blob_size: self.blob_size.as_deref(),
            upgrade: self.upgrade.as_deref(),
            protocols: self.protocols.as_deref(),
            now_ms,
        }
    }
}

fn blob_key(workspace: &str, id: &str) -> String {
    format!("{workspace}/{id}.enc")
}

/// Deletes every object under a workspace's prefix, a few thousand at a
/// time; true when none is left.
async fn purge_blobs(bucket: &Bucket, workspace: &str) -> Result<bool> {
    let prefix = format!("{workspace}/");
    for _ in 0..PURGE_ROUNDS {
        let listed = bucket.list().prefix(prefix.clone()).limit(1000).execute().await?;
        let keys: Vec<String> = listed.objects().iter().map(|object| object.key()).collect();
        if keys.is_empty() {
            return Ok(true);
        }
        bucket.delete_multiple(keys).await?;
        if !listed.truncated() {
            return Ok(true);
        }
    }
    Ok(false)
}

type Space = Workspace<DurableKv, StrictEd25519>;

/// What the idle alarm finds.
enum Idle {
    /// Nothing is kept (never founded, or deleted).
    Gone,
    /// Unused for too long: deleted now, its blobs follow.
    Expired,
    /// In use: look again then.
    Until(u64),
}

/// One workspace: its log, bundles, rows, blob reservations and nonces, in
/// the object's own SQLite storage; an alarm deletes it after
/// [`Limits::idle_days`] without a signed request. Its members' live
/// sockets are hibernatable WebSockets: bare `#[durable_object]` binds the
/// alarm and the WebSocket handlers together.
#[durable_object]
pub struct ModusWorkspace {
    state: State,
    env: Env,
    space: RefCell<Option<Space>>,
}

impl std::fmt::Debug for ModusWorkspace {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("ModusWorkspace")
    }
}

impl ModusWorkspace {
    /// Runs `step` on the use case; nothing awaits inside, so one call is
    /// one step of the object.
    fn with_space<T>(&self, step: impl FnOnce(&mut Space) -> T) -> T {
        let mut slot = self.space.borrow_mut();
        let space =
            slot.get_or_insert_with(|| Workspace::new(DurableKv::new(&self.state), StrictEd25519, Limits::default()));
        step(space)
    }

    /// Clears R2 under a deleted workspace's prefix, or leaves the mark and
    /// an alarm to try again.
    async fn purge(&self, workspace: &str) -> Result<()> {
        let mut kv = DurableKv::new(&self.state);
        kv.put(PURGE, workspace.as_bytes()).map_err(|_| worker::Error::RustError("storage".into()))?;
        let done = purge_blobs(&self.env.bucket(BLOBS)?, workspace).await.unwrap_or(false);
        if done {
            let _ = kv.delete(PURGE);
        } else {
            self.state.storage().set_alarm(at(now_ms() + RETRY_MS)).await?;
        }
        Ok(())
    }

    /// Every live socket the object still holds, with the key, time and
    /// state each carries, and how many the runtime lists in all. A socket
    /// the object closed stays held, closing, until the peer answers, and
    /// counts until then; a closed one no longer does.
    fn sockets(&self) -> (Vec<(WebSocket, Socket)>, usize) {
        const OPEN: u16 = 1;
        const CLOSED: u16 = 3;
        let all = self.state.get_websockets();
        let held = all.len();
        let sockets = all
            .into_iter()
            .filter_map(|ws| {
                let state = AsRef::<worker::web_sys::WebSocket>::as_ref(&ws).ready_state();
                if state == CLOSED {
                    return None;
                }
                let accepted = ws.deserialize_attachment::<u64>().ok().flatten();
                let socket = serve::socket_of(&self.state.get_tags(&ws), accepted, state == OPEN)?;
                Some((ws, socket))
            })
            .collect();
        (sockets, held)
    }

    /// Accepts a member's live socket, after pushing out its key's oldest
    /// past the limit; 429 when the workspace holds too many, before the
    /// runtime is asked (its own limit would end the object).
    fn open_live(&self, key: &MemberKey) -> Result<Response> {
        let (sockets, held) = self.sockets();
        let listed: Vec<Socket> = sockets.iter().map(|(_, socket)| *socket).collect();
        let evicted = match admit_socket(&listed, held, key) {
            Ok(evicted) => evicted,
            Err(error) => return fail(error.into()),
        };
        for i in evicted {
            let _ = sockets[i].0.close(Some(CLOSE_EVICTED), Some("evicted"));
        }
        let pair = WebSocketPair::new()?;
        self.state.set_websocket_auto_response(&WebSocketRequestResponsePair::new("ping", "pong")?);
        self.state.accept_websocket_with_tags(&pair.server, &[&serve::socket_tag(key)]);
        if pair.server.serialize_attachment(now_ms()).is_err() {
            let _ = pair.server.close(Some(1011), Some("unavailable"));
            return fail(ApiError::Unavailable);
        }
        Ok(ResponseBuilder::new()
            .with_status(101)
            .with_websocket(pair.client)
            .with_header("Sec-WebSocket-Protocol", LIVE_PROTOCOL)?
            .empty())
    }

    /// After a write: the heads to the other members, a close to every
    /// socket whose key the log no longer has. Nothing here can fail the
    /// write, which has landed.
    fn fan_out(&self, author: &MemberKey) {
        let (sockets, _) = self.sockets();
        if sockets.is_empty() {
            return;
        }
        let listed: Vec<Socket> = sockets.iter().map(|(_, socket)| *socket).collect();
        let Ok(fanout) = self.with_space(|space| space.fanout(&listed, author)) else { return };
        let message = serve::heads_message(fanout.heads);
        for i in fanout.notify {
            let _ = sockets[i].0.send_with_str(&message);
        }
        for i in fanout.close {
            let _ = sockets[i].0.close(Some(CLOSE_REMOVED), Some("removed"));
        }
    }

    /// The workspace is gone: every socket closes.
    fn close_all(&self) {
        for ws in self.state.get_websockets() {
            let _ = ws.close(Some(CLOSE_GONE), Some("gone"));
        }
    }

    async fn keep_alarm(&self) -> Result<()> {
        let storage = self.state.storage();
        if storage.get_alarm().await?.is_none() {
            storage.set_alarm(at(now_ms() + Limits::default().idle_days * DAY_MS)).await?;
        }
        Ok(())
    }
}

impl DurableObject for ModusWorkspace {
    fn new(state: State, env: Env) -> Self {
        Self { state, env, space: RefCell::new(None) }
    }

    async fn fetch(&self, req: Request) -> Result<Response> {
        let received = Received::read(req).await?;
        let Ok(route) = api::route(&received.method, &received.path, received.query.as_deref()) else {
            return fail(ApiError::NotFound);
        };
        let Some(workspace) = route.workspace().map(|ws| ws.to_hex()) else { return fail(ApiError::NotFound) };
        let mut kv = DurableKv::new(&self.state);
        if kv.get(PURGE).ok().flatten().is_some() {
            return fail(ApiError::Unavailable);
        }
        let done = self.with_space(|space| serve::workspace(space, &Blake2b, &received.incoming(now_ms())));
        let done = match done {
            Ok(done) => done,
            Err(error) => return fail(error),
        };
        if kv.get(NAME).ok().flatten().is_none() && !matches!(done, Done::Deleted) {
            let _ = kv.put(NAME, workspace.as_bytes());
        }
        self.keep_alarm().await?;
        match done {
            Done::Json(status, body) => respond(status, body),
            Done::Wrote { status, body, author } => {
                self.fan_out(&author);
                respond(status, body)
            }
            Done::Live(key) => self.open_live(&key),
            Done::Deleted => {
                self.close_all();
                self.purge(&workspace).await?;
                respond(200, "{}".into())
            }
            Done::Released(ids) => {
                let keys: Vec<String> = ids.iter().map(|id| blob_key(&workspace, id)).collect();
                match self.env.bucket(BLOBS)?.delete_multiple(keys).await {
                    Ok(()) => respond(200, "{}".into()),
                    Err(_) => fail(ApiError::Unavailable),
                }
            }
            Done::Offer { poster, sealed } => {
                let mut response = Response::from_bytes([poster.0.as_slice(), &sealed].concat())?;
                plain_headers(response.headers_mut(), "application/octet-stream")?;
                Ok(response)
            }
        }
    }

    async fn alarm(&self) -> Result<Response> {
        let kv = DurableKv::new(&self.state);
        if let Some(workspace) = kv.text(PURGE) {
            self.purge(&workspace).await?;
            return Response::ok("");
        }
        let now = now_ms();
        let idle = Limits::default().idle_days * DAY_MS;
        let name = kv.text(NAME);
        let outcome = self.with_space(|space| -> std::result::Result<Idle, sync::SyncError> {
            Ok(match space.last_seen_ms()? {
                None => Idle::Gone,
                Some(_) if space.expire(now)? => Idle::Expired,
                Some(seen) => Idle::Until(seen + idle),
            })
        });
        match (outcome, name) {
            (Ok(Idle::Expired), Some(workspace)) => {
                self.close_all();
                self.purge(&workspace).await?
            }
            (Ok(Idle::Until(next)), _) => self.state.storage().set_alarm(at(next.max(now + 1))).await?,
            (Err(_), _) => self.state.storage().set_alarm(at(now + RETRY_MS)).await?,
            _ => {}
        }
        Response::ok("")
    }

    /// A device sends nothing but `ping`, which the runtime answers without
    /// waking the object; anything else closes that socket, unread.
    async fn websocket_message(&self, ws: WebSocket, _message: WebSocketIncomingMessage) -> Result<()> {
        let _ = ws.close(Some(CLOSE_POLICY), Some("policy"));
        Ok(())
    }

    /// A device's close is answered (the runtime does not, at this
    /// compatibility date); one the object started is already closing, and
    /// closing again fails harmlessly.
    async fn websocket_close(&self, ws: WebSocket, _code: usize, _reason: String, _clean: bool) -> Result<()> {
        let _ = ws.close(Some(1000), Some("bye"));
        Ok(())
    }

    async fn websocket_error(&self, _ws: WebSocket, _error: worker::Error) -> Result<()> {
        Ok(())
    }

    /// Bare `#[durable_object]` binds TCP connections too; nothing opens one.
    async fn connect(&self, _socket: worker::Socket) -> Result<()> {
        Err(worker::Error::RustError("no connections".into()))
    }
}

/// One code's lookup: an owner's offer and the answers to it, for fifteen
/// minutes; then an alarm forgets them.
#[durable_object(alarm)]
pub struct ModusRendezvous {
    state: State,
    meeting: RefCell<Option<Rendezvous<DurableKv, StrictEd25519>>>,
}

impl std::fmt::Debug for ModusRendezvous {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("ModusRendezvous")
    }
}

impl ModusRendezvous {
    fn with_meeting<T>(&self, step: impl FnOnce(&mut Rendezvous<DurableKv, StrictEd25519>) -> T) -> T {
        let mut slot = self.meeting.borrow_mut();
        step(slot.get_or_insert_with(|| Rendezvous::new(DurableKv::new(&self.state), StrictEd25519)))
    }
}

impl DurableObject for ModusRendezvous {
    fn new(state: State, _env: Env) -> Self {
        Self { state, meeting: RefCell::new(None) }
    }

    async fn fetch(&self, req: Request) -> Result<Response> {
        let received = Received::read(req).await?;
        let outcome = self.with_meeting(|meeting| serve::rendezvous(meeting, &Blake2b, &received.incoming(now_ms())));
        match outcome {
            Ok((status, body)) => {
                if received.path == INTERNAL_OFFER
                    && let Ok(Some(expires)) = self.with_meeting(|meeting| meeting.expires_ms())
                {
                    self.state.storage().set_alarm(at(expires)).await?;
                }
                respond(status, body)
            }
            Err(error) => fail(error),
        }
    }

    async fn alarm(&self) -> Result<Response> {
        let now = now_ms();
        let _ = self.with_meeting(|meeting| meeting.expire(now));
        if let Ok(Some(expires)) = self.with_meeting(|meeting| meeting.expires_ms())
            && expires > now
        {
            self.state.storage().set_alarm(at(expires)).await?;
        }
        Response::ok("")
    }
}

/// The daily ceilings of the whole service, in one object.
#[durable_object(fetch)]
pub struct ModusGuard {
    state: State,
}

impl std::fmt::Debug for ModusGuard {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("ModusGuard")
    }
}

impl DurableObject for ModusGuard {
    fn new(state: State, _env: Env) -> Self {
        Self { state }
    }

    async fn fetch(&self, req: Request) -> Result<Response> {
        let received = Received::read(req).await?;
        let mut guard = Guard::new(DurableKv::new(&self.state));
        match serve::guard(&mut guard, &received.incoming(now_ms())) {
            Ok(admitted) => respond(200, if admitted { "1" } else { "0" }.into()),
            Err(error) => fail(error),
        }
    }
}

/// One site on serv.pub, named by the site's name: its owner's key, its
/// settings, its pages and the list of its files (their bytes are in R2
/// under `pub/<site>/`). Reads come from the pages Worker, writes from the
/// app through `/api/s/`.
#[durable_object(fetch)]
pub struct ModusSite {
    state: State,
}

impl std::fmt::Debug for ModusSite {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("ModusSite")
    }
}

impl DurableObject for ModusSite {
    fn new(state: State, _env: Env) -> Self {
        Self { state }
    }

    async fn fetch(&self, req: Request) -> Result<Response> {
        let received = Received::read(req).await?;
        let name = self.state.id().name().unwrap_or_default();
        let mut site = Site::new(&name, DurableKv::new(&self.state), StrictEd25519);
        match serve::site(&mut site, &Blake2b, &received.incoming(now_ms())) {
            Ok(SiteDone::Json(status, body)) => respond(status, body),
            Ok(SiteDone::Html(html)) => text_response(html, "text/html; charset=utf-8"),
            Ok(SiteDone::Css(css)) => text_response(css, "text/css; charset=utf-8"),
            Ok(SiteDone::Feed(xml)) => text_response(xml, "application/atom+xml; charset=utf-8"),
            Ok(SiteDone::MediaType(kind)) => text_response(kind.name().to_owned(), "text/plain"),
            Err(error) => fail(error),
        }
    }
}

fn text_response(body: String, content_type: &str) -> Result<Response> {
    let mut response = Response::ok(body)?;
    response.headers_mut().set("Content-Type", content_type)?;
    Ok(response)
}

fn media_key(site: &str, id: &str) -> String {
    format!("pub/{site}/{id}")
}

/// A file for a site: its whole body is read (a few MiB at most) so its
/// first bytes can be checked against its declared type, the site's object
/// counts it, then it goes to R2 with that type.
async fn put_media(
    env: &Env,
    req: &mut Request,
    target: &str,
    site: &str,
    id: &str,
    kind: &str,
) -> std::result::Result<Response, ApiError> {
    let kind = MediaType::parse(kind).ok_or(ApiError::NotFound)?;
    let size = api::declared_length(header(req, "Content-Length").as_deref(), SiteLimits::default().media_file)?;
    let body = req.bytes().await?;
    if body.len() as u64 != size {
        return Err(ApiError::BadRequest);
    }
    if !kind.matches(&body) {
        return Err(ApiError::Unprocessable);
    }
    let object = stub(env, SITES, site)?;
    let authorization = header(req, "Authorization");
    let reply = relay(&object, "PUT", target, authorization.as_deref(), b"", Some(size)).await?;
    if reply.status_code() != 200 {
        return Ok(reply);
    }
    spend(env, Budget::UploadBytes, size).await?;
    let metadata = worker::HttpMetadata { content_type: Some(kind.content_type().to_owned()), ..Default::default() };
    env.bucket(BLOBS)?.put(media_key(site, id), body).http_metadata(metadata).execute().await?;
    Ok(respond(201, "{}".into())?)
}

/// A site's write that frees files: once its object has said yes, R2
/// forgets them too.
async fn site_delete(
    env: &Env,
    req: &Request,
    target: &str,
    route: &Route,
    site: &str,
) -> std::result::Result<Response, ApiError> {
    let object = stub(env, SITES, site)?;
    let authorization = header(req, "Authorization");
    let reply = relay(&object, "DELETE", target, authorization.as_deref(), b"", None).await?;
    if reply.status_code() == 200 {
        let bucket = env.bucket(BLOBS)?;
        match route {
            Route::DeleteMedia(_, id) => bucket.delete(media_key(site, id)).await?,
            _ => {
                purge_blobs(&bucket, &format!("pub/{site}")).await?;
            }
        }
    }
    Ok(reply)
}

/// Spends from a daily ceiling; 429 for everyone once it is reached.
async fn spend(env: &Env, budget: Budget, amount: u64) -> std::result::Result<(), ApiError> {
    let (name, default) = match budget {
        Budget::Workspaces => ("DAILY_WORKSPACES", 500),
        Budget::UploadBytes => ("DAILY_UPLOAD_BYTES", 20 << 30),
    };
    let ceiling = api::setting(env.var(name).ok().map(|v| v.to_string()).as_deref(), default);
    let guard = stub(env, GUARD, GUARD_NAME)?;
    let mut reply =
        relay(&guard, "POST", INTERNAL_SPEND, None, &serve::spend_call(budget, amount, ceiling), None).await?;
    match (reply.status_code(), reply.text().await?.as_str()) {
        (200, "1") => Ok(()),
        (200, "0") => Err(ApiError::RateLimited),
        _ => Err(ApiError::Unavailable),
    }
}

/// Throttles every call by client address, IPv6 by /64 and, for writes,
/// also by /48 (kept in Cloudflare's memory, never stored by us).
async fn rate_limited(env: &Env, req: &Request, write: bool) -> bool {
    let binding = if write { "WRITE_LIMITER" } else { "READ_LIMITER" };
    let Ok(limiter) = env.rate_limiter(binding) else { return api::throttled(write, None) };
    let address = req.headers().get("CF-Connecting-IP").ok().flatten().unwrap_or_default();
    if api::throttled(write, limiter.limit(api::limiter_key(&address)).await.ok().map(|o| o.success)) {
        return true;
    }
    let Some(network) = api::network_key(&address).filter(|_| write) else { return false };
    let Ok(limiter) = env.rate_limiter("NETWORK_WRITE_LIMITER") else { return true };
    api::throttled(true, limiter.limit(network).await.ok().map(|o| o.success))
}

fn header(req: &Request, name: &str) -> Option<String> {
    req.headers().get(name).ok().flatten()
}

/// A blob's upload: the workspace's object counts it (signed over an empty
/// body: the note's digest vouches for the content), then the body streams
/// to R2 without being held. The service's daily ceiling is spent only on
/// bytes that reached R2, so a declared length that never arrives, or a
/// retry, costs the other workspaces nothing.
async fn put_blob(
    env: &Env,
    req: &Request,
    target: &str,
    ws: &WorkspaceId,
    id: &str,
) -> std::result::Result<Response, ApiError> {
    let size = api::declared_length(header(req, "Content-Length").as_deref(), Limits::default().blob_bytes)?;
    let object = stub(env, WORKSPACES, &ws.to_hex())?;
    let authorization = header(req, "Authorization");
    let reply = relay(&object, "PUT", target, authorization.as_deref(), b"", Some(size)).await?;
    if reply.status_code() != 200 {
        return Ok(reply);
    }
    let bucket = env.bucket(BLOBS)?;
    let key = blob_key(&ws.to_hex(), id);
    if bucket.head(key.clone()).await?.is_some_and(|stored| stored.size() == size) {
        return Ok(respond(200, "{}".into())?);
    }
    let body = req.inner().body().ok_or(ApiError::LengthRequired)?;
    let stored = bucket.put(key.clone(), Data::ReadableStream(body)).execute().await?;
    if stored.is_none_or(|stored| stored.size() != size) {
        let _ = bucket.delete(key).await;
        return Err(ApiError::BadRequest);
    }
    if let Err(refused) = spend(env, Budget::UploadBytes, size).await {
        let _ = bucket.delete(key).await;
        return Err(refused);
    }
    Ok(respond(201, "{}".into())?)
}

/// A blob's download, whole or in a range, straight from R2.
async fn get_blob(
    env: &Env,
    req: &Request,
    target: &str,
    ws: &WorkspaceId,
    id: &str,
) -> std::result::Result<Response, ApiError> {
    let object = stub(env, WORKSPACES, &ws.to_hex())?;
    let authorization = header(req, "Authorization");
    let reply = relay(&object, "GET", target, authorization.as_deref(), b"", None).await?;
    if reply.status_code() != 200 {
        return Ok(reply);
    }
    let bucket = env.bucket(BLOBS)?;
    let key = blob_key(&ws.to_hex(), id);
    let (found, part) = match api::byte_range(header(req, "Range").as_deref()) {
        None => (bucket.get(key).execute().await?, None),
        Some((first, last)) => {
            let size = bucket.head(key.clone()).await?.ok_or(ApiError::NotFound)?.size();
            if first >= size {
                let mut response = respond(416, r#"{"error":"range"}"#.into())?;
                response.headers_mut().set("Content-Range", &format!("bytes */{size}"))?;
                return Ok(response);
            }
            let last = last.map_or(size - 1, |last| last.min(size - 1));
            let range = Range::OffsetWithLength { offset: first, length: last - first + 1 };
            (bucket.get(key).range(range).execute().await?, Some((first, last, size)))
        }
    };
    let found = found.ok_or(ApiError::NotFound)?;
    let length = match part {
        Some((first, last, _)) => last - first + 1,
        None => found.size(),
    };
    let body: ResponseBody = found.body().ok_or(ApiError::NotFound)?.response_body()?;
    let mut response = Response::from_body(body)?.with_status(if part.is_some() { 206 } else { 200 });
    let headers = response.headers_mut();
    plain_headers(headers, "application/octet-stream")?;
    headers.set("Content-Length", &length.to_string())?;
    headers.set("Accept-Ranges", "bytes")?;
    if let Some((first, last, size)) = part {
        headers.set("Content-Range", &format!("bytes {first}-{last}/{size}"))?;
    }
    Ok(response)
}

/// An owner's offer under a code: the workspace's object checks the owner,
/// then the code's object takes the lookup if it is free.
async fn post_offer(
    env: &Env,
    req: &Request,
    target: &str,
    ws: &WorkspaceId,
    lookup: &str,
    body: &[u8],
) -> std::result::Result<Response, ApiError> {
    let object = stub(env, WORKSPACES, &ws.to_hex())?;
    let authorization = header(req, "Authorization");
    let mut checked = relay(&object, "POST", target, authorization.as_deref(), body, None).await?;
    if checked.status_code() != 200 {
        return Ok(checked);
    }
    let bytes = checked.bytes().await?;
    if bytes.len() < 32 {
        return Err(ApiError::Unavailable);
    }
    let poster = ledger::MemberKey(bytes[..32].try_into().map_err(|_| ApiError::Unavailable)?);
    let handed = serve::offer_call(&poster, ws, &bytes[32..]);
    Ok(relay(&stub(env, CODES, lookup)?, "POST", INTERNAL_OFFER, None, &handed, None).await?)
}

async fn handle(req: &mut Request, env: &Env) -> std::result::Result<Response, ApiError> {
    let url = req.url()?;
    let method = req.method().to_string();
    let route = api::route(&method, url.path(), url.query())?;
    api::check_origin(header(req, "Origin").as_deref(), &url.origin().ascii_serialization())?;
    if rate_limited(env, req, route.writes()).await {
        return Err(ApiError::RateLimited);
    }
    if route == Route::Info {
        let server = env.var("SERVER_ID").map(|v| v.to_string()).map_err(|_| ApiError::Unavailable)?;
        let text =
            serde_json::to_string(&InfoReply { server: &server, pow: POW_BITS }).map_err(|_| ApiError::Unavailable)?;
        return Ok(respond(200, text)?);
    }
    // A body is read only where the route takes one, and only once its
    // declared length fits.
    let body = if route.takes_json() {
        api::declared_length(header(req, "Content-Length").as_deref(), route.max_body())?;
        let body = req.bytes().await?;
        if body.len() as u64 > route.max_body() {
            return Err(ApiError::TooLarge);
        }
        body
    } else {
        Vec::new()
    };
    serve::admit(&route, &body, &Blake2b, now_ms(), POW_BITS)?;
    if matches!(route, Route::Found(_) | Route::ClaimSite(_)) {
        spend(env, Budget::Workspaces, 1).await?;
    }
    let target = match url.query() {
        Some(query) => format!("{}?{query}", url.path()),
        None => url.path().to_owned(),
    };
    match &route {
        // The upgrade headers must reach the object: the request goes as it came.
        Route::Live(ws) => {
            api::live_token(header(req, "Upgrade").as_deref(), header(req, "Sec-WebSocket-Protocol").as_deref())?;
            Ok(stub(env, WORKSPACES, &ws.to_hex())?.fetch_with_request(req.clone()?).await?)
        }
        Route::PutBlob(ws, id) => put_blob(env, req, &target, ws, id).await,
        Route::GetBlob(ws, id) => get_blob(env, req, &target, ws, id).await,
        Route::PostOffer(ws, lookup) => post_offer(env, req, &target, ws, lookup, &body).await,
        Route::PutMedia(site, id, kind) => put_media(env, req, &target, site, id, kind).await,
        Route::DeleteMedia(site, _) | Route::DeleteSite(site) => site_delete(env, req, &target, &route, site).await,
        _ if route.site().is_some() => {
            let object = stub(env, SITES, route.site().unwrap_or_default())?;
            let authorization = header(req, "Authorization");
            Ok(relay(&object, &method, &target, authorization.as_deref(), &body, None).await?)
        }
        _ => {
            let object = match (route.workspace(), route.lookup()) {
                (Some(ws), _) => stub(env, WORKSPACES, &ws.to_hex())?,
                (None, Some(lookup)) => stub(env, CODES, lookup)?,
                (None, None) => return Err(ApiError::NotFound),
            };
            let authorization = header(req, "Authorization");
            Ok(relay(&object, &method, &target, authorization.as_deref(), &body, None).await?)
        }
    }
}

#[event(fetch)]
async fn fetch(mut req: Request, env: Env, _ctx: Context) -> Result<Response> {
    match handle(&mut req, &env).await {
        Ok(response) => Ok(response),
        Err(error) => fail(error),
    }
}
