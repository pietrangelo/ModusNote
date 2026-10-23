//! `Workspace`: who belongs, with which role, and the current GroupKey
//! epoch, rebuilt by applying the log's changes in order. The rules are
//! `Workspace.apply` of the Dart domain, one for one.

use std::collections::BTreeMap;

use super::record::Change;
use super::values::{MemberKey, Role, WorkspaceId};

/// A change the rules do not allow from its author at that point.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RuleBroken(pub &'static str);

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Workspace {
    pub id: WorkspaceId,
    pub members: BTreeMap<MemberKey, Role>,
    pub epoch: u32,
    /// Position of the last applied change in the log.
    pub sequence: u32,
}

impl Workspace {
    pub fn found(id: WorkspaceId, founder: MemberKey) -> Self {
        Self { id, members: BTreeMap::from([(founder, Role::Owner)]), epoch: 0, sequence: 0 }
    }

    pub fn role(&self, member: &MemberKey) -> Option<Role> {
        self.members.get(member).copied()
    }

    pub fn is_owner(&self, member: &MemberKey) -> bool {
        self.role(member) == Some(Role::Owner)
    }

    pub fn apply(&self, change: &Change, author: &MemberKey) -> Result<Self, RuleBroken> {
        match change {
            Change::Founded(_) => Err(RuleBroken("a workspace is founded only once")),
            Change::Invited(identity, role) => {
                self.require_owner(author)?;
                let member = identity.key();
                if self.members.contains_key(&member) {
                    return Err(RuleBroken("already a member"));
                }
                let mut members = self.members.clone();
                members.insert(member, *role);
                self.next(members, self.epoch)
            }
            Change::Revoked(target) => {
                if author != target {
                    self.require_owner(author)?;
                }
                if !self.members.contains_key(target) {
                    return Err(RuleBroken("not a member"));
                }
                let mut members = self.members.clone();
                members.remove(target);
                require_an_owner(&members)?;
                let epoch = self.epoch.checked_add(1).ok_or(RuleBroken("epoch out of range"))?;
                self.next(members, epoch)
            }
            Change::RoleChanged(target, role) => {
                self.require_owner(author)?;
                if !self.members.contains_key(target) {
                    return Err(RuleBroken("not a member"));
                }
                let mut members = self.members.clone();
                members.insert(*target, *role);
                require_an_owner(&members)?;
                self.next(members, self.epoch)
            }
        }
    }

    fn require_owner(&self, author: &MemberKey) -> Result<(), RuleBroken> {
        if self.is_owner(author) { Ok(()) } else { Err(RuleBroken("not authorized")) }
    }

    fn next(&self, members: BTreeMap<MemberKey, Role>, epoch: u32) -> Result<Self, RuleBroken> {
        let sequence = self.sequence.checked_add(1).ok_or(RuleBroken("log too long"))?;
        Ok(Self { id: self.id, members, epoch, sequence })
    }
}

fn require_an_owner(members: &BTreeMap<MemberKey, Role>) -> Result<(), RuleBroken> {
    if members.values().any(|role| *role == Role::Owner) { Ok(()) } else { Err(RuleBroken("the last owner cannot go")) }
}
