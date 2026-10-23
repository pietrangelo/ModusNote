//! Port: an ordered key-value store with transactions, as the SQLite-backed
//! storage of a Durable Object offers synchronously (`ctx.storage.kv` and
//! `transactionSync`).

use std::collections::BTreeMap;

/// The storage failed; the request can be retried.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Unavailable;

pub trait Store {
    fn get(&self, key: &str) -> Result<Option<Vec<u8>>, Unavailable>;
    fn put(&mut self, key: &str, value: &[u8]) -> Result<(), Unavailable>;
    fn delete(&mut self, key: &str) -> Result<(), Unavailable>;
    /// Up to `limit` entries whose key starts with `prefix`, in key order,
    /// after `start_after` when given.
    fn list(
        &self,
        prefix: &str,
        start_after: Option<&str>,
        limit: usize,
    ) -> Result<Vec<(String, Vec<u8>)>, Unavailable>;
    /// Everything `step` writes lands together, or nothing when it fails.
    fn transaction<T, E: From<Unavailable>>(&mut self, step: impl FnOnce(&mut Self) -> Result<T, E>) -> Result<T, E>;
    /// Removes every key.
    fn clear(&mut self) -> Result<(), Unavailable>;
}

/// The store of the tests, and of nothing else.
#[derive(Clone, Debug, Default)]
pub struct MemoryStore {
    entries: BTreeMap<String, Vec<u8>>,
}

impl MemoryStore {
    pub fn len(&self) -> usize {
        self.entries.len()
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    pub fn keys(&self) -> impl Iterator<Item = &String> {
        self.entries.keys()
    }
}

impl Store for MemoryStore {
    fn get(&self, key: &str) -> Result<Option<Vec<u8>>, Unavailable> {
        Ok(self.entries.get(key).cloned())
    }

    fn put(&mut self, key: &str, value: &[u8]) -> Result<(), Unavailable> {
        self.entries.insert(key.to_owned(), value.to_vec());
        Ok(())
    }

    fn delete(&mut self, key: &str) -> Result<(), Unavailable> {
        self.entries.remove(key);
        Ok(())
    }

    fn list(
        &self,
        prefix: &str,
        start_after: Option<&str>,
        limit: usize,
    ) -> Result<Vec<(String, Vec<u8>)>, Unavailable> {
        Ok(self
            .entries
            .range(prefix.to_owned()..)
            .take_while(|(key, _)| key.starts_with(prefix))
            .filter(|(key, _)| start_after.is_none_or(|after| key.as_str() > after))
            .take(limit)
            .map(|(key, value)| (key.clone(), value.clone()))
            .collect())
    }

    fn transaction<T, E: From<Unavailable>>(&mut self, step: impl FnOnce(&mut Self) -> Result<T, E>) -> Result<T, E> {
        let before = self.entries.clone();
        let outcome = step(self);
        if outcome.is_err() {
            self.entries = before;
        }
        outcome
    }

    fn clear(&mut self) -> Result<(), Unavailable> {
        self.entries.clear();
        Ok(())
    }
}
