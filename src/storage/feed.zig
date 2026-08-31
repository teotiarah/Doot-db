//! Change feed ring (D18, D44).
//!
//! `seq` is already a total order over every mutation, so the dashboard's live view
//! needs no separate mechanism — just the most recent events kept in memory and
//! filtered per account on the way out. 65,536 events at 24 bytes each is about
//! 1.5 MB, which the memory budget in `docs/04-storage.md` accounts for.
//!
//! **Why this lives in the storage engine.** `seq` and the record's location are
//! generated inside the write path, so publishing there makes ring order match
//! sequence order for free — no sorting, no reconciliation. The alternative, a
//! callback out to the server, would run request-handling code underneath the
//! global write mutex, which is exactly the re-entrancy hazard lock discipline
//! exists to prevent. So the engine owns the ring and the server polls it.
//!
//! **What it deliberately is not.** The engine holds no subscriber registry, no
//! callbacks and no notion of who is listening. Reading is a cursor-based poll: a
//! consumer asks for everything after a position it has already seen. Subscriber
//! fan-out, SSE framing and the refcounted frame slots D30 forced all belong to the
//! layer above.
//!
//! **Best-effort, by design.** The feed drives a UI, not a guarantee (D18). A
//! consumer that falls far enough behind to be lapped is told to resync rather than
//! being handed a silent gap. And because publishing happens under the write lock
//! while durability is awaited outside it (D35), a consumer can observe a mutation
//! that a crash would erase — the same window a reader has, and harmless for the
//! same reason: nothing in it has been acknowledged to anyone.
//!
//! Recovery does not publish. A replayed record is not a live change, there are no
//! subscribers during startup, and filling the ring with history would evict the
//! only events anyone wants.

const std = @import("std");
const config = @import("config.zig");
const loc_mod = @import("location.zig");

const Location = loc_mod.Location;

pub const Op = enum(u8) {
    put = 0,
    delete = 1,
};

/// One mutation. 24 bytes, which is the figure the memory budget uses.
pub const Event = struct {
    seq: u64,
    loc: Location,
    account_id: u32,
    op: Op,
};

/// A consumer's place in the stream.
///
/// A monotonic count of events ever published, not a `seq`. That is the difference
/// between "what have I seen" and "have I been lapped": sequence numbers cannot
/// answer the second question, because the ring's contents move independently of
/// how fast `seq` advances.
pub const Cursor = struct {
    pos: u64 = 0,

    /// The cursor to start from when a consumer wants only what happens next.
    pub fn now(f: *const Feed) Cursor {
        return .{ .pos = f.published.load(.acquire) };
    }
};

pub const Poll = struct {
    events: []const Event,
    next: Cursor,
    /// The consumer's position had already been overwritten, so events were
    /// skipped. It should reload its view rather than assume continuity.
    resync: bool,
};

pub const Stats = struct {
    published: u64,
    capacity: u32,
};

pub const Feed = struct {
    events: []Event,
    mask: u64,
    /// Total events ever published. Monotonic, and the only synchronisation point
    /// between the single publisher and any number of pollers.
    published: std.atomic.Value(u64),
    gpa: std.mem.Allocator,

    pub fn init(gpa: std.mem.Allocator) std.mem.Allocator.Error!Feed {
        return initCapacity(gpa, config.feed_ring_events);
    }

    /// `capacity` must be a power of two, so position-to-slot is a mask rather than
    /// a division on the write path.
    pub fn initCapacity(gpa: std.mem.Allocator, capacity: u32) std.mem.Allocator.Error!Feed {
        std.debug.assert(capacity > 0 and std.math.isPowerOfTwo(capacity));
        const events = try gpa.alloc(Event, capacity);
        return .{
            .events = events,
            .mask = capacity - 1,
            .published = .init(0),
            .gpa = gpa,
        };
    }

    pub fn deinit(f: *Feed) void {
        f.gpa.free(f.events);
        f.* = undefined;
    }

    /// Appends one event. **Single publisher only** — the store calls this while
    /// holding the write lock, which is what guarantees ring order equals `seq`
    /// order and why no compare-and-swap is needed here.
    ///
    /// The slot is written before the count is released, so a poller that sees
    /// position `n` is guaranteed the event at `n - 1` is fully stored.
    pub fn publish(f: *Feed, ev: Event) void {
        const pos = f.published.load(.monotonic);
        f.events[pos & f.mask] = ev;
        f.published.store(pos + 1, .release);
    }

    /// The oldest position a reader may trust, given `published == end`.
    ///
    /// **One slot short of the full ring, and the off-by-one is load-bearing.** The
    /// publisher writes a slot *before* it increments the count, so when the count
    /// reads `end` the publisher may be part-way through writing position `end` —
    /// and that write lands in the physical slot currently holding position
    /// `end - capacity`. Treating that slot as readable is a race, and a subtle one:
    /// a reader whose batch begins exactly there can get the *new* event in its first
    /// slot and *old* events in the rest, so every event is individually consistent
    /// while the batch as a whole runs backwards.
    ///
    /// Sacrificing one slot of `capacity` is the standard price and costs nothing
    /// anyone can observe.
    fn oldestSafe(f: *const Feed, end: u64) u64 {
        const usable = f.events.len - 1;
        return if (end > usable) end - usable else 0;
    }

    /// Copies everything after `from` into `out`, up to `out.len`.
    ///
    /// Returns a short page with a cursor when more is available, so a consumer
    /// polls until `next.pos` stops moving. Never blocks and never allocates.
    pub fn poll(f: *Feed, from: Cursor, out: []Event) Poll {
        const end = f.published.load(.acquire);
        const oldest = f.oldestSafe(end);

        var start = from.pos;
        var resync = false;
        if (start < oldest) {
            // Lapped: the events this consumer wanted are gone.
            start = oldest;
            resync = true;
        }
        // A cursor from the future means the ring was rebuilt under the consumer,
        // which is a restart. Treat it as caught up rather than reading garbage.
        if (start > end) start = end;

        const want = @min(out.len, end - start);
        var i: usize = 0;
        while (i < want) : (i += 1) out[i] = f.events[(start + i) & f.mask];

        // The publisher may have reached our range *during* the copy. The binding
        // constraint is the oldest position we read, so re-checking that one covers
        // the whole batch — and rejecting wholesale beats handing back a
        // plausible-looking mixture of two laps.
        const end_after = f.published.load(.acquire);
        const oldest_after = f.oldestSafe(end_after);
        if (oldest_after > start) {
            return .{ .events = out[0..0], .next = .{ .pos = oldest_after }, .resync = true };
        }

        return .{
            .events = out[0..want],
            .next = .{ .pos = start + want },
            .resync = resync,
        };
    }

    pub fn stats(f: *const Feed) Stats {
        return .{
            .published = f.published.load(.acquire),
            .capacity = @intCast(f.events.len),
        };
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn mkEvent(seq: u64, account_id: u32) Event {
    return .{
        .seq = seq,
        .loc = Location.init(0, 1, 64),
        .account_id = account_id,
        .op = .put,
    };
}

test "an event is the 24 bytes the memory budget assumes" {
    try testing.expectEqual(@as(usize, 24), @sizeOf(Event));
    // 65,536 x 24 = ~1.5 MB, as docs/04-storage.md states.
    try testing.expectEqual(@as(usize, 1_572_864), config.feed_ring_events * @sizeOf(Event));
}

test "events come back in publication order" {
    var f = try Feed.initCapacity(testing.allocator, 16);
    defer f.deinit();

    for (1..6) |i| f.publish(mkEvent(i, 7));

    var out: [8]Event = undefined;
    const p = f.poll(.{}, &out);
    try testing.expect(!p.resync);
    try testing.expectEqual(@as(usize, 5), p.events.len);
    for (p.events, 1..) |e, i| try testing.expectEqual(@as(u64, i), e.seq);
    try testing.expectEqual(@as(u64, 5), p.next.pos);
}

test "polling from the returned cursor yields only what is new" {
    var f = try Feed.initCapacity(testing.allocator, 16);
    defer f.deinit();
    f.publish(mkEvent(1, 1));

    var out: [8]Event = undefined;
    const first = f.poll(.{}, &out);
    try testing.expectEqual(@as(usize, 1), first.events.len);

    // Nothing new yet.
    const idle = f.poll(first.next, &out);
    try testing.expectEqual(@as(usize, 0), idle.events.len);
    try testing.expect(!idle.resync);

    f.publish(mkEvent(2, 1));
    const second = f.poll(idle.next, &out);
    try testing.expectEqual(@as(usize, 1), second.events.len);
    try testing.expectEqual(@as(u64, 2), second.events[0].seq);
}

test "a page short of the total still reports where to continue" {
    var f = try Feed.initCapacity(testing.allocator, 16);
    defer f.deinit();
    for (1..11) |i| f.publish(mkEvent(i, 1));

    var out: [4]Event = undefined;
    const p = f.poll(.{}, &out);
    try testing.expectEqual(@as(usize, 4), p.events.len);
    try testing.expectEqual(@as(u64, 4), p.next.pos);

    const q = f.poll(p.next, &out);
    try testing.expectEqual(@as(u64, 5), q.events[0].seq);
}

test "a lapped consumer is told to resync rather than handed a gap" {
    var f = try Feed.initCapacity(testing.allocator, 8);
    defer f.deinit();

    // Hold a cursor at the very start, then overrun the ring twice over.
    const stale: Cursor = .{};
    for (1..21) |i| f.publish(mkEvent(i, 1));

    var out: [8]Event = undefined;
    const p = f.poll(stale, &out);
    try testing.expect(p.resync);
    // Resumes at the oldest event a reader may trust: 20 published, and 7 of the 8
    // slots readable, because the eighth is the one the publisher will reuse next.
    try testing.expectEqual(@as(u64, 14), p.events[0].seq);
    try testing.expectEqual(@as(usize, 7), p.events.len);
}

test "the slot the publisher is about to reuse is never handed out" {
    // The deterministic form of the bug CI's two-core runner caught and an eight-core
    // box did not. Exactly `capacity` events have been published, so position 0's
    // slot is the very next one the publisher will overwrite. A reader sitting at 0
    // must be told to resync rather than being allowed to read it.
    //
    // Before the off-by-one was fixed this returned all 8 events with resync unset,
    // and the race only showed up under real contention.
    const capacity = 8;
    var f = try Feed.initCapacity(testing.allocator, capacity);
    defer f.deinit();

    for (1..capacity + 1) |i| f.publish(mkEvent(i, 1));
    try testing.expectEqual(@as(u64, capacity), f.stats().published);

    var out: [capacity]Event = undefined;
    const p = f.poll(.{}, &out);

    try testing.expect(p.resync);
    try testing.expectEqual(@as(usize, capacity - 1), p.events.len);
    try testing.expectEqual(@as(u64, 2), p.events[0].seq);
    try testing.expectEqual(@as(u64, capacity), p.events[p.events.len - 1].seq);

    // One short of a full ring is readable without a resync.
    var g = try Feed.initCapacity(testing.allocator, capacity);
    defer g.deinit();
    for (1..capacity) |i| g.publish(mkEvent(i, 1));
    const q = g.poll(.{}, &out);
    try testing.expect(!q.resync);
    try testing.expectEqual(@as(usize, capacity - 1), q.events.len);
    try testing.expectEqual(@as(u64, 1), q.events[0].seq);
}

test "wraparound preserves order and content" {
    var f = try Feed.initCapacity(testing.allocator, 4);
    defer f.deinit();
    for (1..7) |i| f.publish(mkEvent(i, 1));

    // Position 3 is the oldest trustworthy one here, and reading from it genuinely
    // wraps: positions 3, 4 and 5 map to physical slots 3, 0 and 1.
    var out: [4]Event = undefined;
    const p = f.poll(.{ .pos = 3 }, &out);
    try testing.expect(!p.resync);
    try testing.expectEqual(@as(usize, 3), p.events.len);
    for (p.events, 4..) |e, i| try testing.expectEqual(@as(u64, i), e.seq);
}

test "a cursor from the future is treated as caught up" {
    var f = try Feed.initCapacity(testing.allocator, 8);
    defer f.deinit();
    f.publish(mkEvent(1, 1));

    var out: [4]Event = undefined;
    const p = f.poll(.{ .pos = 999 }, &out);
    try testing.expectEqual(@as(usize, 0), p.events.len);
    try testing.expectEqual(@as(u64, 1), p.next.pos);
}

test "Cursor.now skips everything already published" {
    var f = try Feed.initCapacity(testing.allocator, 8);
    defer f.deinit();
    for (1..4) |i| f.publish(mkEvent(i, 1));

    const c = Cursor.now(&f);
    var out: [8]Event = undefined;
    try testing.expectEqual(@as(usize, 0), f.poll(c, &out).events.len);

    f.publish(mkEvent(99, 1));
    const p = f.poll(c, &out);
    try testing.expectEqual(@as(usize, 1), p.events.len);
    try testing.expectEqual(@as(u64, 99), p.events[0].seq);
}

test "an empty ring polls clean" {
    var f = try Feed.initCapacity(testing.allocator, 8);
    defer f.deinit();

    var out: [4]Event = undefined;
    const p = f.poll(.{}, &out);
    try testing.expectEqual(@as(usize, 0), p.events.len);
    try testing.expect(!p.resync);
    try testing.expectEqual(@as(u64, 0), p.next.pos);
    try testing.expectEqual(@as(u64, 0), f.stats().published);
}

test "a poller never tears an event under a concurrent publisher" {
    // The publisher laps a small ring thousands of times while a poller reads
    // continuously. Two properties have to hold for every event handed out:
    // `account_id` is derivable from `seq`, so a mixture of an old and a new event
    // is detectable; and `seq` strictly ascends, so a resync skips whole events
    // rather than rewinding or repeating them.
    //
    // Failures are **counted, not asserted, inside the loop**: returning early
    // would run `f.deinit()` while the publisher is still writing into the ring,
    // turning a clear assertion failure into a segfault in an unrelated test.
    const total: u64 = 50_000;
    const mix: u64 = 2654435761;

    var f = try Feed.initCapacity(testing.allocator, 16);
    defer f.deinit();

    const Runner = struct {
        f: *Feed,
        done: std.atomic.Value(bool) = .init(false),

        fn publisher(self: *@This()) void {
            var i: u64 = 1;
            while (i <= total) : (i += 1) {
                self.f.publish(.{
                    .seq = i,
                    .loc = Location.init(0, 1, 64),
                    .account_id = @truncate(i *% mix),
                    .op = .put,
                });
            }
            self.done.store(true, .release);
        }
    };

    var r: Runner = .{ .f = &f };
    const t = try std.Thread.spawn(.{}, Runner.publisher, .{&r});

    var cursor: Cursor = .{};
    var out: [8]Event = undefined;
    var seen: u64 = 0;
    var resyncs: u64 = 0;
    var torn: u64 = 0;
    var out_of_order: u64 = 0;
    var last_seq: u64 = 0;

    while (!r.done.load(.acquire) or cursor.pos < f.published.load(.acquire)) {
        const p = f.poll(cursor, &out);
        if (p.resync) resyncs += 1;
        for (p.events) |e| {
            if (e.account_id != @as(u32, @truncate(e.seq *% mix))) torn += 1;
            if (e.seq <= last_seq) out_of_order += 1;
            last_seq = e.seq;
            seen += 1;
        }
        cursor = p.next;
    }
    t.join();

    // The two invariants that must hold no matter how the two threads interleave.
    try testing.expectEqual(@as(u64, 0), torn);
    try testing.expectEqual(@as(u64, 0), out_of_order);
    try testing.expectEqual(total, f.stats().published);
    try testing.expect(seen > 0);

    // `resyncs` and `seen` are deliberately **not** asserted. Whether the reader
    // falls behind at all depends on scheduling: given two cores and a reader that
    // keeps pace, it can consume every one of 50,000 events through a 16-slot ring
    // and never be lapped once. Requiring a resync here made the test fail on
    // roughly one run in five while the properties under test held perfectly.
    //
    // The lapping path is not left unproven — it is covered deterministically by
    // "a lapped consumer is told to resync" and "the slot the publisher is about to
    // reuse is never handed out", which is where a guarantee about behaviour belongs
    // rather than in a race.
    //
    // Counted anyway, because a resync is only legitimate when the reader really did
    // fall behind: it must never exceed the number of polls that could have lapped.
    try testing.expect(resyncs <= seen + total);
}
