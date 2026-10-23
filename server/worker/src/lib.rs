//! # ModusNote sync server (Cloudflare Worker)
//!
//! One Worker serves the web client (Workers Static Assets) and, under
//! `/api/`, the sync server: every workspace in a Durable Object of its own
//! (`Workspace`), every code's rendezvous in another (`Rendezvous`), blobs in
//! R2 through the binding, all in the EU. Nothing it handles is in clear,
//! and it logs neither ids nor bodies.
//!
//! `api` is the HTTP surface and `serve` what each object does with a call,
//! both without the runtime; `runtime` (wasm only) wires them to Workers.
#![forbid(unsafe_code)]

pub mod api;
pub mod serve;

#[cfg(target_arch = "wasm32")]
mod runtime;
