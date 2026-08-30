//! Canonical storage-engine constants.
//!
//! Mirrors the tables in `docs/04-storage.md` and `docs/01-product.md`. Values are
//! defined here once and referenced everywhere; nothing else may hardcode a limit.

const std = @import("std");

// ---------------------------------------------------------------------------
// Entry limits (user-visible; docs/01-product.md)
// ---------------------------------------------------------------------------

/// Maximum body size. Above this, callers treat Doot as blob storage.
pub const max_body_bytes: u32 = 256 * 1024;

/// Names are 1..256 bytes. Stored on disk biased by one so the length fits a
/// single byte (D32) — a name is never empty, so 0..255 encodes 1..256.
pub const max_name_bytes: u16 = 256;
pub const min_name_bytes: u16 = 1;

pub const max_tags: u8 = 5;
pub const max_tag_bytes: u8 = 64;
pub const max_content_type_bytes: u8 = 128;

/// Applied when the caller supplies no lifetime.
pub const default_ttl_s: u32 = 7 * 24 * 60 * 60;
pub const min_ttl_s: u32 = 60;

// ---------------------------------------------------------------------------
// Lifetime classes (docs/04-storage.md)
// ---------------------------------------------------------------------------

/// Class boundaries. Class 3's bound is the configured maximum lifetime, so
/// nothing here hardcodes a retention policy.
pub const class_count: u8 = 4;
pub const Class = u2;

pub const class_bounds_s = [_]u32{
    60 * 60, // c0: <= 1 hour. Also carries tombstones.
    24 * 60 * 60, // c1: <= 24 hours
    7 * 24 * 60 * 60, // c2: <= 7 days
    // c3's bound is Options.max_ttl_s, resolved at runtime.
};

/// Lowest class whose bound covers `ttl_s`. Anything above class 2's bound lands
/// in class 3, whose ceiling is enforced separately by validation.
pub fn classFor(ttl_s: u32) Class {
    for (class_bounds_s, 0..) |bound, i| {
        if (ttl_s <= bound) return @intCast(i);
    }
    return 3;
}

/// Tombstones live in class 0 and only need to outlast one snapshot (D32), so
/// they get twice the snapshot interval.
pub const tombstone_ttl_s: u32 = 2 * snapshot_interval_s;

// ---------------------------------------------------------------------------
// Segments
// ---------------------------------------------------------------------------

pub const default_segment_bytes: u32 = 64 * 1024 * 1024;

/// Segment ids are 24 bits in a packed location and are never reused.
pub const max_segment_id: u32 = (1 << 24) - 1;

/// Offsets are 26 bits, so a segment can never exceed 64 MiB.
pub const max_segment_bytes: u32 = 1 << 26;

// ---------------------------------------------------------------------------
// Index
// ---------------------------------------------------------------------------

pub const index_shards: u32 = 64;
pub const index_slot_bytes: u32 = 20;

/// Occupancy (live + dead slots) at which a shard grows. 0.70 gives the
/// ~29 B/entry the memory budget is built on: 20 / 0.70.
pub const index_max_load_num: u64 = 7;
pub const index_max_load_den: u64 = 10;

/// Dead-slot fraction at which a shard is rebuilt to reclaim memory (D32).
/// Distinct from segment compaction: index-only, no disk, steady-state.
pub const index_rebuild_dead_num: u64 = 1;
pub const index_rebuild_dead_den: u64 = 4;

/// Slots per shard on a fresh store. Grows by doubling.
pub const index_initial_slots_per_shard: u32 = 1024;

// ---------------------------------------------------------------------------
// Durability
// ---------------------------------------------------------------------------

pub const commit_interval_ms: u32 = 5;
pub const commit_size_trigger_bytes: u32 = 1024 * 1024;
pub const snapshot_interval_s: u32 = 5 * 60;

/// Tracked regression metric, asserted by the M1 harness.
pub const recovery_target_ms: u32 = 10_000;

// ---------------------------------------------------------------------------
// Tag traversal
// ---------------------------------------------------------------------------

/// Hops per list page. Bounds a free operation so it cannot become an
/// unbounded disk scan; a page may return short and still yield a cursor.
pub const tag_hop_budget: u32 = 500;

pub const list_default_limit: u32 = 50;
pub const list_max_limit: u32 = 100;

// ---------------------------------------------------------------------------
// Change feed
// ---------------------------------------------------------------------------

pub const feed_ring_events: u32 = 65_536;

// ---------------------------------------------------------------------------
// Runtime options
// ---------------------------------------------------------------------------

/// Everything a store instance needs that is not a compile-time constant.
pub const Options = struct {
    /// Ceiling on maximum requested lifetime. Class 3's bound. Deliberately a
    /// value, not a constant: retention is expected to move (D9 amendment).
    max_ttl_s: u32 = 30 * 24 * 60 * 60,

    segment_bytes: u32 = default_segment_bytes,
    commit_interval_ms: u32 = commit_interval_ms,
    snapshot_interval_s: u32 = snapshot_interval_s,

    /// Hard ceiling on index memory. Zero means unlimited, which is only
    /// appropriate in tests.
    max_index_bytes: u64 = 0,

    /// Keys the index hash so hash-flooding is not a remote DoS vector.
    /// Randomised per instance in production; fixed in tests for determinism.
    index_hash_key: [16]u8 = @splat(0),

    pub fn classBound(o: Options, class: Class) u32 {
        return if (class == 3) o.max_ttl_s else class_bounds_s[class];
    }

    pub fn validate(o: Options) !void {
        if (o.segment_bytes > max_segment_bytes) return error.SegmentTooLarge;
        if (o.segment_bytes < 64 * 1024) return error.SegmentTooSmall;
        if (o.max_ttl_s < min_ttl_s) return error.MaxTtlTooSmall;
    }
};

test "class assignment follows the documented bounds" {
    try std.testing.expectEqual(@as(Class, 0), classFor(1));
    try std.testing.expectEqual(@as(Class, 0), classFor(60 * 60));
    try std.testing.expectEqual(@as(Class, 1), classFor(60 * 60 + 1));
    try std.testing.expectEqual(@as(Class, 1), classFor(24 * 60 * 60));
    try std.testing.expectEqual(@as(Class, 2), classFor(24 * 60 * 60 + 1));
    try std.testing.expectEqual(@as(Class, 2), classFor(7 * 24 * 60 * 60));
    try std.testing.expectEqual(@as(Class, 3), classFor(7 * 24 * 60 * 60 + 1));
    try std.testing.expectEqual(@as(Class, 3), classFor(90 * 24 * 60 * 60));
}

test "a segment can never exceed what a 26-bit offset addresses" {
    try std.testing.expect(default_segment_bytes <= max_segment_bytes);
}

test "load factor yields the ~29 bytes per entry the memory budget assumes" {
    const per_entry = index_slot_bytes * index_max_load_den / index_max_load_num;
    try std.testing.expectEqual(@as(u32, 28), per_entry); // 20 / 0.7 = 28.57
}
