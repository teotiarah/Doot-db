//! Doot control-plane state.
//!
//! Accounts, API keys and credit balances: an append-only log with the whole state
//! held in RAM (D40), and balances that are authoritative in memory and
//! checkpointed as absolute values (D41).
//!
//! Separate from the storage engine because nothing in the entry store can outlive
//! its own expiry, and separate from the request layer because it owns durability.
//! It depends on the engine only for its syscall layer, its checksum and its
//! injected clock.
//!
//! Specification: `docs/04-storage.md` (Control-plane state). Decisions:
//! `docs/07-decisions.md` D40, D41, and D21 for why keys are SHA-256 and not
//! Argon2id.

const std = @import("std");

pub const event = @import("control/event.zig");
pub const store = @import("control/store.zig");

pub const Control = store.Control;
pub const Account = store.Account;
pub const ApiKey = store.ApiKey;
pub const Auth = store.Auth;
pub const Plan = store.Plan;
pub const AccountState = store.AccountState;
pub const Spend = store.Spend;
pub const hashKey = store.hashKey;

test {
    _ = event;
    _ = store;
}
