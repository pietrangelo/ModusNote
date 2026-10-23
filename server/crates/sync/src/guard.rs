//! Daily ceilings for the whole service, in one object: how many workspaces
//! may be founded and how many blob bytes uploaded, by everyone together.
//! Keys cost nothing, so per-key limits alone would let anyone make the
//! server keep without end; at the ceiling every caller waits until the
//! next UTC day, which is better than a bill without a bottom.

use crate::auth::decode_u64;
use crate::store::{Store, Unavailable};

const DAY_MS: u64 = 86_400_000;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Budget {
    Workspaces,
    UploadBytes,
}

impl Budget {
    fn key(self) -> &'static str {
        match self {
            Self::Workspaces => "spent/workspaces",
            Self::UploadBytes => "spent/upload-bytes",
        }
    }
}

#[derive(Debug)]
pub struct Guard<S> {
    store: S,
}

impl<S: Store> Guard<S> {
    pub fn new(store: S) -> Self {
        Self { store }
    }

    /// Spends `amount` of today's `budget` if it stays within `ceiling`;
    /// false, and nothing spent, when it would not.
    pub fn spend(&mut self, budget: Budget, amount: u64, ceiling: u64, now_ms: u64) -> Result<bool, Unavailable> {
        let today = now_ms / DAY_MS;
        let stored = self.store.get(budget.key())?;
        let spent = match stored {
            Some(bytes) if bytes.get(..8).map(decode_u64) == Some(today) => bytes.get(8..16).map_or(0, decode_u64),
            _ => 0,
        };
        let Some(total) = spent.checked_add(amount).filter(|total| *total <= ceiling) else { return Ok(false) };
        let mut value = today.to_be_bytes().to_vec();
        value.extend_from_slice(&total.to_be_bytes());
        self.store.put(budget.key(), &value)?;
        Ok(true)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::MemoryStore;

    const NOW: u64 = 20_000 * DAY_MS + 5;

    #[test]
    fn spends_up_to_the_ceiling_and_starts_again_the_next_day() {
        let mut guard = Guard::new(MemoryStore::default());
        assert_eq!(guard.spend(Budget::Workspaces, 1, 2, NOW), Ok(true));
        assert_eq!(guard.spend(Budget::Workspaces, 1, 2, NOW), Ok(true));
        assert_eq!(guard.spend(Budget::Workspaces, 1, 2, NOW), Ok(false));
        assert_eq!(guard.spend(Budget::UploadBytes, 2, 2, NOW), Ok(true), "budgets are separate");
        assert_eq!(guard.spend(Budget::Workspaces, 1, 2, NOW + DAY_MS), Ok(true));
    }

    #[test]
    fn a_refused_spend_costs_nothing_and_never_overflows() {
        let mut guard = Guard::new(MemoryStore::default());
        assert_eq!(guard.spend(Budget::UploadBytes, 10, 15, NOW), Ok(true));
        assert_eq!(guard.spend(Budget::UploadBytes, 6, 15, NOW), Ok(false));
        assert_eq!(guard.spend(Budget::UploadBytes, 5, 15, NOW), Ok(true));
        assert_eq!(guard.spend(Budget::UploadBytes, u64::MAX, u64::MAX, NOW), Ok(false));
    }
}
