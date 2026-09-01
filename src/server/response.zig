//! Response head assembly, and the bookkeeping a single `writev` needs.
//!
//! Pure over caller-supplied buffers: no allocation, no clock, no sockets. The loop
//! owns the memory and the descriptor; this file only decides what bytes go in it.
//!
//! Two things here are load-bearing.
//!
//! **Headers and body leave in one `writev`** (`05-architecture.md`) — one syscall per
//! response. So the head is built into its own buffer and the body is never copied
//! beside it; they travel as two `iovec`s instead.
//!
//! **A partial write is normal, not an error.** `writev` may report fewer bytes than
//! it was given, and the remainder has to be re-submitted from exactly where it
//! stopped. `Outbound` is that cursor. Getting this wrong truncates large responses
//! under load and nowhere else, which is the worst possible place for a bug to live.
//!
//! Both buffers handed to the ring must stay unmodified until the completion arrives
//! (D30). `Outbound` borrows rather than copies, so the caller keeps that obligation.

const std = @import("std");
const api = @import("api");
const config = @import("config.zig");
const head_mod = @import("head.zig");

const Code = api.errors.Code;
const Version = head_mod.Version;

pub const Error = error{
    NoSpaceLeft,
    /// A header name or value contained a byte that would end the header block early.
    InvalidHeader,
};

/// Builds a status line and header block into a caller-supplied buffer.
pub const Writer = struct {
    buf: []u8,
    len: usize = 0,

    pub fn init(buf: []u8) Writer {
        return .{ .buf = buf };
    }

    /// `HTTP/1.1 200 OK`. Always 1.1 on the wire: the origin implements one version,
    /// and answering a 1.0 request with `HTTP/1.1` is both legal and what every
    /// server does.
    pub fn status(w: *Writer, code: u16, reason: []const u8) Error!void {
        try w.put("HTTP/1.1 ");
        try w.putInt(code);
        try w.put(" ");
        try w.put(reason);
        try w.crlf();
    }

    pub fn statusOf(w: *Writer, code: Code) Error!void {
        return w.status(code.status(), code.reason());
    }

    pub fn header(w: *Writer, name: []const u8, value: []const u8) Error!void {
        // Response splitting: a CR, LF or NUL in either half would terminate the
        // header block early and let the rest be read as a second response. Several
        // values here originate with the caller — `Content-Type` is stored verbatim
        // and echoed back — so this is checked rather than assumed.
        if (!headerSafe(name) or !headerSafe(value)) return error.InvalidHeader;
        try w.put(name);
        try w.put(": ");
        try w.put(value);
        try w.crlf();
    }

    pub fn headerInt(w: *Writer, name: []const u8, value: u64) Error!void {
        if (!headerSafe(name)) return error.InvalidHeader;
        try w.put(name);
        try w.put(": ");
        try w.putInt(value);
        try w.crlf();
    }

    /// Closes the header block with the empty line and returns the head.
    pub fn finish(w: *Writer) Error![]u8 {
        try w.crlf();
        return w.buf[0..w.len];
    }

    fn put(w: *Writer, s: []const u8) Error!void {
        if (w.len + s.len > w.buf.len) return error.NoSpaceLeft;
        @memcpy(w.buf[w.len..][0..s.len], s);
        w.len += s.len;
    }

    fn putInt(w: *Writer, value: u64) Error!void {
        var scratch: [20]u8 = undefined;
        const text = std.fmt.bufPrint(&scratch, "{d}", .{value}) catch unreachable;
        return w.put(text);
    }

    fn crlf(w: *Writer) Error!void {
        return w.put("\r\n");
    }
};

fn headerSafe(s: []const u8) bool {
    for (s) |c| if (c == '\r' or c == '\n' or c == 0) return false;
    return true;
}

/// A response waiting to go out, and how much of it already has.
///
/// `head` and `body` are borrowed. Both must outlive the send and neither may be
/// touched until its completion arrives (D30).
pub const Outbound = struct {
    head: []const u8 = &.{},
    body: []const u8 = &.{},
    sent: usize = 0,

    pub fn total(o: *const Outbound) usize {
        return o.head.len + o.body.len;
    }

    pub fn remaining(o: *const Outbound) usize {
        return o.total() - o.sent;
    }

    pub fn done(o: *const Outbound) bool {
        return o.sent >= o.total();
    }

    pub fn advance(o: *Outbound, n: usize) void {
        o.sent = @min(o.sent + n, o.total());
    }

    /// The `iovec`s still to be written, into caller-supplied storage.
    ///
    /// The array must outlive the submission: io_uring reads the `iovec`s themselves
    /// asynchronously, not just the buffers they point at, so a stack array in the
    /// calling function would be a use-after-return.
    ///
    /// Empty segments are skipped, so an empty return means `done()`.
    pub fn iovecs(o: *const Outbound, out: *[2]std.posix.iovec_const) []const std.posix.iovec_const {
        var n: usize = 0;
        if (o.sent < o.head.len) {
            out[n] = .{ .base = o.head.ptr + o.sent, .len = o.head.len - o.sent };
            n += 1;
            if (o.body.len > 0) {
                out[n] = .{ .base = o.body.ptr, .len = o.body.len };
                n += 1;
            }
        } else {
            const offset = o.sent - o.head.len;
            if (offset < o.body.len) {
                out[n] = .{ .base = o.body.ptr + offset, .len = o.body.len - offset };
                n += 1;
            }
        }
        return out[0..n];
    }
};

// ---------------------------------------------------------------------------
// The error response
// ---------------------------------------------------------------------------

/// One response header, for the cases that pass a list rather than writing them in order.
pub const Field = struct {
    name: []const u8,
    value: []const u8,
};

pub const ErrorOptions = struct {
    code: Code,
    /// `null` uses the catalogue's default. Handlers that can name the offending
    /// value should pass their own (`api.errors`).
    message: ?[]const u8 = null,
    /// Pre-formatted IMF-fixdate. Cached by the loop and refreshed once a second, so
    /// a response never formats a timestamp.
    date: []const u8,
    keep_alive: bool,
    /// `429` carries this, in seconds (`02-api.md`).
    retry_after_s: ?u32 = null,
    /// `405` carries this (`02-api.md`).
    allow: ?[]const u8 = null,
    /// Headers the handler set before failing.
    ///
    /// Error responses carry these too, which is not a detail: `02-api.md` puts the three
    /// `RateLimit-*` headers on **every** `/v1` response, and the response a caller most
    /// needs them on is the `429`. Dropping them on the error path would leave a throttled
    /// client unable to see its own budget.
    extra: []const Field = &.{},
};

/// Writes a complete error response — the uniform JSON body from `api.errors` plus its
/// head — into two caller-supplied buffers.
pub fn writeError(o: ErrorOptions, head_buf: []u8, body_buf: []u8) Error!Outbound {
    const body = api.errors.writeBody(
        o.code,
        o.message orelse o.code.defaultMessage(),
        body_buf,
    ) catch return error.NoSpaceLeft;

    var w = Writer.init(head_buf);
    try w.statusOf(o.code);
    try w.header("Date", o.date);
    for (o.extra) |f| try w.header(f.name, f.value);
    try w.header("Content-Type", "application/json");
    try w.headerInt("Content-Length", body.len);
    if (o.retry_after_s) |secs| try w.headerInt("Retry-After", secs);
    if (o.allow) |methods| try w.header("Allow", methods);
    try w.header("Connection", if (o.keep_alive) "keep-alive" else "close");

    return .{ .head = try w.finish(), .body = body };
}

// ---------------------------------------------------------------------------
// Dates
// ---------------------------------------------------------------------------

/// Length of an IMF-fixdate: `Sun, 06 Nov 1994 08:49:37 GMT`.
pub const http_date_len = 29;

const day_names = [7][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
const month_names = [12][]const u8{
    "Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
};

/// Formats unix seconds as an IMF-fixdate.
///
/// RFC 9110 requires an origin server with a clock to send `Date`, and neither
/// `05-architecture.md`'s header list nor `02-api.md`'s per-endpoint tables enumerate
/// it — they describe the product's headers, and this one belongs to the protocol.
/// Emitted for correctness rather than for the product: caches and clients use it, and
/// omitting it is a deviation that is cheap now and awkward to add later.
///
/// The loop formats this once per tick and every response borrows the result, so the
/// cost is one conversion a second rather than one per request.
pub fn httpDate(unix_seconds: u64, out: *[http_date_len]u8) []const u8 {
    const days: u64 = unix_seconds / 86_400;
    const secs_of_day: u64 = unix_seconds % 86_400;

    // 1970-01-01 was a Thursday, which is index 4.
    const weekday: usize = @intCast((days + 4) % 7);
    const civil = civilFromDays(days);

    _ = std.fmt.bufPrint(out, "{s}, {d:0>2} {s} {d:0>4} {d:0>2}:{d:0>2}:{d:0>2} GMT", .{
        day_names[weekday],
        civil.day,
        month_names[civil.month - 1],
        civil.year,
        secs_of_day / 3600,
        (secs_of_day % 3600) / 60,
        secs_of_day % 60,
    }) catch unreachable;
    return out;
}

/// Length of `2026-08-30T20:41:07Z`.
pub const timestamp_len = 20;

/// Formats unix seconds as the timestamp shape `02-api.md` publishes.
///
/// Distinct from `httpDate`, which is the protocol's format. This one is the *product's*:
/// `X-Doot-Created-At`, `X-Doot-Expires-At` and the list and `whoami` bodies all use it.
/// RFC 3339 with a `Z` offset, seconds precision, because entry lifetimes are stored to
/// the second (`03-data-model.md`) and a fractional part would imply precision that is
/// not there.
pub fn timestamp(unix_seconds: u64, out: *[timestamp_len]u8) []const u8 {
    const civil = civilFromDays(unix_seconds / 86_400);
    const s = unix_seconds % 86_400;
    _ = std.fmt.bufPrint(out, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        civil.year, civil.month, civil.day,
        s / 3600,   (s % 3600) / 60, s % 60,
    }) catch unreachable;
    return out;
}

const Civil = struct { year: u32, month: u32, day: u32 };

/// Days since the epoch to a calendar date, by Howard Hinnant's `civil_from_days`.
///
/// Shifts the era to start in March so the leap day lands at the end of the cycle,
/// which is what removes every special case for February.
fn civilFromDays(days: u64) Civil {
    const z: u64 = days + 719_468;
    const era: u64 = z / 146_097;
    const doe: u64 = z - era * 146_097; // [0, 146096]
    const yoe: u64 = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365; // [0, 399]
    const y: u64 = yoe + era * 400;
    const doy: u64 = doe - (365 * yoe + yoe / 4 - yoe / 100); // [0, 365]
    const mp: u64 = (5 * doy + 2) / 153; // [0, 11], March = 0
    const d: u64 = doy - (153 * mp + 2) / 5 + 1; // [1, 31]
    const m: u64 = if (mp < 10) mp + 3 else mp - 9; // [1, 12]
    return .{
        .year = @intCast(if (m <= 2) y + 1 else y),
        .month = @intCast(m),
        .day = @intCast(d),
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "a status line and headers assemble in order" {
    var buf: [256]u8 = undefined;
    var w = Writer.init(&buf);
    try w.status(200, "OK");
    try w.header("Content-Type", "application/json");
    try w.headerInt("Content-Length", 42);
    try testing.expectEqualStrings(
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 42\r\n\r\n",
        try w.finish(),
    );
}

test "a status comes from the catalogue without restating it" {
    var buf: [128]u8 = undefined;
    var w = Writer.init(&buf);
    try w.statusOf(.not_found);
    try testing.expectEqualStrings("HTTP/1.1 404 Not Found\r\n", buf[0..w.len]);

    var buf2: [128]u8 = undefined;
    var w2 = Writer.init(&buf2);
    try w2.statusOf(.headers_too_large);
    try testing.expectEqualStrings("HTTP/1.1 431 Request Header Fields Too Large\r\n", buf2[0..w2.len]);
}

test "a header cannot inject a second response" {
    var buf: [256]u8 = undefined;
    var w = Writer.init(&buf);
    // The shape that matters: a stored Content-Type echoed back on a read.
    try testing.expectError(
        error.InvalidHeader,
        w.header("Content-Type", "text/plain\r\n\r\nHTTP/1.1 200 OK"),
    );
    try testing.expectError(error.InvalidHeader, w.header("Content-Type", "a\rb"));
    try testing.expectError(error.InvalidHeader, w.header("Content-Type", "a\nb"));
    try testing.expectError(error.InvalidHeader, w.header("Content-Type", "a\x00b"));
    try testing.expectError(error.InvalidHeader, w.header("X-Bad\r\nX-Other", "v"));
}

test "a head that will not fit fails rather than truncating" {
    var tiny: [8]u8 = undefined;
    var w = Writer.init(&tiny);
    try testing.expectError(error.NoSpaceLeft, w.status(200, "OK"));
}

test "the worst-case response head fits its buffer" {
    // Every header 02-api.md can put on one response at once, at maximum length.
    // Asserted rather than estimated, because overflowing this would turn a valid
    // response into a 500 only for the largest entries.
    var buf: [config.max_response_head_bytes]u8 = undefined;
    var w = Writer.init(&buf);
    var date: [http_date_len]u8 = undefined;

    const ct: [128]u8 = @splat('a');
    const name: [256]u8 = @splat('n');
    // Five 64-byte tags with comma separators.
    var tags: [5 * 64 + 4]u8 = @splat('t');
    inline for (.{ 64, 129, 194, 259 }) |i| tags[i] = ',';

    try w.status(200, "OK");
    try w.header("Date", httpDate(1_800_000_000, &date));
    try w.header("Content-Type", &ct);
    try w.headerInt("Content-Length", 262_144);
    try w.header("X-Doot-Tags", &tags);
    try w.header("X-Doot-Name", &name);
    try w.header("X-Doot-Created-At", "2026-08-30T20:41:07Z");
    try w.header("X-Doot-Expires-At", "2026-09-13T20:41:07Z");
    try w.headerInt("RateLimit-Limit", 500);
    try w.headerInt("RateLimit-Remaining", 499);
    try w.headerInt("RateLimit-Reset", 60);
    try w.headerInt("X-Doot-Credits-Remaining", 9_999_999);
    try w.header("Location", "/v1/entries/01JBQ2K9XW4V7N8M3PZR6TYAC5");
    try w.header("Idempotency-Replayed", "true");
    try w.header("Connection", "keep-alive");
    const head = try w.finish();

    try testing.expect(head.len <= config.max_response_head_bytes);
    // Headroom for the headers M3 and M4 add.
    try testing.expect(head.len < config.max_response_head_bytes - 512);
}

test "an unsent response offers both segments in order" {
    var out: [2]std.posix.iovec_const = undefined;
    var o: Outbound = .{ .head = "HEAD", .body = "BODY!" };

    try testing.expectEqual(@as(usize, 9), o.total());
    try testing.expect(!o.done());

    const iov = o.iovecs(&out);
    try testing.expectEqual(@as(usize, 2), iov.len);
    try testing.expectEqualStrings("HEAD", iov[0].base[0..iov[0].len]);
    try testing.expectEqualStrings("BODY!", iov[1].base[0..iov[1].len]);
}

test "a partial write resumes inside the head" {
    var out: [2]std.posix.iovec_const = undefined;
    var o: Outbound = .{ .head = "HEAD", .body = "BODY!" };
    o.advance(2);

    const iov = o.iovecs(&out);
    try testing.expectEqual(@as(usize, 2), iov.len);
    try testing.expectEqualStrings("AD", iov[0].base[0..iov[0].len]);
    try testing.expectEqualStrings("BODY!", iov[1].base[0..iov[1].len]);
    try testing.expectEqual(@as(usize, 7), o.remaining());
}

test "a partial write resumes inside the body, dropping the head entirely" {
    var out: [2]std.posix.iovec_const = undefined;
    var o: Outbound = .{ .head = "HEAD", .body = "BODY!" };
    o.advance(6);

    const iov = o.iovecs(&out);
    try testing.expectEqual(@as(usize, 1), iov.len);
    try testing.expectEqualStrings("DY!", iov[0].base[0..iov[0].len]);
}

test "the boundary between head and body is not off by one" {
    var out: [2]std.posix.iovec_const = undefined;
    var o: Outbound = .{ .head = "HEAD", .body = "BODY!" };
    o.advance(4); // exactly the head

    const iov = o.iovecs(&out);
    try testing.expectEqual(@as(usize, 1), iov.len);
    try testing.expectEqualStrings("BODY!", iov[0].base[0..iov[0].len]);
}

test "a fully written response offers nothing" {
    var out: [2]std.posix.iovec_const = undefined;
    var o: Outbound = .{ .head = "HEAD", .body = "BODY!" };
    o.advance(9);
    try testing.expect(o.done());
    try testing.expectEqual(@as(usize, 0), o.iovecs(&out).len);

    // Over-reporting cannot walk the cursor past the end.
    o.advance(100);
    try testing.expectEqual(@as(usize, 9), o.sent);
    try testing.expectEqual(@as(usize, 0), o.remaining());
}

test "a bodiless response never offers an empty segment" {
    var out: [2]std.posix.iovec_const = undefined;
    var o: Outbound = .{ .head = "HEAD" };
    const iov = o.iovecs(&out);
    try testing.expectEqual(@as(usize, 1), iov.len);
    o.advance(4);
    try testing.expect(o.done());
    try testing.expectEqual(@as(usize, 0), o.iovecs(&out).len);
}

test "one byte at a time reassembles the whole response exactly" {
    // The property that matters: whatever the kernel accepts per call, the bytes that
    // arrive are the response, once, in order.
    var head_buf: [64]u8 = undefined;
    var w = Writer.init(&head_buf);
    try w.status(200, "OK");
    try w.headerInt("Content-Length", 5);
    var o: Outbound = .{ .head = try w.finish(), .body = "hello" };

    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(testing.allocator);

    var out: [2]std.posix.iovec_const = undefined;
    while (!o.done()) {
        const iov = o.iovecs(&out);
        try testing.expect(iov.len > 0);
        try got.append(testing.allocator, iov[0].base[0]);
        o.advance(1);
    }

    try testing.expectEqualStrings(
        "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello",
        got.items,
    );
}

test "an error response is the catalogue shape with its head" {
    var head_buf: [config.max_response_head_bytes]u8 = undefined;
    var body_buf: [api.errors.max_body_bytes]u8 = undefined;

    const o = try writeError(.{
        .code = .not_found,
        .date = "Mon, 31 Aug 2026 12:00:00 GMT",
        .keep_alive = true,
    }, &head_buf, &body_buf);

    try testing.expectEqualStrings(
        "HTTP/1.1 404 Not Found\r\n" ++
            "Date: Mon, 31 Aug 2026 12:00:00 GMT\r\n" ++
            "Content-Type: application/json\r\n" ++
            "Content-Length: 120\r\n" ++
            "Connection: keep-alive\r\n\r\n",
        o.head,
    );
    try testing.expectEqualStrings(
        \\{"error":{"code":"not_found","message":"No entry exists at that name.","docs":"https://doot.run/docs/errors#not_found"}}
    , o.body);
    // The declared length is the body's actual length, which is what a keep-alive
    // client uses to find the end of this response and the start of the next.
    try testing.expectEqual(@as(usize, 120), o.body.len);
}

test "an error response carries the handler's headers too" {
    // Regression. These were dropped on the error path, which meant a `429` — the one
    // response where a caller most needs to see its budget — arrived without the
    // `RateLimit-*` trio that `02-api.md` puts on every `/v1` response.
    var head_buf: [config.max_response_head_bytes]u8 = undefined;
    var body_buf: [api.errors.max_body_bytes]u8 = undefined;

    const o = try writeError(.{
        .code = .rate_limited,
        .date = "Mon, 31 Aug 2026 12:00:00 GMT",
        .keep_alive = true,
        .retry_after_s = 34,
        .extra = &.{
            .{ .name = "RateLimit-Limit", .value = "100" },
            .{ .name = "RateLimit-Remaining", .value = "0" },
            .{ .name = "RateLimit-Reset", .value = "60" },
        },
    }, &head_buf, &body_buf);

    try testing.expect(std.mem.indexOf(u8, o.head, "RateLimit-Limit: 100\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, o.head, "RateLimit-Remaining: 0\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, o.head, "RateLimit-Reset: 60\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, o.head, "Retry-After: 34\r\n") != null);
    // And the body is still the catalogue's.
    try testing.expect(std.mem.indexOf(u8, o.body, "\"code\":\"rate_limited\"") != null);
}

test "an error response's extra headers cannot inject" {
    var head_buf: [config.max_response_head_bytes]u8 = undefined;
    var body_buf: [api.errors.max_body_bytes]u8 = undefined;
    try testing.expectError(error.InvalidHeader, writeError(.{
        .code = .not_found,
        .date = "Mon, 31 Aug 2026 12:00:00 GMT",
        .keep_alive = true,
        .extra = &.{.{ .name = "X-Bad", .value = "a\r\nX-Injected: yes" }},
    }, &head_buf, &body_buf));
}

test "429 carries Retry-After and 405 carries Allow" {
    var head_buf: [config.max_response_head_bytes]u8 = undefined;
    var body_buf: [api.errors.max_body_bytes]u8 = undefined;

    const limited = try writeError(.{
        .code = .rate_limited,
        .date = "Mon, 31 Aug 2026 12:00:00 GMT",
        .keep_alive = true,
        .retry_after_s = 34,
    }, &head_buf, &body_buf);
    try testing.expect(std.mem.indexOf(u8, limited.head, "Retry-After: 34\r\n") != null);

    var head_buf2: [config.max_response_head_bytes]u8 = undefined;
    var body_buf2: [api.errors.max_body_bytes]u8 = undefined;
    const wrong_method = try writeError(.{
        .code = .method_not_allowed,
        .date = "Mon, 31 Aug 2026 12:00:00 GMT",
        .keep_alive = false,
        .allow = "GET, PUT, DELETE",
    }, &head_buf2, &body_buf2);
    try testing.expect(std.mem.indexOf(u8, wrong_method.head, "Allow: GET, PUT, DELETE\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, wrong_method.head, "Connection: close\r\n") != null);
}

test "every catalogue code produces a response that fits its buffers" {
    // An error path that overflows its own buffer would replace the error with a
    // different one, which is exactly the failure D52 wanted to make impossible.
    inline for (@typeInfo(Code).@"enum".fields) |f| {
        var head_buf: [config.max_response_head_bytes]u8 = undefined;
        var body_buf: [api.errors.max_body_bytes]u8 = undefined;
        const o = try writeError(.{
            .code = @enumFromInt(f.value),
            .date = "Mon, 31 Aug 2026 12:00:00 GMT",
            .keep_alive = false,
            .retry_after_s = 60,
            .allow = "GET, PUT, POST, DELETE",
        }, &head_buf, &body_buf);
        try testing.expect(o.total() > 0);
    }
}

test "the HTTP date matches RFC 9110's own example" {
    var buf: [http_date_len]u8 = undefined;
    // The example date from the specification, and its exact epoch second.
    try testing.expectEqualStrings("Sun, 06 Nov 1994 08:49:37 GMT", httpDate(784_111_777, &buf));
    try testing.expectEqual(@as(usize, http_date_len), httpDate(784_111_777, &buf).len);
}

test "the HTTP date handles the epoch, leap years and century rules" {
    var buf: [http_date_len]u8 = undefined;
    try testing.expectEqualStrings("Thu, 01 Jan 1970 00:00:00 GMT", httpDate(0, &buf));
    // Last second before the epoch day rolls over.
    try testing.expectEqualStrings("Thu, 01 Jan 1970 23:59:59 GMT", httpDate(86_399, &buf));
    // 2000 was a leap year: divisible by 400.
    try testing.expectEqualStrings("Tue, 29 Feb 2000 12:00:00 GMT", httpDate(951_825_600, &buf));
    // 2024 was a leap year: divisible by 4.
    try testing.expectEqualStrings("Thu, 29 Feb 2024 00:00:00 GMT", httpDate(1_709_164_800, &buf));
    // 1900 was not, but that predates the epoch; 2100 is the reachable case and is
    // not a leap year, so 28 February is followed by 1 March.
    try testing.expectEqualStrings("Sun, 28 Feb 2100 00:00:00 GMT", httpDate(4_107_456_000, &buf));
    try testing.expectEqualStrings("Mon, 01 Mar 2100 00:00:00 GMT", httpDate(4_107_542_400, &buf));
}

test "every weekday name is reachable and in the right order" {
    var buf: [http_date_len]u8 = undefined;
    // 2026-08-31 was a Monday. Seven consecutive days from there.
    const monday: u64 = 1_788_134_400;
    inline for (.{ "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" }, 0..) |name, i| {
        const text = httpDate(monday + i * 86_400, &buf);
        try testing.expectEqualStrings(name, text[0..3]);
    }
}

test "every month name is reachable" {
    var buf: [http_date_len]u8 = undefined;
    // First of each month through 2026, a non-leap year.
    const firsts = [12]u64{
        1_767_225_600, 1_769_904_000, 1_772_323_200, 1_775_001_600,
        1_777_593_600, 1_780_272_000, 1_782_864_000, 1_785_542_400,
        1_788_220_800, 1_790_812_800, 1_793_491_200, 1_796_083_200,
    };
    inline for (month_names, 0..) |name, i| {
        const text = httpDate(firsts[i], &buf);
        try testing.expectEqualStrings(name, text[8..11]);
        try testing.expectEqualStrings("01", text[5..7]);
        try testing.expectEqualStrings("2026", text[12..16]);
    }
}
