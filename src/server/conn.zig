//! Connection state, and the three pools that bound the transport's memory.
//!
//! This is where D28 is implemented, so it is worth being explicit about what that
//! decision actually constrains. The measured cost of an *idle* keep-alive connection
//! is what matters — at 10,000 of them, naive allocation cost 8.11 KB each and pooling
//! brought it to 0.63 KB. Resident cost is pages **touched**, not bytes reserved, so
//! the rule that follows is: an idle connection must not own anything large.
//!
//! Hence three tiers rather than one buffer per connection:
//!
//! 1. **`Conn`**, in a slab indexed by file descriptor, carrying a small inline read
//!    buffer (`idle_read_bytes`). This is all an idle connection holds.
//! 2. **A pooled `max_head_bytes` buffer**, borrowed only by a connection whose request
//!    head did not fit in tier 1, and released when that request finishes.
//! 3. **A pooled `Request`**, holding the parsed head, the response head, and the
//!    260 KiB body slot. Borrowed for the life of one request.
//!
//! Tiers 2 and 3 are capped at `max_concurrent_requests`, which is what makes body
//! memory a function of concurrency rather than of connection count — 65 MB total,
//! whether there are ten connections or ten thousand.
//!
//! Nothing here performs I/O. The loop owns the ring and the descriptors; this file
//! owns the bytes and the arithmetic, which is why the awkward parts of both are
//! testable without a socket.

const std = @import("std");
const api = @import("api");
const config = @import("config.zig");
const head_mod = @import("head.zig");
const response = @import("response.zig");
const handler = @import("handler.zig");
const pool_mod = @import("pool.zig");
const net = @import("net.zig");

const Fd = net.Fd;

/// A fixed-capacity pool handing out indices.
///
/// Indices rather than pointers, deliberately. A pointer into a pooled array is a
/// self-referential pointer as soon as it is stored beside the thing it points at, and
/// M1 lost time to exactly that: a struct copy silently invalidated one. An index
/// survives being copied.
pub fn Pool(comptime T: type, comptime capacity: u16) type {
    return struct {
        const Self = @This();

        pub const cap = capacity;

        items: [capacity]T = undefined,
        free: [capacity]u16 = undefined,
        free_top: u16 = 0,
        /// Highest simultaneous occupancy, for `/admin/stats`.
        peak: u16 = 0,

        pub fn init(self: *Self) void {
            // Descending, so the first acquisitions come off the front of the array
            // and a lightly loaded server touches the fewest pages.
            for (0..capacity) |i| self.free[i] = @intCast(capacity - 1 - i);
            self.free_top = capacity;
            self.peak = 0;
        }

        pub fn acquire(self: *Self) ?u16 {
            if (self.free_top == 0) return null;
            self.free_top -= 1;
            const in_use = capacity - self.free_top;
            if (in_use > self.peak) self.peak = @intCast(in_use);
            return self.free[self.free_top];
        }

        pub fn release(self: *Self, index: u16) void {
            std.debug.assert(self.free_top < capacity);
            self.free[self.free_top] = index;
            self.free_top += 1;
        }

        pub fn at(self: *Self, index: u16) *T {
            return &self.items[index];
        }

        pub fn available(self: *const Self) u16 {
            return self.free_top;
        }

        pub fn inUse(self: *const Self) u16 {
            return capacity - self.free_top;
        }
    };
}

/// Everything one in-flight request needs beyond its head bytes.
pub const Request = struct {
    /// The parsed head. Its slices borrow the connection's head bytes — tier 1 or
    /// tier 2 — which stay untouched until the response has been written.
    head: head_mod.Head = .{},

    /// Request body on the way in, or a record on the way out. One buffer for both,
    /// because no request needs the two at once and the read path is what sets the
    /// size (D51).
    slot: [config.request_slot_bytes]u8 = undefined,
    /// Body bytes received so far.
    body_got: u32 = 0,

    resp_head: [config.max_response_head_bytes]u8 = undefined,
    /// The uniform catalogue body, when this request is answered with an error.
    err_body: [api.errors.max_body_bytes]u8 = undefined,

    /// What the handler filled in.
    reply: handler.Reply = .{},

    /// Head-buffer bytes this request consumed: its head, plus whatever of its body
    /// arrived alongside it. Anything past this is a pipelined follower.
    consumed: u32 = 0,

    /// The socket this request arrived on, handed to the handler as `Incoming.socket` so
    /// that `Incoming.peer()` can answer without a handler ever holding a descriptor
    /// (D74 amendment).
    ///
    /// Distinct from `job_fd` on purpose. That one exists to detect a completion arriving
    /// after its connection was closed and the descriptor reused, and is only meaningful
    /// alongside `job_gen`; reusing it here would tangle a lifetime check with a plain
    /// piece of request context. This one is set on every dispatch, so the on-loop and
    /// deferred paths hand the handler the same thing and a deferred handler asking for
    /// the peer does not silently get nothing.
    socket: Fd = -1,

    // -- deferred work (D57) --

    /// Storage for the job when this request's reply needs an I/O worker. Embedded, so
    /// deferring allocates nothing.
    job: pool_mod.Job = undefined,
    /// This request's own index in the pool, so a completion arriving on the loop can
    /// name it without searching.
    index: u16 = 0,
    /// The connection the job belongs to, and which incarnation of it. Checked on
    /// completion, because the descriptor may have been closed and reused while the job
    /// was running.
    job_fd: Fd = -1,
    job_gen: u8 = 0,
    /// The owning loop, opaque only to keep `conn` from importing `loop`.
    job_loop: ?*anyopaque = null,

    /// Set when the connection went away while a worker still held this request.
    ///
    /// The slot cannot be returned to the pool at that moment: a worker is still writing
    /// into it, and handing it to a new request would let two requests share a body
    /// buffer. So ownership transfers to the completion, which releases it and sends
    /// nothing.
    orphaned: bool = false,

    pub fn body(r: *const Request) []const u8 {
        return r.slot[0..r.body_got];
    }

    pub fn bodyComplete(r: *const Request) bool {
        return r.body_got >= r.head.bodyLen();
    }
};

pub const HeadBuf = [config.max_head_bytes]u8;

pub const RequestPool = Pool(Request, config.max_concurrent_requests);
pub const HeadPool = Pool(HeadBuf, config.max_concurrent_requests);

pub const State = enum {
    /// Not in use.
    free,
    /// Accumulating a request head.
    head,
    /// Head parsed, still reading the body.
    body,
    /// Waiting for the interim `100 Continue` to go out before reading the body.
    continue_sent,
    /// Handed to an I/O worker; nothing is posted on the socket until it comes back
    /// (D57). Deliberately not swept for idleness — the connection is not idle, it is
    /// waiting on us.
    awaiting,
    /// Writing a response.
    send,
    /// Response written; the connection closes when the send completes.
    closing,
};

/// One connection. Lives in the slab, is never copied out of it.
pub const Conn = struct {
    fd: Fd = -1,
    state: State = .free,
    /// Bumped every time this descriptor is reused.
    ///
    /// Carried in every `user_data` the loop submits, so a completion that arrives
    /// after its connection has gone — and after the kernel has handed the same
    /// descriptor to a new one — can be recognised and dropped. Without it, one
    /// connection's bytes could surface on another's.
    gen: u8 = 0,
    /// Monotonic milliseconds of the last completion on this connection, for the idle
    /// sweep. Monotonic rather than the injected wall clock: this measures a duration,
    /// and a wall clock that steps backwards must not close live connections.
    last_ms: i64 = 0,

    /// Tier 1. All an idle connection holds.
    idle_buf: [config.idle_read_bytes]u8 = undefined,
    /// Tier 2, when a head outgrew tier 1.
    escalated: ?u16 = null,
    /// Head bytes accumulated in whichever tier is active. May run past the end of the
    /// head into the body and into a following pipelined request.
    buffered: u32 = 0,

    /// Tier 3, held from head completion until the response is written.
    req: ?u16 = null,

    out: response.Outbound = .{},
    /// The `iovec`s the ring reads asynchronously, so they live as long as the send
    /// rather than as long as the function that submitted it (D30).
    iov: [2]std.posix.iovec_const = undefined,

    keep_alive: bool = true,

    /// Prepares a freshly accepted connection.
    ///
    /// The generation is carried across and advanced rather than zeroed, because its
    /// whole purpose is to differ from the previous occupant of this descriptor.
    /// Wrapping is fine: it only has to differ from completions still in flight.
    pub fn reset(c: *Conn, fd: Fd, now_ms: i64) void {
        const next_gen = c.gen +% 1;
        c.* = .{ .fd = fd, .state = .head, .last_ms = now_ms, .gen = next_gen };
    }

    /// The active head buffer: tier 2 if escalated, tier 1 otherwise.
    pub fn headBuf(c: *Conn, heads: *HeadPool) []u8 {
        if (c.escalated) |i| return heads.at(i);
        return &c.idle_buf;
    }

    /// Head bytes accumulated so far.
    pub fn head(c: *Conn, heads: *HeadPool) []const u8 {
        return c.headBuf(heads)[0..c.buffered];
    }

    /// Where the next `recv` for this head should land. Empty means the buffer is full
    /// and the head has to escalate or be refused.
    pub fn headTail(c: *Conn, heads: *HeadPool) []u8 {
        return c.headBuf(heads)[c.buffered..];
    }

    /// Moves accumulated bytes from tier 1 into a pooled tier-2 buffer.
    ///
    /// Returns false when the pool is exhausted, which the caller answers with a
    /// `503` rather than a `431`: the head may well be legal and the shortage is ours.
    pub fn escalate(c: *Conn, heads: *HeadPool) bool {
        std.debug.assert(c.escalated == null);
        const index = heads.acquire() orelse return false;
        const big = heads.at(index);
        @memcpy(big[0..c.buffered], c.idle_buf[0..c.buffered]);
        c.escalated = index;
        return true;
    }

    /// Whether tier 1 is full and a head still has not terminated.
    pub fn needsEscalation(c: *Conn, heads: *HeadPool) bool {
        return c.escalated == null and c.buffered == c.headBuf(heads).len;
    }

    /// Drops everything held for one request, leaving the connection able to serve the
    /// next one on the same descriptor.
    ///
    /// Any bytes past the end of the finished request are a pipelined follower and are
    /// moved to the front of tier 1, so releasing tier 2 cannot lose them.
    pub fn finishRequest(
        c: *Conn,
        heads: *HeadPool,
        requests: *RequestPool,
        consumed: u32,
    ) void {
        std.debug.assert(consumed <= c.buffered);
        const leftover = c.buffered - consumed;

        if (leftover > 0) {
            const src = c.headBuf(heads)[consumed..][0..leftover];
            // A follower can only exceed tier 1 if it is itself an oversized head,
            // and that case re-escalates on the next read. Truncating here would
            // desynchronise the stream, so the excess is dropped along with the
            // connection instead.
            if (leftover <= c.idle_buf.len) {
                std.mem.copyForwards(u8, c.idle_buf[0..leftover], src);
                c.buffered = leftover;
            } else {
                c.buffered = 0;
                c.keep_alive = false;
            }
        } else {
            c.buffered = 0;
        }

        if (c.escalated) |i| {
            heads.release(i);
            c.escalated = null;
        }
        if (c.req) |i| {
            requests.release(i);
            c.req = null;
        }
        c.out = .{};
    }

    /// Releases everything without preserving anything. For a connection going away.
    ///
    /// The generation survives, so a late completion for this descriptor is still
    /// recognisable as stale after the slot is reused.
    pub fn releaseAll(c: *Conn, heads: *HeadPool, requests: *RequestPool) void {
        if (c.escalated) |i| {
            heads.release(i);
            c.escalated = null;
        }
        if (c.req) |i| {
            requests.release(i);
            c.req = null;
        }
        const gen = c.gen;
        c.* = .{ .gen = gen };
    }

    /// Copies whatever of the body already arrived in the head buffer into the slot,
    /// and reports how many head-buffer bytes the request consumed in total.
    ///
    /// A single `recv` routinely carries the head, the body, and the beginning of the
    /// next pipelined request, so all three cases are the same arithmetic.
    pub fn takeBufferedBody(c: *Conn, heads: *HeadPool, requests: *RequestPool) u32 {
        const r = requests.at(c.req.?);
        const head_len: u32 = @intCast(r.head.head_len);
        const want: u32 = @intCast(r.head.bodyLen());

        const after_head = c.buffered - head_len;
        const take = @min(after_head, want);
        if (take > 0) {
            @memcpy(r.slot[0..take], c.headBuf(heads)[head_len..][0..take]);
            r.body_got = take;
        }
        r.consumed = head_len + take;
        return r.consumed;
    }

    /// Where the next `recv` for this body should land.
    pub fn bodyTail(c: *Conn, requests: *RequestPool) []u8 {
        const r = requests.at(c.req.?);
        const want: u32 = @intCast(r.head.bodyLen());
        return r.slot[r.body_got..want];
    }

    pub fn idleFor(c: *const Conn, now_ms: i64) i64 {
        return now_ms - c.last_ms;
    }
};

/// The connection slab.
///
/// Indexed directly by file descriptor, which removes the need for a free list
/// entirely: the kernel already guarantees descriptors are unique among *open*
/// connections. The cost is that the table spans the descriptor space rather than the
/// connection count, so a descriptor at or above `max_connections` is refused on
/// arrival — pair the process with an `RLIMIT_NOFILE` no higher than the same number.
pub const Table = struct {
    conns: [config.max_connections]Conn = undefined,
    live: u32 = 0,
    peak: u32 = 0,

    pub fn init(t: *Table) void {
        // Only the discriminant matters; the buffers are deliberately left untouched
        // so their pages are never faulted in until a connection actually arrives.
        for (&t.conns) |*c| {
            c.state = .free;
            c.fd = -1;
            c.gen = 0;
            c.escalated = null;
            c.req = null;
        }
        t.live = 0;
        t.peak = 0;
    }

    pub fn addressable(_: *const Table, fd: Fd) bool {
        return fd >= 0 and fd < config.max_connections;
    }

    pub fn at(t: *Table, fd: Fd) *Conn {
        return &t.conns[@intCast(fd)];
    }

    pub fn open(t: *Table, fd: Fd, now_ms: i64) *Conn {
        const c = t.at(fd);
        c.reset(fd, now_ms);
        t.live += 1;
        if (t.live > t.peak) t.peak = t.live;
        return c;
    }

    pub fn close(t: *Table, fd: Fd, heads: *HeadPool, requests: *RequestPool) void {
        const c = t.at(fd);
        if (c.state == .free) return;
        c.releaseAll(heads, requests);
        t.live -= 1;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "a pool hands out every index, refuses when empty, and takes them back" {
    var pool: Pool(u32, 4) = .{};
    pool.init();
    try testing.expectEqual(@as(u16, 4), pool.available());

    var got: [4]u16 = undefined;
    for (&got) |*g| g.* = pool.acquire().?;
    try testing.expectEqual(@as(u16, 0), pool.available());
    try testing.expectEqual(@as(u16, 4), pool.inUse());
    try testing.expectEqual(@as(u16, 4), pool.peak);
    try testing.expect(pool.acquire() == null);

    // Every index is distinct, or two requests would share a body buffer.
    var seen: [4]bool = @splat(false);
    for (got) |g| {
        try testing.expect(!seen[g]);
        seen[g] = true;
    }

    for (got) |g| pool.release(g);
    try testing.expectEqual(@as(u16, 4), pool.available());
    // Peak is a high-water mark and does not fall back.
    try testing.expectEqual(@as(u16, 4), pool.peak);
}

test "a pool's storage is independently addressable" {
    var pool: Pool(u32, 4) = .{};
    pool.init();
    const a = pool.acquire().?;
    const b = pool.acquire().?;
    pool.at(a).* = 111;
    pool.at(b).* = 222;
    try testing.expectEqual(@as(u32, 111), pool.at(a).*);
    try testing.expectEqual(@as(u32, 222), pool.at(b).*);
}

const Fixture = struct {
    table: *Table,
    heads: *HeadPool,
    requests: *RequestPool,

    fn init(gpa: std.mem.Allocator) !Fixture {
        const f: Fixture = .{
            .table = try gpa.create(Table),
            .heads = try gpa.create(HeadPool),
            .requests = try gpa.create(RequestPool),
        };
        f.table.init();
        f.heads.init();
        f.requests.init();
        return f;
    }

    fn deinit(f: Fixture, gpa: std.mem.Allocator) void {
        gpa.destroy(f.table);
        gpa.destroy(f.heads);
        gpa.destroy(f.requests);
    }

    /// Puts `bytes` into the connection's head buffer, escalating if they do not fit.
    fn feed(f: Fixture, c: *Conn, bytes: []const u8) !void {
        var offset: usize = 0;
        while (offset < bytes.len) {
            if (c.needsEscalation(f.heads)) try testing.expect(c.escalate(f.heads));
            const tail = c.headTail(f.heads);
            try testing.expect(tail.len > 0);
            const n = @min(tail.len, bytes.len - offset);
            @memcpy(tail[0..n], bytes[offset..][0..n]);
            c.buffered += @intCast(n);
            offset += n;
        }
    }
};

test "an idle connection holds only its inline buffer" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa);
    defer f.deinit(gpa);

    const c = f.table.open(7, 1000);
    try testing.expectEqual(State.head, c.state);
    try testing.expectEqual(@as(u32, 1), f.table.live);
    // The two bounded pools are what an idle connection must not be holding.
    try testing.expectEqual(@as(u16, 0), f.heads.inUse());
    try testing.expectEqual(@as(u16, 0), f.requests.inUse());
    try testing.expectEqual(@as(usize, config.idle_read_bytes), c.headBuf(f.heads).len);
}

test "a small head stays in tier 1 and never touches the pools" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa);
    defer f.deinit(gpa);

    const c = f.table.open(7, 1000);
    try f.feed(c, "GET /healthz HTTP/1.1\r\nHost: doot.run\r\n\r\n");
    try testing.expect(c.escalated == null);
    try testing.expectEqual(@as(u16, 0), f.heads.inUse());

    switch (head_mod.parse(c.head(f.heads))) {
        .complete => |h| try testing.expectEqualStrings("/healthz", h.target),
        else => return error.TestUnexpectedResult,
    }
}

test "a head larger than tier 1 escalates without losing or reordering a byte" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa);
    defer f.deinit(gpa);

    const c = f.table.open(7, 1000);

    // A head that genuinely exceeds 512 bytes: a 256-byte name plus five 64-byte tags
    // is an ordinary Doot request, not a pathological one.
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(gpa);
    try raw.appendSlice(gpa, "PUT /v1/entries/");
    try raw.appendNTimes(gpa, 'n', 240);
    try raw.appendSlice(gpa, " HTTP/1.1\r\nHost: doot.run\r\n");
    try raw.appendSlice(gpa, "Authorization: Bearer doot_live_0123456789abcdef0123456789abcdef\r\n");
    try raw.appendSlice(gpa, "X-Doot-Tags: ");
    for (0..5) |i| {
        if (i > 0) try raw.append(gpa, ',');
        try raw.appendNTimes(gpa, @as(u8, 'a') + @as(u8, @intCast(i)), 64);
    }
    try raw.appendSlice(gpa, "\r\nContent-Length: 0\r\n\r\n");
    try testing.expect(raw.items.len > config.idle_read_bytes);
    try testing.expect(raw.items.len < config.max_head_bytes);

    try f.feed(c, raw.items);

    try testing.expect(c.escalated != null);
    try testing.expectEqual(@as(u16, 1), f.heads.inUse());
    // The whole head, byte for byte, across the tier boundary.
    try testing.expectEqualStrings(raw.items, c.head(f.heads));

    switch (head_mod.parse(c.head(f.heads))) {
        .complete => |h| try testing.expectEqual(head_mod.Method.put, h.method),
        else => return error.TestUnexpectedResult,
    }
}

test "escalation reports failure rather than overrunning an exhausted pool" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa);
    defer f.deinit(gpa);

    var drained: [config.max_concurrent_requests]u16 = undefined;
    for (&drained) |*d| d.* = f.heads.acquire().?;

    const c = f.table.open(7, 1000);
    c.buffered = config.idle_read_bytes;
    try testing.expect(c.needsEscalation(f.heads));
    try testing.expect(!c.escalate(f.heads));
    try testing.expect(c.escalated == null);

    for (drained) |d| f.heads.release(d);
    try testing.expect(c.escalate(f.heads));
}

test "a body arriving with its head is copied out of the head buffer" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa);
    defer f.deinit(gpa);

    const c = f.table.open(7, 1000);
    const raw = "PUT /v1/entries/a HTTP/1.1\r\nHost: d\r\nContent-Length: 5\r\n\r\nhello";
    try f.feed(c, raw);

    c.req = f.requests.acquire().?;
    const r = f.requests.at(c.req.?);
    r.body_got = 0;
    r.head = switch (head_mod.parse(c.head(f.heads))) {
        .complete => |h| h,
        else => return error.TestUnexpectedResult,
    };

    const consumed = c.takeBufferedBody(f.heads, f.requests);
    try testing.expectEqual(@as(u32, raw.len), consumed);
    try testing.expect(r.bodyComplete());
    try testing.expectEqualStrings("hello", r.body());
    // Nothing further to read.
    try testing.expectEqual(@as(usize, 0), c.bodyTail(f.requests).len);
}

test "a body split across two reads lands contiguously in the slot" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa);
    defer f.deinit(gpa);

    const c = f.table.open(7, 1000);
    try f.feed(c, "PUT /v1/entries/a HTTP/1.1\r\nHost: d\r\nContent-Length: 11\r\n\r\nhello");

    c.req = f.requests.acquire().?;
    const r = f.requests.at(c.req.?);
    r.body_got = 0;
    r.head = switch (head_mod.parse(c.head(f.heads))) {
        .complete => |h| h,
        else => return error.TestUnexpectedResult,
    };

    _ = c.takeBufferedBody(f.heads, f.requests);
    try testing.expect(!r.bodyComplete());
    try testing.expectEqual(@as(u32, 5), r.body_got);

    // The rest arrives straight into the slot, where the loop would have aimed it.
    const tail = c.bodyTail(f.requests);
    try testing.expectEqual(@as(usize, 6), tail.len);
    @memcpy(tail, " world");
    r.body_got += 6;

    try testing.expect(r.bodyComplete());
    try testing.expectEqualStrings("hello world", r.body());
}

test "a pipelined follower survives the release of a tier-2 buffer" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa);
    defer f.deinit(gpa);

    const c = f.table.open(7, 1000);

    // Force escalation, so the follower starts life in the pooled buffer that
    // finishRequest is about to hand back.
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(gpa);
    try raw.appendSlice(gpa, "GET /v1/entries/");
    try raw.appendNTimes(gpa, 'x', 500);
    try raw.appendSlice(gpa, " HTTP/1.1\r\nHost: d\r\n\r\n");
    const first_len: u32 = @intCast(raw.items.len);
    const follower = "GET /healthz HTTP/1.1\r\nHost: d\r\n\r\n";
    try raw.appendSlice(gpa, follower);

    try f.feed(c, raw.items);
    try testing.expect(c.escalated != null);

    c.finishRequest(f.heads, f.requests, first_len);

    // Tier 2 went back to the pool and the follower moved down into tier 1 intact.
    try testing.expectEqual(@as(u16, 0), f.heads.inUse());
    try testing.expect(c.escalated == null);
    try testing.expectEqualStrings(follower, c.head(f.heads));
    try testing.expect(c.keep_alive);

    switch (head_mod.parse(c.head(f.heads))) {
        .complete => |h| try testing.expectEqualStrings("/healthz", h.target),
        else => return error.TestUnexpectedResult,
    }
}

test "finishing a request with nothing following leaves an empty buffer" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa);
    defer f.deinit(gpa);

    const c = f.table.open(7, 1000);
    const raw = "GET /healthz HTTP/1.1\r\nHost: d\r\n\r\n";
    try f.feed(c, raw);
    c.req = f.requests.acquire().?;

    c.finishRequest(f.heads, f.requests, @intCast(raw.len));
    try testing.expectEqual(@as(u32, 0), c.buffered);
    try testing.expectEqual(@as(u16, 0), f.requests.inUse());
    try testing.expect(c.req == null);
    try testing.expect(c.keep_alive);
}

test "a follower too large for tier 1 closes rather than desynchronising" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa);
    defer f.deinit(gpa);

    const c = f.table.open(7, 1000);
    const first = "GET /a HTTP/1.1\r\nHost: d\r\n\r\n";
    try f.feed(c, first);
    // A follower whose own head exceeds tier 1. Silently dropping bytes here would
    // make the next parse read the middle of a request as its start.
    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(gpa);
    try big.appendNTimes(gpa, 'z', config.idle_read_bytes + 1);
    try f.feed(c, big.items);

    c.finishRequest(f.heads, f.requests, @intCast(first.len));
    try testing.expect(!c.keep_alive);
    try testing.expectEqual(@as(u32, 0), c.buffered);
}

test "closing a connection returns everything it borrowed" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa);
    defer f.deinit(gpa);

    const c = f.table.open(7, 1000);
    c.buffered = config.idle_read_bytes;
    try testing.expect(c.escalate(f.heads));
    c.req = f.requests.acquire().?;
    try testing.expectEqual(@as(u16, 1), f.heads.inUse());
    try testing.expectEqual(@as(u16, 1), f.requests.inUse());

    f.table.close(7, f.heads, f.requests);

    try testing.expectEqual(@as(u16, 0), f.heads.inUse());
    try testing.expectEqual(@as(u16, 0), f.requests.inUse());
    try testing.expectEqual(@as(u32, 0), f.table.live);
    try testing.expectEqual(State.free, f.table.at(7).state);

    // Idempotent: a descriptor closed twice must not double-release into the pools.
    f.table.close(7, f.heads, f.requests);
    try testing.expectEqual(@as(u32, 0), f.table.live);
    try testing.expectEqual(@as(u16, 0), f.heads.inUse());
}

test "descriptors outside the table are refused rather than indexed" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa);
    defer f.deinit(gpa);

    try testing.expect(f.table.addressable(0));
    try testing.expect(f.table.addressable(config.max_connections - 1));
    try testing.expect(!f.table.addressable(config.max_connections));
    try testing.expect(!f.table.addressable(-1));
}

test "reusing a descriptor starts from clean state" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa);
    defer f.deinit(gpa);

    const first = f.table.open(9, 1000);
    try f.feed(first, "GET /a HTTP/1.1\r\nHost: d\r\n\r\n");
    first.keep_alive = false;
    f.table.close(9, f.heads, f.requests);

    // The kernel hands the same descriptor to the next connection.
    const second = f.table.open(9, 2000);
    try testing.expectEqual(@as(u32, 0), second.buffered);
    try testing.expect(second.keep_alive);
    try testing.expect(second.escalated == null);
    try testing.expect(second.req == null);
    try testing.expectEqual(@as(i64, 2000), second.last_ms);
}

test "idle age is measured from the last completion" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa);
    defer f.deinit(gpa);

    const c = f.table.open(7, 10_000);
    try testing.expectEqual(@as(i64, 0), c.idleFor(10_000));
    try testing.expectEqual(@as(i64, 75_000), c.idleFor(85_000));
    try testing.expect(c.idleFor(85_000) >= config.idle_timeout_s * 1000);
}

test "body memory is the pool, not the connection table" {
    // The structural claim behind the 65 MB figure: a Conn is small, and the large
    // buffer lives in a pool capped by concurrency.
    try testing.expect(@sizeOf(Conn) < 2 * config.idle_read_bytes);
    try testing.expect(@sizeOf(Request) > config.request_slot_bytes);
    try testing.expectEqual(
        @as(u16, config.max_concurrent_requests),
        RequestPool.cap,
    );
}
