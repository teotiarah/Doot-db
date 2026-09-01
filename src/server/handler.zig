//! The seam between the transport and everything above it.
//!
//! The transport moves bytes and frames requests. It does not know what an entry is,
//! which paths exist, or who is allowed to call them. A `Handler` is the one thing it
//! calls that does, and M2's router plugs in here without the loop changing.
//!
//! A runtime vtable rather than a comptime interface, for the same reason
//! `05-architecture.md` puts TLS behind `tls.Listener`: it is a seam, so the
//! implementation on the far side must be replaceable — by the router in production
//! and by a fixture in a test — without the transport being recompiled around it.
//!
//! The handler never touches a socket, never sees a descriptor, and cannot choose when
//! its response is written. It reads an `Incoming` and fills in a `Reply`.

const std = @import("std");
const api = @import("api");
const head_mod = @import("head.zig");

const Code = api.errors.Code;

/// Headers one reply may set, beyond the ones the transport always writes itself
/// (`Date`, `Content-Length`, `Connection`).
///
/// The largest published response is a read, which sets six (`02-api.md`), plus three
/// `RateLimit-*` and a credit count. Sixteen leaves room without making the array a
/// meaningful cost inside a pooled `Request`.
pub const max_reply_headers = 16;

/// Scratch for header values the handler formats rather than borrows.
pub const reply_scratch_bytes = 1024;

/// Space for whatever a handler needs to carry from the loop to an I/O worker.
///
/// Sized for the largest of those, which is a write: a decoded name is up to 256 bytes and
/// a *normalised* tag set is 326, because normalisation lowercases and de-duplicates into
/// its own storage and so cannot borrow the request head the way a content type can. A read
/// or a delete needs only the name; a list needs a 40-byte traversal cursor and a tag.
///
/// Cheap at any of those sizes — it sits inside a pooled `Request` that is already 260 KiB.
pub const work_ctx_bytes = 768;

/// Whether a reply is ready to send, or still needs work that must not run on the event
/// loop.
///
/// Exists because no storage call may run on the loop (D57), and only the handler knows
/// which requests need one. The loop stays ignorant of *what* the work is: a deferred
/// reply simply names a function to run on an I/O worker, and the loop sends whatever
/// that function leaves in the `Reply`.
pub const Disposition = enum {
    /// The `Reply` is complete. Send it.
    complete,
    /// `Reply.work` is set and must run on an I/O worker first.
    deferred,
};

/// One request, as the handler sees it.
pub const Incoming = struct {
    head: *const head_mod.Head,
    /// The complete body. Empty when the request declared none.
    body: []const u8,

    pub fn method(i: Incoming) head_mod.Method {
        return i.head.method;
    }
    pub fn path(i: Incoming) []const u8 {
        return i.head.path();
    }
    pub fn query(i: Incoming) []const u8 {
        return i.head.query();
    }
    pub fn header(i: Incoming, name: []const u8) ?[]const u8 {
        return i.head.header(name);
    }
};

/// What the handler fills in.
///
/// Lives inside a pooled `Request`, so it is reset rather than constructed per request
/// and must not grow a field that is expensive to clear.
pub const Reply = struct {
    status: u16 = 200,
    reason: []const u8 = "OK",

    /// The response body.
    ///
    /// **Borrowed, and it must outlive the write.** Static text is always safe; so is
    /// anything in the owning `Request`'s slot or scratch. A pointer to the handler's
    /// own stack is not, because the write completes long after the handler returns
    /// (D30).
    body: []const u8 = &.{},

    /// Ask for the connection to close after this response.
    close: bool = false,

    /// Writable space for a response body too large for `scratch`, supplied by the
    /// transport. Set `body` to a sub-slice of this after filling it.
    ///
    /// It is the unused tail of the request's own 260 KiB slot, which is why it is
    /// large exactly when it needs to be: a read has no request body, so a record
    /// reply gets the whole slot — and `Store.get` requires precisely that much
    /// contiguous space (D51). A write's reply is small metadata and fits in
    /// `scratch`.
    out: []u8 = &.{},

    /// Set alongside returning `.deferred`. Runs on an I/O worker thread and fills in
    /// the rest of this same `Reply`; the loop sends whatever it leaves.
    ///
    /// It receives **the context of the handler registered with the `Loop`** — not the
    /// context of whoever assigned this field. The two are the same thing in every normal
    /// arrangement, and they differ in exactly one: a handler that *decorates* another and
    /// delegates to it. Such a handler must not defer, because the inner handler's work
    /// function would be handed the outer handler's pointer and reinterpret it. If a
    /// decorating handler is ever genuinely needed, this field has to become a
    /// `{ ctx, fn }` pair rather than a bare function (D66 amendment).
    ///
    /// Everything it is handed outlives it: the head and body live in the pooled
    /// `Request`, which is deliberately not released while a job is in flight.
    ///
    /// It runs on another thread, so it must not touch anything the loop owns — no
    /// connection state, no ring, no statistics.
    work: ?*const fn (ctx: *anyopaque, in: Incoming, out: *Reply) void = null,

    /// Scratch the handler owns across a deferral. The transport never reads it.
    ///
    /// It exists so that everything cheap happens on the loop and only the disk happens
    /// on the worker. Authenticating a key, decoding a name and validating a cursor are
    /// all memory-only, so they run before deferring — and the results have to survive
    /// the hop to the worker somehow. Re-deriving them there would mean the same request
    /// being authenticated and validated twice, by two code paths that could drift.
    work_ctx: [work_ctx_bytes]u8 align(8) = undefined,

    /// Set instead of a status to answer from the error catalogue. The transport
    /// renders the uniform JSON body and picks the status, so no handler restates
    /// either.
    error_code: ?Code = null,
    error_message: ?[]const u8 = null,
    /// Only meaningful alongside `error_code`.
    retry_after_s: ?u32 = null,
    allow: ?[]const u8 = null,

    names: [max_reply_headers][]const u8 = undefined,
    values: [max_reply_headers][]const u8 = undefined,
    count: u8 = 0,

    scratch: [reply_scratch_bytes]u8 = undefined,
    scratch_len: u16 = 0,

    /// Set when a header did not fit. The transport turns this into a `500` rather
    /// than sending a response that is quietly missing a header, because a missing
    /// `X-Doot-Credits-Remaining` is a billing question nobody can answer afterwards.
    overflow: bool = false,

    /// Typed view of `work_ctx`.
    ///
    /// Deliberately not cleared by `reset`: it is only ever read by the same handler that
    /// wrote it, in the same request, and zeroing 384 bytes per request to no purpose
    /// would be a cost paid on every request for the benefit of none.
    pub fn workCtx(r: *Reply, comptime T: type) *T {
        comptime std.debug.assert(@sizeOf(T) <= work_ctx_bytes);
        comptime std.debug.assert(@alignOf(T) <= 8);
        return @ptrCast(@alignCast(&r.work_ctx));
    }

    pub fn reset(r: *Reply) void {
        r.status = 200;
        r.reason = "OK";
        r.body = &.{};
        r.close = false;
        r.out = &.{};
        r.work = null;
        r.error_code = null;
        r.error_message = null;
        r.retry_after_s = null;
        r.allow = null;
        r.count = 0;
        r.scratch_len = 0;
        r.overflow = false;
    }

    pub fn ok(r: *Reply, status: u16, reason: []const u8) void {
        r.status = status;
        r.reason = reason;
    }

    /// Answer from the catalogue with its default message.
    pub fn fail(r: *Reply, code: Code) void {
        r.error_code = code;
        r.error_message = null;
    }

    /// Answer from the catalogue with a message naming the offending value.
    pub fn failWith(r: *Reply, code: Code, message: []const u8) void {
        r.error_code = code;
        r.error_message = message;
    }

    /// Adds a header whose value the caller guarantees outlives the write.
    pub fn header(r: *Reply, name: []const u8, value: []const u8) void {
        if (r.count == max_reply_headers) {
            r.overflow = true;
            return;
        }
        r.names[r.count] = name;
        r.values[r.count] = value;
        r.count += 1;
    }

    /// Adds a header, copying the value into the reply's own scratch.
    ///
    /// For values built from borrowed memory that the response outlives — a name from
    /// the request head is the common one.
    pub fn headerCopy(r: *Reply, name: []const u8, value: []const u8) void {
        const copied = r.dupe(value) orelse {
            r.overflow = true;
            return;
        };
        r.header(name, copied);
    }

    pub fn headerInt(r: *Reply, name: []const u8, value: u64) void {
        var buf: [20]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{d}", .{value}) catch unreachable;
        return r.headerCopy(name, text);
    }

    /// Copies bytes into the reply's scratch and returns the stable slice.
    pub fn dupe(r: *Reply, bytes: []const u8) ?[]const u8 {
        if (r.scratch_len + bytes.len > r.scratch.len) return null;
        const start = r.scratch_len;
        @memcpy(r.scratch[start..][0..bytes.len], bytes);
        r.scratch_len += @intCast(bytes.len);
        return r.scratch[start..][0..bytes.len];
    }

    pub fn fields(r: *const Reply) usize {
        return r.count;
    }
};

/// The transport's one outward call.
pub const Handler = struct {
    ctx: *anyopaque,
    respondFn: *const fn (ctx: *anyopaque, in: Incoming, out: *Reply) Disposition,

    pub fn respond(h: Handler, in: Incoming, out: *Reply) Disposition {
        return h.respondFn(h.ctx, in, out);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "a reply starts as a 200 with nothing set" {
    var r: Reply = .{};
    r.reset();
    try testing.expectEqual(@as(u16, 200), r.status);
    try testing.expectEqualStrings("OK", r.reason);
    try testing.expectEqual(@as(usize, 0), r.body.len);
    try testing.expectEqual(@as(usize, 0), r.fields());
    try testing.expect(!r.close);
    try testing.expect(!r.overflow);
    try testing.expect(r.error_code == null);
}

test "headers keep the order they were added" {
    var r: Reply = .{};
    r.reset();
    r.header("Content-Type", "application/json");
    r.headerInt("RateLimit-Remaining", 96);
    r.headerCopy("X-Doot-Name", "ci/last-green-sha");

    try testing.expectEqual(@as(usize, 3), r.fields());
    try testing.expectEqualStrings("Content-Type", r.names[0]);
    try testing.expectEqualStrings("application/json", r.values[0]);
    try testing.expectEqualStrings("RateLimit-Remaining", r.names[1]);
    try testing.expectEqualStrings("96", r.values[1]);
    try testing.expectEqualStrings("X-Doot-Name", r.names[2]);
    try testing.expectEqualStrings("ci/last-green-sha", r.values[2]);
}

test "a copied value survives the buffer it came from" {
    var r: Reply = .{};
    r.reset();

    var borrowed: [8]u8 = "original".*;
    r.headerCopy("X-Doot-Name", &borrowed);
    @memset(&borrowed, 'z');

    try testing.expectEqualStrings("original", r.values[0]);
}

test "too many headers is reported rather than silently dropped" {
    var r: Reply = .{};
    r.reset();
    for (0..max_reply_headers) |_| r.header("X-Pad", "v");
    try testing.expect(!r.overflow);
    try testing.expectEqual(@as(usize, max_reply_headers), r.fields());

    r.header("X-One-Too-Many", "v");
    try testing.expect(r.overflow);
    // The count does not grow past the array.
    try testing.expectEqual(@as(usize, max_reply_headers), r.fields());
}

test "exhausted scratch is reported rather than truncating a value" {
    var r: Reply = .{};
    r.reset();
    const big: [reply_scratch_bytes]u8 = @splat('x');
    try testing.expect(r.dupe(&big) != null);
    try testing.expect(r.dupe("one more") == null);

    r.headerCopy("X-Late", "value");
    try testing.expect(r.overflow);
}

test "a catalogue failure carries its code and optional message" {
    var r: Reply = .{};
    r.reset();
    r.fail(.not_found);
    try testing.expectEqual(Code.not_found, r.error_code.?);
    try testing.expect(r.error_message == null);

    r.reset();
    r.failWith(.ttl_too_long, "30d exceeds the 14d maximum for the trial plan.");
    try testing.expectEqual(Code.ttl_too_long, r.error_code.?);
    try testing.expectEqualStrings("30d exceeds the 14d maximum for the trial plan.", r.error_message.?);
}

test "reset clears everything a previous request set" {
    var r: Reply = .{};
    r.reset();
    r.ok(201, "Created");
    r.header("Location", "/v1/entries/x");
    r.headerInt("X-Doot-Credits-Remaining", 9187);
    r.body = "leftover";
    r.close = true;
    r.fail(.rate_limited);
    r.retry_after_s = 30;
    r.allow = "GET";
    for (0..max_reply_headers + 4) |_| r.header("X-Pad", "v");
    try testing.expect(r.overflow);

    r.reset();

    try testing.expectEqual(@as(u16, 200), r.status);
    try testing.expectEqualStrings("OK", r.reason);
    try testing.expectEqual(@as(usize, 0), r.fields());
    try testing.expectEqual(@as(u16, 0), r.scratch_len);
    try testing.expectEqual(@as(usize, 0), r.body.len);
    try testing.expect(!r.close);
    try testing.expect(!r.overflow);
    try testing.expect(r.error_code == null);
    try testing.expect(r.retry_after_s == null);
    try testing.expect(r.allow == null);
}

test "a handler is reachable through the vtable" {
    const Fixture = struct {
        calls: usize = 0,
        fn respond(ctx: *anyopaque, in: Incoming, out: *Reply) Disposition {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
            out.ok(200, "OK");
            out.header("X-Seen-Path", in.path());
            out.body = in.body;
            return .complete;
        }
        fn handler(self: *@This()) Handler {
            return .{ .ctx = self, .respondFn = respond };
        }
    };

    var fixture: Fixture = .{};
    const h = fixture.handler();

    var parsed = switch (head_mod.parse("PUT /v1/entries/a HTTP/1.1\r\nHost: d\r\nContent-Length: 2\r\n\r\nhi")) {
        .complete => |x| x,
        else => return error.TestUnexpectedResult,
    };
    var reply: Reply = .{};
    reply.reset();

    try testing.expectEqual(Disposition.complete, h.respond(.{ .head = &parsed, .body = "hi" }, &reply));

    try testing.expectEqual(@as(usize, 1), fixture.calls);
    try testing.expectEqualStrings("/v1/entries/a", reply.values[0]);
    try testing.expectEqualStrings("hi", reply.body);
}
