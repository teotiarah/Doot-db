//! Packed record address (docs/04-storage.md).
//!
//! | bits  | width | field                              |
//! |-------|-------|------------------------------------|
//! | 0-25  | 26    | offset within segment (64 MiB)      |
//! | 26-49 | 24    | segment id, monotonic, never reused |
//! | 50-51 | 2     | lifetime class                      |
//! | 52-63 | 12    | reserved                            |
//!
//! Segment ids are never recycled, which keeps a location globally unambiguous
//! and makes a stale reference detectable rather than silently pointing at
//! someone else's data.

const std = @import("std");
const config = @import("config.zig");

pub const offset_bits = 26;
pub const segment_bits = 24;
pub const class_bits = 2;

const offset_mask: u64 = (1 << offset_bits) - 1;
const segment_mask: u64 = (1 << segment_bits) - 1;
const class_mask: u64 = (1 << class_bits) - 1;

/// Reserved for "no location". Not a valid address because offset 0 of segment 0
/// holds a segment header, never a record.
pub const none: Location = .{ .raw = 0 };

pub const Location = struct {
    raw: u64,

    pub fn init(cls: config.Class, segment_id: u32, off: u32) Location {
        std.debug.assert(off <= offset_mask);
        std.debug.assert(segment_id <= segment_mask);
        return .{ .raw = @as(u64, off) |
            (@as(u64, segment_id) << offset_bits) |
            (@as(u64, cls) << (offset_bits + segment_bits)) };
    }

    pub fn offset(l: Location) u32 {
        return @intCast(l.raw & offset_mask);
    }

    pub fn segmentId(l: Location) u32 {
        return @intCast((l.raw >> offset_bits) & segment_mask);
    }

    pub fn class(l: Location) config.Class {
        return @intCast((l.raw >> (offset_bits + segment_bits)) & class_mask);
    }

    pub fn isNone(l: Location) bool {
        return l.raw == 0;
    }

    pub fn eql(a: Location, b: Location) bool {
        return a.raw == b.raw;
    }
};

test "round-trips every field at its extreme" {
    const cases = [_]struct { class: config.Class, seg: u32, off: u32 }{
        .{ .class = 0, .seg = 0, .off = 1 },
        .{ .class = 3, .seg = config.max_segment_id, .off = (1 << offset_bits) - 1 },
        .{ .class = 1, .seg = 12_345, .off = 67_890 },
        .{ .class = 2, .seg = 1, .off = 0 },
    };
    for (cases) |c| {
        const l = Location.init(c.class, c.seg, c.off);
        try std.testing.expectEqual(c.class, l.class());
        try std.testing.expectEqual(c.seg, l.segmentId());
        try std.testing.expectEqual(c.off, l.offset());
        try std.testing.expect(!l.isNone());
    }
}

test "the reserved bits stay clear so they remain usable" {
    const l = Location.init(3, config.max_segment_id, (1 << offset_bits) - 1);
    try std.testing.expectEqual(@as(u64, 0), l.raw >> 52);
}

test "none is distinguishable from every real address" {
    try std.testing.expect(none.isNone());
    // Offset 0 of segment 0 is a segment header, so this encoding is never a
    // record address and is safe to reserve.
    try std.testing.expect(!Location.init(0, 0, 1).isNone());
}

test "a 26-bit offset is exactly the documented segment ceiling" {
    try std.testing.expectEqual(config.max_segment_bytes, @as(u32, 1) << offset_bits);
}
