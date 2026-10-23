//! What one workspace may make the server keep, so that free keys cannot
//! make it keep everything. The worker may lower them; the defaults are the
//! spec's (`CLAUDE.md`, «Server su Durable Objects»).

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Limits {
    /// Rows, log and bundles together.
    pub workspace_bytes: u64,
    pub row_bytes: usize,
    pub rows_per_push: usize,
    pub blob_bytes: u64,
    pub workspace_blob_bytes: u64,
    pub daily_upload_bytes: u64,
    pub pull_rows: usize,
    pub pull_bytes: usize,
    pub members: usize,
    /// Days without a signed request before the workspace deletes itself.
    pub idle_days: u64,
}

impl Default for Limits {
    fn default() -> Self {
        const MIB: u64 = 1 << 20;
        Self {
            workspace_bytes: 100 * MIB,
            row_bytes: 1 << 20,
            rows_per_push: 100,
            blob_bytes: 95 * MIB,
            workspace_blob_bytes: 2048 * MIB,
            daily_upload_bytes: 2048 * MIB,
            pull_rows: 200,
            pull_bytes: 4 << 20,
            members: 64,
            idle_days: 396,
        }
    }
}
