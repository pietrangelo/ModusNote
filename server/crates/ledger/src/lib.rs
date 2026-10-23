//! # Ledger
//!
//! What the sync server checks before it stores anything a device sends:
//! the signed membership log, the key bundles and the signed requests. The
//! formats and rules are the Dart domain's (`collaboration_access_control`,
//! `offline_sync`); `server/vectors` holds cases both sides must agree on.
//!
//! The server stays blind: it opens nothing. What it gains by checking is
//! that a record or bundle no client would accept can no longer enter and
//! block everyone, and that only members of the verified log get in.
//!
//! `core` holds values, wire formats and rules; `application` the verified
//! log, over a [`SignatureCheck`] port. No I/O and no dependencies.

mod application;
mod core;

pub use application::ledger::{Refused, SignatureCheck, VerifiedLedger};
pub use core::bundle::{Grant, KeyBundle};
pub use core::record::{Change, Record};
pub use core::request::{Credential, RequestError, signable_request};
pub use core::values::{
    ENCRYPTION_KEY_LENGTH, IDENTITY_LENGTH, KEY_LENGTH, MemberKey, PublicIdentity, Role, SEALED_KEY_LENGTH,
    SIGNATURE_LENGTH, Signature, WorkspaceId,
};
pub use core::wire::Malformed;
pub use core::workspace::{RuleBroken, Workspace};
