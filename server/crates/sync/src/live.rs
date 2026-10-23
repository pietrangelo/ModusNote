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
/// Beyond this many sockets of any kind the runtime still lists, ours or
/// not, readable or not, the object accepts no more.
pub const SOCKETS_HELD: usize = 2 * SOCKETS_PER_WORKSPACE;

/// A socket the object still holds: whose it is, when the object accepted
/// it, and whether it is open (or closing, on its way out).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Socket {
    pub key: MemberKey,
    pub accepted_ms: u64,
    pub open: bool,
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

/// The sockets a new one for `key` pushes out: its open ones, oldest first
/// by acceptance, so the key keeps at most [`SOCKETS_PER_KEY`] open.
/// `sockets` are every one of ours the object holds, closing ones too: it
/// keeps them until the peer answers the close, which a peer may never do.
/// `Throttled` when the key would then have more than [`SOCKETS_PER_KEY`]
/// closing, when the workspace would hold more than
/// [`SOCKETS_PER_WORKSPACE`], or when the runtime already lists [`SOCKETS_HELD`]
/// sockets of any kind (`held`), so accepting one never meets its own limit.
pub fn admit_socket(sockets: &[Socket], held: usize, key: &MemberKey) -> Result<Vec<usize>, SyncError> {
    if held >= SOCKETS_HELD {
        return Err(SyncError::Throttled);
    }
    let own = |open: bool| (0..sockets.len()).filter(move |&i| sockets[i].key == *key && sockets[i].open == open);
    let closing = own(false).count();
    let mut evicted: Vec<usize> = own(true).collect();
    evicted.sort_by_key(|&i| (sockets[i].accepted_ms, i));
    evicted.truncate((evicted.len() + 1).saturating_sub(SOCKETS_PER_KEY));
    if closing + evicted.len() > SOCKETS_PER_KEY || sockets.len() - evicted.len() >= SOCKETS_PER_WORKSPACE {
        return Err(SyncError::Throttled);
    }
    evicted.sort_unstable();
    Ok(evicted)
}

/// Splits the open sockets after a write by `author`: members hear of it,
/// except the author's own sockets (it knows); the others close. Closing
/// sockets are left as they are.
pub(crate) fn fan_out(
    sockets: &[Socket],
    author: &MemberKey,
    is_member: impl Fn(&MemberKey) -> bool,
) -> (Vec<usize>, Vec<usize>) {
    let (mut notify, mut close) = (Vec::new(), Vec::new());
    for (i, socket) in sockets.iter().enumerate().filter(|(_, socket)| socket.open) {
        if !is_member(&socket.key) {
            close.push(i);
        } else if socket.key != *author {
            notify.push(i);
        }
    }
    (notify, close)
}
