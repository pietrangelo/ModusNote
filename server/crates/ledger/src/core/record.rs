//! `MembershipRecord`: one signed, chained change of the membership log.
//!
//! Wire: `version | workspace | sequence | author | hasPrevious [previous] |
//! kind | payload | signature`; the author signs `modusnote.membership.v1`
//! followed by everything before the signature.

use super::values::{MemberKey, PublicIdentity, Role, Signature, WorkspaceId};
use super::wire::{Malformed, Reader};

const LABEL: &[u8] = b"modusnote.membership.v1";
const VERSION: u8 = 1;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Change {
    Founded(PublicIdentity),
    Invited(PublicIdentity, Role),
    Revoked(MemberKey),
    RoleChanged(MemberKey, Role),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Record {
    pub workspace: WorkspaceId,
    pub sequence: u32,
    pub author: MemberKey,
    pub previous: Option<Signature>,
    pub change: Change,
    pub signature: Signature,
    /// The bytes as received: what is stored and handed out again.
    wire: Vec<u8>,
}

impl Record {
    pub fn parse(wire: &[u8]) -> Result<Self, Malformed> {
        let mut reader = Reader::new(wire);
        if reader.u8()? != VERSION {
            return Err(Malformed("unknown record version"));
        }
        let workspace = WorkspaceId(reader.array()?);
        let sequence = reader.u32()?;
        let author = MemberKey(reader.array()?);
        let previous = match reader.u8()? {
            0 => None,
            1 => Some(Signature(reader.array()?)),
            _ => return Err(Malformed("bad previous flag")),
        };
        if (sequence == 0) != previous.is_none() {
            return Err(Malformed("only the first record has no predecessor"));
        }
        let role = |reader: &mut Reader<'_>| Role::from_wire(reader.u8()?).ok_or(Malformed("unknown role"));
        let change = match reader.u8()? {
            0 => Change::Founded(PublicIdentity::read(&mut reader)?),
            1 => {
                let identity = PublicIdentity::read(&mut reader)?;
                Change::Invited(identity, role(&mut reader)?)
            }
            2 => Change::Revoked(MemberKey(reader.array()?)),
            3 => {
                let member = MemberKey(reader.array()?);
                Change::RoleChanged(member, role(&mut reader)?)
            }
            _ => return Err(Malformed("unknown change kind")),
        };
        let signature = Signature(reader.array()?);
        reader.finish()?;
        Ok(Self { workspace, sequence, author, previous, change, signature, wire: wire.to_vec() })
    }

    /// The exact bytes the author signed.
    pub fn signable(&self) -> Vec<u8> {
        let body = &self.wire[..self.wire.len() - self.signature.0.len()];
        [LABEL, body].concat()
    }

    pub fn wire(&self) -> &[u8] {
        &self.wire
    }
}
