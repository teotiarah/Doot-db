//! Group commit and durable acknowledgement (docs/04-storage.md).
//!
//! A write is acknowledgeable only once its bytes are durable. Since records are
//! already `pwrite`n by the time they reach here (see the deviation note in
//! `segment.zig`), the only remaining work is the `fsync` — so this module's job
//! is to make one `fsync` serve as many waiting writers as possible.
//!
//! ## Leader commit, not a timer
//!
//! The specification describes a commit thread firing every 5 ms or every 1 MiB.
//! This implements the same guarantee differently: **the first writer that needs
//! durability becomes the leader and performs the flush; everyone else waits and
//! is covered by it.**
//!
//! That removes the interval and size triggers rather than implementing them, and
//! it is strictly better on both axes the triggers existed to balance:
//!
//! * *Latency* — a writer waits one `fsync` (50–200 µs), never up to 5 ms.
//! * *Batching* — writers arriving while the leader is in `fsync` are all
//!   satisfied by the next flush, so throughput still amortises.
//!
//! There is also nothing left for a timer to do. The triggers exist to bound how
//! long staged data sits unflushed, and nothing is staged: every acknowledged
//! write has a writer actively waiting on it, and an unacknowledged write has no
//! durability requirement to bound.
//!
//! ## Durability is per class
//!
//! Each lifetime class is a separate file, so durability is tracked per class.
//! Within a class, appends are serialised by the segment set, which makes `fsync`
//! completion order match sequence order — that is what lets a waiter reason
//! about its own sequence number without tracking a completed prefix across
//! concurrently-written classes.
//!
//! The global `seq` is still a total order over all mutations; it is what recovery
//! replays and what the change feed publishes. It is simply not what durability
//! is measured against.

const std = @import("std");
const config = @import("config.zig");
const os = @import("os.zig");
const segment = @import("segment.zig");

pub const Error = segment.Error;

pub const Committer = struct {
    segments: *segment.SegmentSet,

    /// Allocates the next global sequence number. Monotonic across all classes.
    seq_counter: std.atomic.Value(u64) = .init(0),

    /// Per class, the sequence number of the most recently completed append.
    /// Monotonic because appends within a class are serialised.
    written: [config.class_count]std.atomic.Value(u64) = @splat(.init(0)),
    /// Per class, the highest sequence number known durable.
    durable: [config.class_count]std.atomic.Value(u64) = @splat(.init(0)),

    /// Only one thread flushes at a time; the rest wait on `gen`.
    flush_lock: os.Mutex = .{},
    /// Bumped after every flush. Futex target for waiters.
    gen: std.atomic.Value(u32) = .init(0),

    flushes: std.atomic.Value(u64) = .init(0),
    /// Writers satisfied by someone else's flush. The group-commit payoff, and
    /// the number that shows batching is really happening.
    piggybacked: std.atomic.Value(u64) = .init(0),

    pub fn init(segments: *segment.SegmentSet) Committer {
        return .{ .segments = segments };
    }

    pub fn nextSeq(c: *Committer) u64 {
        return c.seq_counter.fetchAdd(1, .monotonic) + 1;
    }

    /// Highest sequence number handed out so far.
    pub fn lastSeq(c: *Committer) u64 {
        return c.seq_counter.load(.monotonic);
    }

    /// Recovery replays existing records, so the counter must resume above them.
    pub fn resumeFrom(c: *Committer, seq: u64) void {
        var cur = c.seq_counter.load(.monotonic);
        while (cur < seq) {
            cur = c.seq_counter.cmpxchgWeak(cur, seq, .monotonic, .monotonic) orelse break;
        }
    }

    /// Records that an append to `class` with sequence `seq` has completed its
    /// `pwrite`. Must be called after the write lands and before waiting.
    pub fn noteWritten(c: *Committer, class: config.Class, seq: u64) void {
        // Monotonic max: appends within a class complete in order, but be
        // defensive so a reordering cannot move the watermark backwards.
        var cur = c.written[class].load(.monotonic);
        while (cur < seq) {
            cur = c.written[class].cmpxchgWeak(cur, seq, .release, .monotonic) orelse break;
        }
    }

    pub fn isDurable(c: *Committer, class: config.Class, seq: u64) bool {
        return c.durable[class].load(.acquire) >= seq;
    }

    /// Blocks until `seq` is durable in `class`.
    ///
    /// The caller either becomes the leader and flushes, or waits for a flush
    /// already in progress to cover it.
    pub fn awaitDurable(c: *Committer, class: config.Class, seq: u64) Error!void {
        while (!c.isDurable(class, seq)) {
            // Sample the generation before attempting to lead, so a flush that
            // completes between the check and the wait cannot be missed.
            const seen_gen = c.gen.load(.acquire);

            if (c.flush_lock.tryLock()) {
                defer c.flush_lock.unlock();
                // Re-check: the previous leader may already have covered us.
                if (c.isDurable(class, seq)) {
                    _ = c.piggybacked.fetchAdd(1, .monotonic);
                    return;
                }
                try c.flushLocked();
                continue;
            }

            // Someone else is flushing. Wait for a generation change rather than
            // spinning, then re-check.
            if (c.gen.load(.acquire) == seen_gen) {
                os.futexWait(&c.gen, seen_gen);
            }
            if (c.isDurable(class, seq)) {
                _ = c.piggybacked.fetchAdd(1, .monotonic);
                return;
            }
        }
    }

    /// Flushes every class that has unflushed writes. Callers hold `flush_lock`.
    fn flushLocked(c: *Committer) Error!void {
        // Capture the watermarks *before* flushing. Anything written after this
        // point may or may not be included, so it is not claimed.
        var marks: [config.class_count]u64 = undefined;
        var dirty: [config.class_count]bool = undefined;
        for (0..config.class_count) |i| {
            marks[i] = c.written[i].load(.acquire);
            dirty[i] = marks[i] > c.durable[i].load(.acquire);
        }

        for (0..config.class_count) |i| {
            if (!dirty[i]) continue;
            try c.segments.sync(@intCast(i));
        }

        for (0..config.class_count) |i| {
            if (!dirty[i]) continue;
            var cur = c.durable[i].load(.monotonic);
            while (cur < marks[i]) {
                cur = c.durable[i].cmpxchgWeak(cur, marks[i], .release, .monotonic) orelse break;
            }
        }

        _ = c.flushes.fetchAdd(1, .monotonic);
        _ = c.gen.fetchAdd(1, .release);
        os.futexWake(&c.gen, os.wake_all);
    }

    /// Flushes unconditionally. Used by snapshotting and shutdown, where there is
    /// no particular sequence number to wait for.
    pub fn flush(c: *Committer) Error!void {
        c.flush_lock.lock();
        defer c.flush_lock.unlock();
        try c.flushLocked();
    }

    pub const Stats = struct {
        last_seq: u64,
        flushes: u64,
        piggybacked: u64,
        durable: [config.class_count]u64,

        /// Writers per flush. Above 1 means grouping is doing something.
        pub fn writersPerFlush(s: Stats) f64 {
            if (s.flushes == 0) return 0;
            return @as(f64, @floatFromInt(s.flushes + s.piggybacked)) /
                @as(f64, @floatFromInt(s.flushes));
        }
    };

    pub fn stats(c: *Committer) Stats {
        var d: [config.class_count]u64 = undefined;
        for (0..config.class_count) |i| d[i] = c.durable[i].load(.monotonic);
        return .{
            .last_seq = c.seq_counter.load(.monotonic),
            .flushes = c.flushes.load(.monotonic),
            .piggybacked = c.piggybacked.load(.monotonic),
            .durable = d,
        };
    }
};

// ---------------------------------------------------------------------------

const testing = std.testing;
const clock_mod = @import("clock.zig");
const record = @import("record.zig");

const Harness = struct {
    tmp: [64]u8 = undefined,
    path: [:0]u8 = undefined,
    dir_fd: os.Fd,
    mclock: clock_mod.Manual,

    fn init(seed: u64) !Harness {
        var h: Harness = .{ .dir_fd = -1, .mclock = .init(1000) };
        h.path = try std.fmt.bufPrintZ(&h.tmp, "/tmp/doot_commit_{d}", .{seed});
        removeTree(h.path);
        try os.mkdir(os.cwd, h.path);
        h.dir_fd = try os.openDir(os.cwd, h.path);
        return h;
    }
    fn deinit(h: *Harness) void {
        os.close(h.dir_fd);
        removeTree(h.path);
    }
    fn removeTree(path: [:0]const u8) void {
        const d = os.openDir(os.cwd, path) catch return;
        var it = os.DirIterator.init(d);
        var nb: [256]u8 = undefined;
        while (it.next() catch null) |e| {
            const n = std.fmt.bufPrintZ(&nb, "{s}", .{e.name}) catch continue;
            os.unlink(d, n) catch {};
        }
        os.close(d);
        _ = std.os.linux.unlinkat(os.cwd, path.ptr, std.os.linux.AT.REMOVEDIR);
    }
};

fn appendOne(set: *segment.SegmentSet, com: *Committer, class: config.Class, name: []const u8) !u64 {
    const seq = com.nextSeq();
    var enc: [512]u8 = undefined;
    const bytes = try record.encode(.{
        .seq = seq,
        .account_id = 1,
        .created_at = 1000,
        .expires_at = 9_000_000,
        .class = class,
        .tombstone = false,
        .name = name,
        .content_type = "",
        .tags = &.{},
        .body = "x",
    }, &enc);
    _ = try set.append(class, bytes, 9_000_000);
    com.noteWritten(class, seq);
    return seq;
}

test "sequence numbers are monotonic and unique" {
    var h = try Harness.init(1);
    defer h.deinit();
    var set = try segment.SegmentSet.open(testing.allocator, h.dir_fd, h.mclock.clock(), .{});
    defer set.deinit();
    var com = Committer.init(&set);

    var prev: u64 = 0;
    var i: u32 = 0;
    while (i < 1000) : (i += 1) {
        const s = com.nextSeq();
        try testing.expect(s > prev);
        prev = s;
    }
    try testing.expectEqual(@as(u64, 1000), com.lastSeq());
}

test "a write becomes durable only after a flush" {
    var h = try Harness.init(2);
    defer h.deinit();
    var set = try segment.SegmentSet.open(testing.allocator, h.dir_fd, h.mclock.clock(), .{});
    defer set.deinit();
    var com = Committer.init(&set);

    const seq = try appendOne(&set, &com, 1, "durable");
    try testing.expect(!com.isDurable(1, seq));

    try com.awaitDurable(1, seq);
    try testing.expect(com.isDurable(1, seq));
    try testing.expectEqual(@as(u64, 1), com.stats().flushes);
}

test "a flush costs exactly one fsync per dirty class, and none for clean ones" {
    var h = try Harness.init(3);
    defer h.deinit();
    var set = try segment.SegmentSet.open(testing.allocator, h.dir_fd, h.mclock.clock(), .{});
    defer set.deinit();
    var com = Committer.init(&set);

    // Two classes dirty, two untouched.
    _ = try appendOne(&set, &com, 0, "a");
    const s1 = try appendOne(&set, &com, 2, "b");

    const before = os.fsync_count.load(.monotonic);
    try com.awaitDurable(2, s1);
    const spent = os.fsync_count.load(.monotonic) - before;
    try testing.expectEqual(@as(u64, 2), spent);
}

test "a second wait for already-durable data costs nothing" {
    var h = try Harness.init(4);
    defer h.deinit();
    var set = try segment.SegmentSet.open(testing.allocator, h.dir_fd, h.mclock.clock(), .{});
    defer set.deinit();
    var com = Committer.init(&set);

    const seq = try appendOne(&set, &com, 1, "once");
    try com.awaitDurable(1, seq);

    const before = os.fsync_count.load(.monotonic);
    try com.awaitDurable(1, seq);
    try testing.expectEqual(before, os.fsync_count.load(.monotonic));
}

test "one flush covers many writers, which is the point of grouping" {
    var h = try Harness.init(5);
    defer h.deinit();
    var set = try segment.SegmentSet.open(testing.allocator, h.dir_fd, h.mclock.clock(), .{});
    defer set.deinit();
    var com = Committer.init(&set);

    // Append a batch, then have the last writer wait. One flush makes them all
    // durable, because fsync covers the whole file.
    var name_buf: [32]u8 = undefined;
    var last: u64 = 0;
    var i: u32 = 0;
    while (i < 500) : (i += 1) {
        const name = try std.fmt.bufPrint(&name_buf, "batch/{d}", .{i});
        last = try appendOne(&set, &com, 1, name);
    }

    const before = os.fsync_count.load(.monotonic);
    try com.awaitDurable(1, last);
    try testing.expectEqual(@as(u64, 1), os.fsync_count.load(.monotonic) - before);

    // Every earlier sequence number is durable too.
    var s: u64 = 1;
    while (s <= last) : (s += 1) try testing.expect(com.isDurable(1, s));
}

test "durability is tracked per class and does not leak between them" {
    var h = try Harness.init(6);
    defer h.deinit();
    var set = try segment.SegmentSet.open(testing.allocator, h.dir_fd, h.mclock.clock(), .{});
    defer set.deinit();
    var com = Committer.init(&set);

    const s0 = try appendOne(&set, &com, 0, "in-class-0");
    try com.awaitDurable(0, s0);

    // A later sequence number in another class is not made durable by that.
    const s3 = try appendOne(&set, &com, 3, "in-class-3");
    try testing.expect(com.isDurable(0, s0));
    try testing.expect(!com.isDurable(3, s3));

    try com.awaitDurable(3, s3);
    try testing.expect(com.isDurable(3, s3));
}

test "concurrent writers all reach durability with far fewer flushes than writers" {
    var h = try Harness.init(7);
    defer h.deinit();
    var set = try segment.SegmentSet.open(testing.allocator, h.dir_fd, h.mclock.clock(), .{});
    defer set.deinit();
    var com = Committer.init(&set);

    const Worker = struct {
        fn run(s: *segment.SegmentSet, c: *Committer, class: config.Class, n: u32, ok: *std.atomic.Value(u32)) void {
            var nb: [48]u8 = undefined;
            var i: u32 = 0;
            while (i < n) : (i += 1) {
                const name = std.fmt.bufPrint(&nb, "c{d}/i{d}", .{ class, i }) catch return;
                const seq = appendOne(s, c, class, name) catch return;
                c.awaitDurable(class, seq) catch return;
                if (!c.isDurable(class, seq)) return; // must never happen
                _ = ok.fetchAdd(1, .monotonic);
            }
        }
    };

    var ok: std.atomic.Value(u32) = .init(0);
    const per = 200;
    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*t, i| {
        t.* = try std.Thread.spawn(.{}, Worker.run, .{ &set, &com, @as(config.Class, @intCast(i)), per, &ok });
    }
    for (&threads) |t| t.join();

    try testing.expectEqual(@as(u32, threads.len * per), ok.load(.monotonic));

    const st = com.stats();
    // Every write is durable, but nowhere near one flush each.
    try testing.expect(st.flushes < threads.len * per);
    try testing.expectEqual(@as(u64, threads.len * per), st.last_seq);
}

test "resumeFrom lifts the counter above replayed records but never lowers it" {
    var h = try Harness.init(8);
    defer h.deinit();
    var set = try segment.SegmentSet.open(testing.allocator, h.dir_fd, h.mclock.clock(), .{});
    defer set.deinit();
    var com = Committer.init(&set);

    com.resumeFrom(5000);
    try testing.expectEqual(@as(u64, 5000), com.lastSeq());
    try testing.expectEqual(@as(u64, 5001), com.nextSeq());

    com.resumeFrom(10); // must not move backwards
    try testing.expectEqual(@as(u64, 5001), com.lastSeq());
}
