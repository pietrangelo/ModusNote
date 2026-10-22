//! One workspace, as its Durable Object keeps it: the verified membership
//! log, the key bundles, the sealed rows and the blobs it reserved, with
//! the quotas, and who may do what. Every call is a signed [`Request`]; the
//! roles come from the verified log alone.
//!
//! Keys: `meta`, `log/<sequence>`, `bun/<position>`, `row/<position>` (the
//! record id, then the ciphertext), `idx/<record>/<position>` (to find the
//! rows a new one supersedes), `blob/<id>` (size and time), `nonce/<hex>`.

use ledger::{KeyBundle, MemberKey, Record, Refused, Role, SignatureCheck, VerifiedLedger, WorkspaceId};

use crate::auth::{Caller, Denied, Request, authenticate, decode_u64, ledger_hex};
use crate::limits::Limits;
use crate::store::{Store, Unavailable};

const META: &str = "meta";
const LOG: &str = "log/";
const BUNDLES: &str = "bun/";
const ROWS: &str = "row/";
const INDEX: &str = "idx/";
const BLOBS: &str = "blob/";
const DAY_MS: u64 = 86_400_000;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SyncError {
    Denied(Denied),
    /// No such workspace (404).
    NotFound,
    /// Already there: another first record, or a sequence taken (409).
    Conflict,
    /// Signed data that breaks the rules (422).
    Refused(Refused),
    /// Not a request the API knows (400).
    Malformed(&'static str),
    /// The workspace's quota is used up (413).
    Full,
    /// Today's upload budget is spent (429).
    Throttled,
    Unavailable,
}

impl From<Unavailable> for SyncError {
    fn from(_: Unavailable) -> Self {
        Self::Unavailable
    }
}

impl From<Denied> for SyncError {
    fn from(denied: Denied) -> Self {
        match denied {
            Denied::Unavailable => Self::Unavailable,
            other => Self::Denied(other),
        }
    }
}

impl From<Refused> for SyncError {
    fn from(refused: Refused) -> Self {
        Self::Refused(refused)
    }
}

/// The newest position of each stream, and how many records the log has.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub struct Heads {
    pub rows: u64,
    pub bundles: u64,
    pub membership: u64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PushedRow {
    pub record: [u8; 16],
    pub ciphertext: Vec<u8>,
    /// The position up to which this row supersedes the rows of its record.
    pub supersedes: u64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PulledRow {
    pub position: u64,
    pub record: [u8; 16],
    pub ciphertext: Vec<u8>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BlobEntry {
    pub id: String,
    pub size: u64,
    pub uploaded_ms: u64,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
struct Meta {
    next_row: u64,
    next_bundle: u64,
    bytes: u64,
    blob_bytes: u64,
    upload_day: u64,
    upload_bytes: u64,
    last_seen_ms: u64,
}

impl Meta {
    fn load(store: &impl Store) -> Result<Self, Unavailable> {
        let Some(bytes) = store.get(META)? else { return Ok(Self { next_row: 1, next_bundle: 1, ..Self::default() }) };
        let field = |i: usize| bytes.get(i * 8..i * 8 + 8).map_or(0, decode_u64);
        Ok(Self {
            next_row: field(0),
            next_bundle: field(1),
            bytes: field(2),
            blob_bytes: field(3),
            upload_day: field(4),
            upload_bytes: field(5),
            last_seen_ms: field(6),
        })
    }

    fn save(&self, store: &mut impl Store) -> Result<(), Unavailable> {
        let fields = [
            self.next_row,
            self.next_bundle,
            self.bytes,
            self.blob_bytes,
            self.upload_day,
            self.upload_bytes,
            self.last_seen_ms,
        ];
        let bytes: Vec<u8> = fields.iter().flat_map(|f| f.to_be_bytes()).collect();
        store.put(META, &bytes)
    }
}

#[derive(Debug)]
pub struct Workspace<S, C> {
    store: S,
    check: C,
    limits: Limits,
    ledger: Option<VerifiedLedger>,
}

impl<S: Store, C: SignatureCheck> Workspace<S, C> {
    pub fn new(store: S, check: C, limits: Limits) -> Self {
        Self { store, check, limits, ledger: None }
    }

    pub fn store(&self) -> &S {
        &self.store
    }

    /// The log as stored, verified when it was appended; loaded once.
    fn ledger(&mut self) -> Result<Option<&VerifiedLedger>, SyncError> {
        if self.ledger.is_none() {
            let stored = self.store.list(LOG, None, usize::MAX)?;
            if stored.is_empty() {
                return Ok(None);
            }
            let mut records = Vec::with_capacity(stored.len());
            for (_, wire) in stored {
                records.push(Record::parse(&wire).map_err(|_| SyncError::Unavailable)?);
            }
            self.ledger = Some(VerifiedLedger::restore(records).map_err(|_| SyncError::Unavailable)?);
        }
        Ok(self.ledger.as_ref())
    }

    /// The caller, if a member allowed to do what `allowed` asks of its role.
    fn member(&mut self, request: &Request<'_>, allowed: fn(Role) -> bool) -> Result<(MemberKey, Role), SyncError> {
        if self.ledger()?.is_none() {
            return Err(SyncError::NotFound);
        }
        let Caller { key } = authenticate(&mut self.store, &self.check, request)?;
        let role = self.ledger()?.and_then(|ledger| ledger.workspace().role(&key));
        match role {
            Some(role) if allowed(role) => {
                self.touch(request)?;
                Ok((key, role))
            }
            _ => Err(SyncError::Denied(Denied::Forbidden)),
        }
    }

    /// Remembers that the workspace is in use: at every write, and at most
    /// once a day for reads.
    fn touch(&mut self, request: &Request<'_>) -> Result<(), SyncError> {
        let mut meta = Meta::load(&self.store)?;
        if request.writes() || request.now_ms.saturating_sub(meta.last_seen_ms) >= DAY_MS {
            meta.last_seen_ms = request.now_ms;
            meta.save(&mut self.store)?;
        }
        Ok(())
    }

    /// Registers the workspace with its first record, signed by its founder,
    /// who also signs the request. The same first record again is fine;
    /// another is a conflict: the first registered keeps the id.
    pub fn found(&mut self, request: &Request<'_>, id: WorkspaceId, genesis: &[u8]) -> Result<bool, SyncError> {
        let Caller { key } = authenticate(&mut self.store, &self.check, request)?;
        let record = Record::parse(genesis).map_err(Refused::from)?;
        if record.workspace != id {
            return Err(SyncError::Malformed("record of another workspace"));
        }
        if record.author != key {
            return Err(SyncError::Denied(Denied::Forbidden));
        }
        if let Some(ledger) = self.ledger()? {
            return if ledger.records()[0].wire() == genesis { Ok(false) } else { Err(SyncError::Conflict) };
        }
        let ledger = VerifiedLedger::found(record, &self.check)?;
        let mut meta = Meta::load(&self.store)?;
        meta.bytes = genesis.len() as u64;
        meta.last_seen_ms = request.now_ms;
        self.store.transaction(|store| -> Result<(), SyncError> {
            store.put(&log_key(0), genesis)?;
            meta.save(store)?;
            Ok(())
        })?;
        self.ledger = Some(ledger);
        Ok(true)
    }

    pub fn heads(&mut self, request: &Request<'_>) -> Result<Heads, SyncError> {
        self.member(request, |_| true)?;
        let meta = Meta::load(&self.store)?;
        let membership = self.ledger()?.map_or(0, VerifiedLedger::len) as u64;
        Ok(Heads { rows: meta.next_row - 1, bundles: meta.next_bundle - 1, membership })
    }

    /// Records from sequence `from` on.
    pub fn membership(&mut self, request: &Request<'_>, from: u32) -> Result<Vec<Vec<u8>>, SyncError> {
        self.member(request, |_| true)?;
        let ledger = self.ledger()?.ok_or(SyncError::NotFound)?;
        Ok(ledger.records().iter().skip(from as usize).map(|record| record.wire().to_vec()).collect())
    }

    /// Appends the next record of the log if it extends the verified log.
    /// Whoever relays it must be a member; whether it may be written is the
    /// record's own signature and the rules'.
    pub fn append_record(&mut self, request: &Request<'_>, wire: &[u8]) -> Result<(), SyncError> {
        self.member(request, |_| true)?;
        let record = Record::parse(wire).map_err(Refused::from)?;
        let mut ledger = self.ledger()?.ok_or(SyncError::NotFound)?.clone();
        if (record.sequence as usize) < ledger.len() {
            return Err(SyncError::Conflict);
        }
        let sequence = record.sequence;
        ledger.extend(record, &self.check)?;
        if ledger.workspace().members.len() > self.limits.members {
            return Err(SyncError::Full);
        }
        let limits = self.limits;
        self.store.transaction(|store| -> Result<(), SyncError> {
            let mut meta = Meta::load(store)?;
            meta.bytes += wire.len() as u64;
            if meta.bytes > limits.workspace_bytes {
                return Err(SyncError::Full);
            }
            store.put(&log_key(sequence), wire)?;
            meta.save(store)?;
            Ok(())
        })?;
        self.ledger = Some(ledger);
        Ok(())
    }

    /// Bundles after position `after`, with their positions.
    pub fn bundles(&mut self, request: &Request<'_>, after: u64) -> Result<Vec<(u64, Vec<u8>)>, SyncError> {
        self.member(request, |_| true)?;
        let listed = self.store.list(BUNDLES, Some(&position_key(BUNDLES, after)), self.limits.pull_rows)?;
        Ok(listed.into_iter().map(|(key, wire)| (position_of(&key), wire)).collect())
    }

    /// Stores a bundle that the verified log allows, and returns its position.
    pub fn append_bundle(&mut self, request: &Request<'_>, wire: &[u8]) -> Result<u64, SyncError> {
        self.member(request, |_| true)?;
        let bundle = KeyBundle::parse(wire).map_err(Refused::from)?;
        self.ledger()?;
        let ledger = self.ledger.as_ref().ok_or(SyncError::NotFound)?;
        ledger.check_bundle(&bundle, &self.check)?;
        let limits = self.limits;
        self.store.transaction(|store| {
            let mut meta = Meta::load(store)?;
            meta.bytes += wire.len() as u64;
            if meta.bytes > limits.workspace_bytes {
                return Err(SyncError::Full);
            }
            let position = meta.next_bundle;
            meta.next_bundle += 1;
            store.put(&position_key(BUNDLES, position), wire)?;
            meta.save(store)?;
            Ok(position)
        })
    }

    /// Appends rows in order and drops what each one supersedes; all or
    /// nothing. Only members who write may push.
    pub fn push(&mut self, request: &Request<'_>, rows: &[PushedRow]) -> Result<Vec<u64>, SyncError> {
        self.member(request, Role::writes_content)?;
        if rows.is_empty() || rows.len() > self.limits.rows_per_push {
            return Err(SyncError::Malformed("rows per push"));
        }
        if rows.iter().any(|row| row.ciphertext.is_empty() || row.ciphertext.len() > self.limits.row_bytes) {
            return Err(SyncError::Malformed("row size"));
        }
        let limits = self.limits;
        self.store.transaction(|store| {
            let mut meta = Meta::load(store)?;
            let mut positions = Vec::with_capacity(rows.len());
            for row in rows {
                let position = meta.next_row;
                meta.next_row += 1;
                let mut value = Vec::with_capacity(16 + row.ciphertext.len());
                value.extend_from_slice(&row.record);
                value.extend_from_slice(&row.ciphertext);
                store.put(&position_key(ROWS, position), &value)?;
                store.put(&index_key(&row.record, position), &[])?;
                meta.bytes += value.len() as u64;
                let bound = row.supersedes.min(position - 1);
                if bound > 0 {
                    meta.bytes -= drop_superseded(store, &row.record, bound)?;
                }
                positions.push(position);
            }
            // After compaction: an edit that does not grow a note passes even
            // with the quota full.
            if meta.bytes > limits.workspace_bytes {
                return Err(SyncError::Full);
            }
            meta.save(store)?;
            Ok(positions)
        })
    }

    /// Rows after position `after`, and whether more are waiting.
    pub fn pull(&mut self, request: &Request<'_>, after: u64) -> Result<(Vec<PulledRow>, bool), SyncError> {
        self.member(request, |_| true)?;
        let listed = self.store.list(ROWS, Some(&position_key(ROWS, after)), self.limits.pull_rows + 1)?;
        let mut rows = Vec::new();
        let mut bytes = 0;
        let mut more = false;
        for (key, value) in listed {
            if rows.len() == self.limits.pull_rows || (!rows.is_empty() && bytes + value.len() > self.limits.pull_bytes)
            {
                more = true;
                break;
            }
            bytes += value.len();
            let (record, ciphertext) = value.split_at(16);
            rows.push(PulledRow {
                position: position_of(&key),
                record: record.try_into().map_err(|_| SyncError::Unavailable)?,
                ciphertext: ciphertext.to_vec(),
            });
        }
        Ok((rows, more))
    }

    /// Counts a blob a writer is about to upload against the workspace's
    /// space and today's budget. The same id again counts once. True when
    /// the id is new.
    pub fn reserve_blob(&mut self, request: &Request<'_>, id: &str, size: u64) -> Result<bool, SyncError> {
        self.member(request, Role::writes_content)?;
        check_blob_id(id)?;
        if size == 0 || size > self.limits.blob_bytes {
            return Err(SyncError::Full);
        }
        let key = format!("{BLOBS}{id}");
        if self.store.get(&key)?.is_some() {
            return Ok(false);
        }
        let limits = self.limits;
        let today = request.now_ms / DAY_MS;
        self.store.transaction(|store| {
            let mut meta = Meta::load(store)?;
            if meta.upload_day != today {
                meta.upload_day = today;
                meta.upload_bytes = 0;
            }
            if meta.blob_bytes + size > limits.workspace_blob_bytes {
                return Err(SyncError::Full);
            }
            if meta.upload_bytes + size > limits.daily_upload_bytes {
                return Err(SyncError::Throttled);
            }
            meta.blob_bytes += size;
            meta.upload_bytes += size;
            let mut entry = size.to_be_bytes().to_vec();
            entry.extend_from_slice(&request.now_ms.to_be_bytes());
            store.put(&key, &entry)?;
            meta.save(store)?;
            Ok(true)
        })
    }

    /// Whether the caller may read the workspace's blobs.
    pub fn may_read(&mut self, request: &Request<'_>) -> Result<(), SyncError> {
        self.member(request, |_| true).map(|_| ())
    }

    /// The blobs reserved after `after`, in id order, a page at a time.
    pub fn blobs(&mut self, request: &Request<'_>, after: Option<&str>) -> Result<Vec<BlobEntry>, SyncError> {
        self.member(request, |_| true)?;
        let start = after.map(|id| format!("{BLOBS}{id}"));
        let listed = self.store.list(BLOBS, start.as_deref(), 1000)?;
        Ok(listed
            .into_iter()
            .map(|(key, entry)| BlobEntry {
                id: key[BLOBS.len()..].to_owned(),
                size: entry.get(..8).map_or(0, decode_u64),
                uploaded_ms: entry.get(8..16).map_or(0, decode_u64),
            })
            .collect())
    }

    /// Forgets blobs a writer deleted, returning the space; the caller then
    /// deletes the objects. Ids never reserved are skipped.
    pub fn release_blobs(&mut self, request: &Request<'_>, ids: &[String]) -> Result<(), SyncError> {
        self.member(request, Role::writes_content)?;
        if ids.is_empty() || ids.len() > 50 {
            return Err(SyncError::Malformed("blobs per call"));
        }
        for id in ids {
            check_blob_id(id)?;
        }
        self.store.transaction(|store| {
            let mut meta = Meta::load(store)?;
            for id in ids {
                let key = format!("{BLOBS}{id}");
                if let Some(entry) = store.get(&key)? {
                    meta.blob_bytes = meta.blob_bytes.saturating_sub(entry.get(..8).map_or(0, decode_u64));
                    store.delete(&key)?;
                }
            }
            meta.save(store)?;
            Ok(())
        })
    }

    /// Checks that the caller is an owner, for a call another object will
    /// carry out (an offer under a code).
    pub fn owner(&mut self, request: &Request<'_>) -> Result<MemberKey, SyncError> {
        self.member(request, Role::manages_members).map(|(key, _)| key)
    }

    /// Deletes everything the workspace holds, at an owner's request. The
    /// caller then deletes the blob objects under the workspace's prefix.
    pub fn delete(&mut self, request: &Request<'_>) -> Result<(), SyncError> {
        self.member(request, Role::manages_members)?;
        self.store.clear()?;
        self.ledger = None;
        Ok(())
    }

    /// When the last signed request came, if the workspace exists.
    pub fn last_seen_ms(&mut self) -> Result<Option<u64>, SyncError> {
        if self.ledger()?.is_none() {
            return Ok(None);
        }
        Ok(Some(Meta::load(&self.store)?.last_seen_ms))
    }

    /// Deletes a workspace nobody has used for `idle_days`; true when it did.
    pub fn expire(&mut self, now_ms: u64) -> Result<bool, SyncError> {
        match self.last_seen_ms()? {
            Some(seen) if now_ms.saturating_sub(seen) >= self.limits.idle_days * DAY_MS => {
                self.store.clear()?;
                self.ledger = None;
                Ok(true)
            }
            _ => Ok(false),
        }
    }
}

/// Deletes the rows of `record` at or below `bound`; returns their bytes.
fn drop_superseded(store: &mut impl Store, record: &[u8; 16], bound: u64) -> Result<u64, Unavailable> {
    let prefix = format!("{INDEX}{}/", ledger_hex(record));
    let mut freed = 0;
    for (key, _) in store.list(&prefix, None, usize::MAX)? {
        let position = position_of(&key);
        if position > bound {
            break;
        }
        let row = position_key(ROWS, position);
        if let Some(value) = store.get(&row)? {
            freed += value.len() as u64;
            store.delete(&row)?;
        }
        store.delete(&key)?;
    }
    Ok(freed)
}

fn check_blob_id(id: &str) -> Result<(), SyncError> {
    let ok =
        !id.is_empty() && id.len() <= 128 && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_');
    if ok { Ok(()) } else { Err(SyncError::Malformed("blob id")) }
}

fn log_key(sequence: u32) -> String {
    format!("{LOG}{sequence:08x}")
}

fn position_key(prefix: &str, position: u64) -> String {
    format!("{prefix}{position:016x}")
}

fn index_key(record: &[u8; 16], position: u64) -> String {
    format!("{INDEX}{}/{position:016x}", ledger_hex(record))
}

fn position_of(key: &str) -> u64 {
    key.rsplit('/').next().and_then(|hex| u64::from_str_radix(hex, 16).ok()).unwrap_or(0)
}
