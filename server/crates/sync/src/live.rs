//! The live channel: WebSockets a workspace's object keeps open to tell its
//! members that something changed, so they sync at once instead of at the
//! next poll. The object holds nothing about them in memory: the key is the
//! socket's tag and the time it was accepted its attachment, and these
//! decisions take them as the object finds them.

use ledger::MemberKey;

use crate::workspace::{Heads, SyncError};

/// A key's fifth socket closes its oldest (a tab reopened, a phone that
/// reconnected before the old socket timed out).
pub const SOCKETS_PER_KEY: usize = 4;
/// Beyond this the workspace refuses new sockets (429).
pub const SOCKETS_PER_WORKSPACE: usize = 256;

/// An open socket: whose it is and when the object accepted it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Socket {
    pub key: MemberKey,
    pub accepted_ms: u64,
}

/// What the object does with its open sockets after a write: the heads go
/// to `notify`, and `close` shuts the sockets of keys no longer members.
/// Indices are into the sockets it was given, in order.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Fanout {
    pub heads: Heads,
    pub notify: Vec<usize>,
    pub close: Vec<usize>,
}

/// The sockets a new one for `key` pushes out, oldest first by acceptance
/// so the key keeps at most [`SOCKETS_PER_KEY`]; `Throttled` when even then
/// the workspace would hold more than [`SOCKETS_PER_WORKSPACE`].
pub fn admit_socket(open: &[Socket], key: &MemberKey) -> Result<Vec<usize>, SyncError> {
    let mut own: Vec<usize> = (0..open.len()).filter(|&i| open[i].key == *key).collect();
    own.sort_by_key(|&i| (open[i].accepted_ms, i));
    own.truncate((own.len() + 1).saturating_sub(SOCKETS_PER_KEY));
    if open.len() - own.len() >= SOCKETS_PER_WORKSPACE {
        return Err(SyncError::Throttled);
    }
    own.sort_unstable();
    Ok(own)
}

/// Splits the open sockets after a write by `author`: members hear of it,
/// except the author's own sockets (it knows); the others close.
pub(crate) fn fan_out(
    open: &[Socket],
    author: &MemberKey,
    is_member: impl Fn(&MemberKey) -> bool,
) -> (Vec<usize>, Vec<usize>) {
    let (mut notify, mut close) = (Vec::new(), Vec::new());
    for (i, socket) in open.iter().enumerate() {
        if !is_member(&socket.key) {
            close.push(i);
        } else if socket.key != *author {
            notify.push(i);
        }
    }
    (notify, close)
}
