//! The injected clock (D33).
//!
//! Every expiry decision, segment reclamation, tombstone lifetime and snapshot
//! interval reads time from here. Nothing else in the engine may call the system
//! clock — that restriction is what makes a 24-hour soak run in seconds.

const std = @import("std");
const linux = std.os.linux;

/// Unix seconds. u32 is deliberate: it is what the record header and index slot
/// store, and it runs to 2106.
pub const Seconds = u32;

pub const Clock = struct {
    ptr: *anyopaque,
    nowFn: *const fn (ptr: *anyopaque) Seconds,

    pub fn now(c: Clock) Seconds {
        return c.nowFn(c.ptr);
    }
};

/// Wall clock. The only place in the engine that reads system time.
pub const Real = struct {
    var instance: Real = .{};

    fn nowImpl(_: *anyopaque) Seconds {
        var ts: linux.timespec = undefined;
        _ = linux.clock_gettime(.REALTIME, &ts);
        return @intCast(ts.sec);
    }

    pub fn clock(self: *Real) Clock {
        return .{ .ptr = self, .nowFn = nowImpl };
    }

    pub fn get() Clock {
        return instance.clock();
    }
};

/// A clock that only moves when told. Lets the engine's time-dependent
/// behaviour — expiry, reclamation, snapshot cadence — be driven deterministically
/// and at arbitrary speed.
pub const Manual = struct {
    t: std.atomic.Value(u64),

    pub fn init(start: Seconds) Manual {
        return .{ .t = .init(start) };
    }

    fn nowImpl(ptr: *anyopaque) Seconds {
        const self: *Manual = @ptrCast(@alignCast(ptr));
        return @intCast(self.t.load(.monotonic));
    }

    pub fn clock(self: *Manual) Clock {
        return .{ .ptr = self, .nowFn = nowImpl };
    }

    pub fn advance(self: *Manual, seconds: u32) void {
        _ = self.t.fetchAdd(seconds, .monotonic);
    }

    pub fn set(self: *Manual, to: Seconds) void {
        self.t.store(to, .monotonic);
    }
};

test "manual clock only moves when told" {
    var m: Manual = .init(1_000);
    const c = m.clock();

    try std.testing.expectEqual(@as(Seconds, 1_000), c.now());
    try std.testing.expectEqual(@as(Seconds, 1_000), c.now());

    m.advance(30 * 24 * 60 * 60);
    try std.testing.expectEqual(@as(Seconds, 1_000 + 2_592_000), c.now());

    m.set(42);
    try std.testing.expectEqual(@as(Seconds, 42), c.now());
}

test "real clock returns a plausible present" {
    const now = Real.get().now();
    // Somewhere after 2020 and before 2100. Catches a broken syscall wrapper
    // without pinning the test to a date.
    try std.testing.expect(now > 1_577_836_800);
    try std.testing.expect(now < 4_102_444_800);
}
