//! Doot storage engine.
//!
//! Standalone by design at M1: no HTTP, no networking, no dependency on
//! `std.Io`. The engine owns files, memory and time-driven behaviour, and
//! nothing else.
//!
//! Specification: `docs/04-storage.md`. Decisions: `docs/07-decisions.md`,
//! particularly D10 (lifetime classes), D11 (hash-only index), D12 (on-disk tag
//! chains), D17 (snapshot plus tail replay), D32 and D33 (record format,
//! slot lifecycle, and the injected clock and crash point).

const std = @import("std");

pub const config = @import("storage/config.zig");
pub const clock = @import("storage/clock.zig");
pub const os = @import("storage/os.zig");
pub const location = @import("storage/location.zig");
pub const crc32c = @import("storage/crc32c.zig");
pub const record = @import("storage/record.zig");
pub const index = @import("storage/index.zig");
pub const segment = @import("storage/segment.zig");
pub const commit = @import("storage/commit.zig");
pub const tagchain = @import("storage/tagchain.zig");
pub const snapshot = @import("storage/snapshot.zig");
pub const identity = @import("storage/identity.zig");
pub const feed = @import("storage/feed.zig");
pub const store = @import("storage/store.zig");

pub const Location = location.Location;
pub const Record = record.Record;
pub const Index = index.Index;
pub const SegmentSet = segment.SegmentSet;
pub const Committer = commit.Committer;
pub const TagHeads = tagchain.TagHeads;
pub const Store = store.Store;
pub const Clock = clock.Clock;
pub const Options = config.Options;

test {
    // Pull in every submodule's tests. `refAllDeclsRecursive` was removed in
    // Zig 0.16, so reference the modules explicitly.
    _ = config;
    _ = clock;
    _ = os;
    _ = location;
    _ = crc32c;
    _ = record;
    _ = index;
    _ = segment;
    _ = commit;
    _ = tagchain;
    _ = snapshot;
    _ = identity;
    _ = feed;
    _ = store;
}
