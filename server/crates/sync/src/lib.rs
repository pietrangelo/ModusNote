//! # Sync
//!
//! The use cases of the sync server, on a key-value [`Store`] port that a
//! Durable Object (or a map, in tests) provides:
//!
//! - [`Workspace`]: one workspace's verified membership log, key bundles,
//!   sealed rows with compaction, blob reservations and quotas, and who may
//!   call: a request counts only if a member of the verified log signed it.
//!   Its members' open WebSockets hear of every write ([`Fanout`]).
//! - [`Rendezvous`]: where an owner's offer under a code's lookup meets the
//!   answers of the devices that know the code, for fifteen minutes.
//! - [`Guard`]: daily ceilings for the whole service, so that free keys
//!   cannot found workspaces or upload bytes without end.
//!
//! Nothing here opens a ciphertext. The HTTP shell is `server/worker`.

mod auth;
mod guard;
mod limits;
mod live;
mod pow;
mod rendezvous;
mod store;
mod workspace;

pub use auth::{Caller, Denied, Request, SKEW_MS};
pub use guard::{Budget, Guard};
pub use limits::Limits;
pub use live::{Fanout, SOCKETS_PER_KEY, SOCKETS_PER_WORKSPACE, Socket, admit_socket};
pub use pow::{PowPurpose, pow_satisfied};
pub use rendezvous::{Rendezvous, RendezvousError};
pub use store::{MemoryStore, Store, Unavailable};
pub use workspace::{BlobEntry, Heads, PulledRow, PushedRow, SyncError, Workspace};

/// Port: BLAKE2b-256, as libsodium's `crypto_generichash`.
pub trait Hasher {
    fn blake2b_256(&self, bytes: &[u8]) -> [u8; 32];
}
