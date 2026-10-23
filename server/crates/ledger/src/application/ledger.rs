//! The verified membership log of one workspace, and the checks of a key
//! bundle against it: `MembershipLedger` and `WorkspaceAdministration.verify`
//! of the Dart domain.

use crate::core::bundle::KeyBundle;
use crate::core::record::{Change, Record};
use crate::core::values::{MemberKey, Signature};
use crate::core::wire::Malformed;
use crate::core::workspace::Workspace;

/// Port: Ed25519 verification at least as strict as libsodium's
/// `crypto_sign_verify_detached` (canonical S and key, no key or R of small
/// order), so the server never stores what a client would refuse.
pub trait SignatureCheck {
    fn verifies(&self, key: &MemberKey, message: &[u8], signature: &Signature) -> bool;
}

/// Why something was not let into the log or the bundle stream.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Refused {
    Malformed(&'static str),
    Tampered(&'static str),
}

impl From<Malformed> for Refused {
    fn from(malformed: Malformed) -> Self {
        Self::Malformed(malformed.0)
    }
}

/// A membership log in which every record was checked: signature, chain,
/// workspace and the author's authority at that point.
#[derive(Clone, Debug)]
pub struct VerifiedLedger {
    records: Vec<Record>,
    states: Vec<Workspace>,
}

impl VerifiedLedger {
    /// Starts a log from its first record, which names its own founder: the
    /// server keeps the first one registered for a workspace id.
    pub fn found(genesis: Record, check: &impl SignatureCheck) -> Result<Self, Refused> {
        let founder = match &genesis.change {
            Change::Founded(founder) if founder.key() == genesis.author => founder.key(),
            _ => return Err(Refused::Tampered("log not founded by its author")),
        };
        if genesis.sequence != 0 {
            return Err(Refused::Tampered("log not founded by its author"));
        }
        verify_signature(check, &genesis.author, &genesis.signable(), &genesis.signature)?;
        let state = Workspace::found(genesis.workspace, founder);
        Ok(Self { records: vec![genesis], states: vec![state] })
    }

    /// Rebuilds a log that this server verified and stored before, without
    /// checking signatures again; the rules still run.
    pub fn restore(records: Vec<Record>) -> Result<Self, Refused> {
        let mut iter = records.into_iter();
        let genesis = iter.next().ok_or(Refused::Tampered("empty membership log"))?;
        let Change::Founded(founder) = &genesis.change else {
            return Err(Refused::Tampered("log not founded by its author"));
        };
        let state = Workspace::found(genesis.workspace, founder.key());
        let mut ledger = Self { records: vec![genesis], states: vec![state] };
        for record in iter {
            ledger.append_checked(record)?;
        }
        Ok(ledger)
    }

    /// Appends the next record, or refuses it and stays as it was.
    pub fn extend(&mut self, record: Record, check: &impl SignatureCheck) -> Result<(), Refused> {
        let last = self.records.last().expect("a log is never empty");
        if record.workspace != last.workspace
            || Some(record.sequence) != last.sequence.checked_add(1)
            || record.previous != Some(last.signature)
        {
            return Err(Refused::Tampered("broken membership chain"));
        }
        verify_signature(check, &record.author, &record.signable(), &record.signature)?;
        self.append_checked(record)
    }

    fn append_checked(&mut self, record: Record) -> Result<(), Refused> {
        let state = self
            .workspace()
            .apply(&record.change, &record.author)
            .map_err(|_| Refused::Tampered("record breaks the membership rules"))?;
        self.records.push(record);
        self.states.push(state);
        Ok(())
    }

    pub fn records(&self) -> &[Record] {
        &self.records
    }

    pub fn len(&self) -> usize {
        self.records.len()
    }

    pub fn is_empty(&self) -> bool {
        false
    }

    /// The membership now.
    pub fn workspace(&self) -> &Workspace {
        self.states.last().expect("a log is never empty")
    }

    /// The membership right after record `sequence`.
    pub fn at(&self, sequence: u32) -> Option<&Workspace> {
        self.states.get(usize::try_from(sequence).ok()?)
    }

    /// Checks a bundle without opening it: its issuer was an owner at the
    /// position it names, its signature verifies, and every grant goes to a
    /// member of that state for an epoch that existed there.
    pub fn check_bundle(&self, bundle: &KeyBundle, check: &impl SignatureCheck) -> Result<(), Refused> {
        let state = self.at(bundle.at_sequence).ok_or(Refused::Tampered("unknown log position"))?;
        if bundle.workspace != state.id {
            return Err(Refused::Tampered("bundle for another space"));
        }
        if !state.is_owner(&bundle.issuer) {
            return Err(Refused::Tampered("issuer is not an owner"));
        }
        if !check.verifies(&bundle.issuer, &bundle.signable(), &bundle.signature) {
            return Err(Refused::Tampered("bad bundle signature"));
        }
        for grant in &bundle.grants {
            if grant.epoch > state.epoch || state.role(&grant.recipient).is_none() {
                return Err(Refused::Tampered("grant beyond authority"));
            }
        }
        Ok(())
    }
}

fn verify_signature(
    check: &impl SignatureCheck,
    key: &MemberKey,
    message: &[u8],
    signature: &Signature,
) -> Result<(), Refused> {
    if check.verifies(key, message, signature) { Ok(()) } else { Err(Refused::Tampered("bad record signature")) }
}
