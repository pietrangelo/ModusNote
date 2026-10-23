//! `KeyBundle`: GroupKey grants issued together by an owner and signed.
//!
//! Wire: `version | workspace | atSequence | issuer | count | grants |
//! signature`, each grant `epoch | recipient | sealedKey`; the issuer signs
//! `modusnote.keybundle.v1` followed by everything before the signature.

use super::values::{
    KEY_LENGTH, MemberKey, SEALED_KEY_LENGTH, SIGNATURE_LENGTH, Signature, WorkspaceId, check_sealed_key,
};
use super::wire::{Malformed, Reader};

const LABEL: &[u8] = b"modusnote.keybundle.v1";
const VERSION: u8 = 1;
pub const MAX_GRANTS: usize = 4096;
const GRANT_LENGTH: usize = 4 + KEY_LENGTH + SEALED_KEY_LENGTH;

/// One GroupKey of one epoch for one member; the sealed key stays opaque.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Grant {
    pub epoch: u32,
    pub recipient: MemberKey,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct KeyBundle {
    pub workspace: WorkspaceId,
    pub at_sequence: u32,
    pub issuer: MemberKey,
    pub grants: Vec<Grant>,
    pub signature: Signature,
    wire: Vec<u8>,
}

impl KeyBundle {
    pub fn parse(wire: &[u8]) -> Result<Self, Malformed> {
        let mut reader = Reader::new(wire);
        if reader.u8()? != VERSION {
            return Err(Malformed("unknown bundle version"));
        }
        let workspace = WorkspaceId(reader.array()?);
        let at_sequence = reader.u32()?;
        let issuer = MemberKey(reader.array()?);
        let count = usize::from(reader.u16()?);
        if count > MAX_GRANTS || count * GRANT_LENGTH + SIGNATURE_LENGTH != reader.remaining() {
            return Err(Malformed("grant count mismatch"));
        }
        let mut grants = Vec::with_capacity(count);
        for _ in 0..count {
            let epoch = reader.u32()?;
            let recipient = MemberKey(reader.array()?);
            check_sealed_key(reader.take(SEALED_KEY_LENGTH)?)?;
            grants.push(Grant { epoch, recipient });
        }
        let signature = Signature(reader.array()?);
        reader.finish()?;
        Ok(Self { workspace, at_sequence, issuer, grants, signature, wire: wire.to_vec() })
    }

    /// The exact bytes the issuer signed.
    pub fn signable(&self) -> Vec<u8> {
        let body = &self.wire[..self.wire.len() - SIGNATURE_LENGTH];
        [LABEL, body].concat()
    }

    pub fn wire(&self) -> &[u8] {
        &self.wire
    }
}
