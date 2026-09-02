//! Outbound mail: a bounded queue, and the ZeptoMail call that drains it (D69, D78).
//!
//! **A request never blocks on delivery.** `06-auth.md` requires the signup response to
//! return as soon as the code is persisted, and D75 requires the timing not to depend on
//! whether an address exists — an inline send would break both, because a third party's
//! latency is not something we control or can equalise.
//!
//! So enqueueing is memory-only and happens on the event loop; the sending happens on the
//! mail thread `boot.zig` runs. That thread is **separate from maintenance**, because
//! maintenance blocks on local disk for a bounded time and this blocks on a third party for
//! an unbounded one — sharing would let a slow provider stop expiry sweeps and snapshots,
//! and by D63 no snapshots means D38's recovery bound stops holding.
//!
//! **A full queue fails the enqueue**, surfacing as a `503` on the request rather than an
//! unbounded backlog. A user retrying in a moment is a better outcome than a queue that
//! grows until the box dies.

const std = @import("std");
const storage = @import("storage");
const api = @import("api");

const os = storage.os;

/// Deep enough that a burst of signups never touches the ceiling, shallow enough that a
/// dead provider cannot hold much: 256 × ~300 B is under 80 KiB.
pub const capacity: usize = 256;

/// Attempts before a message is dropped and counted (D78).
pub const max_attempts: u8 = 4;

/// Backoff between attempts, in seconds. Indexed by attempts already made.
const backoff_s = [_]u32{ 0, 5, 30, 120 };

/// ZeptoMail's Indian region, which is the one this zone's DKIM record points at
/// (`cluster89.zeptomail.in`).
///
/// Hardcoded rather than configured, because `05-architecture.md`'s variable list contains a
/// token and no endpoint, and inventing a variable is a decision D78 would have to carry. If
/// a second region is ever needed this becomes `DOOT_ZEPTOMAIL_ENDPOINT` in the milestone
/// that needs it — which is exactly D78's per-variable rule applied to itself.
pub const endpoint = "https://api.zeptomail.in/v1.1/email";

pub const Kind = enum {
    /// The signup verification code.
    verify,
    /// The password-reset code.
    reset,
    /// 80% and 100% credit notifications (`01-product.md`).
    credits_80,
    credits_100,
};

/// One queued message.
///
/// Fixed-size and copied by value, so the queue allocates nothing and a message cannot
/// borrow a slice that has gone by the time the thread reaches it — which is the shape of
/// bug a queue of pointers invites.
pub const Message = struct {
    kind: Kind,
    to_buf: [api.email.max_bytes]u8 = undefined,
    to_len: u16 = 0,
    /// The OTP, for `verify` and `reset`. Empty otherwise.
    code: [8]u8 = @splat(0),
    code_len: u8 = 0,
    attempts: u8 = 0,
    /// Earliest time this may be attempted, for backoff.
    not_before: u32 = 0,

    pub fn to(m: *const Message) []const u8 {
        return m.to_buf[0..m.to_len];
    }
    pub fn codeText(m: *const Message) []const u8 {
        return m.code[0..m.code_len];
    }

    pub fn init(kind: Kind, recipient: []const u8, code: []const u8) ?Message {
        if (recipient.len == 0 or recipient.len > api.email.max_bytes) return null;
        if (code.len > 8) return null;
        var m: Message = .{ .kind = kind, .to_len = @intCast(recipient.len) };
        @memcpy(m.to_buf[0..recipient.len], recipient);
        @memcpy(m.code[0..code.len], code);
        m.code_len = @intCast(code.len);
        return m;
    }
};

pub const Enqueued = enum { queued, full };

/// A fixed ring, guarded by a mutex.
///
/// The mutex is held only to move a message in or out — never across the HTTP call, which is
/// the whole reason the queue exists.
pub const Queue = struct {
    items: [capacity]Message = undefined,
    head: usize = 0,
    len: usize = 0,
    mutex: os.Mutex = .{},

    queued: u64 = 0,
    refused: u64 = 0,
    sent: u64 = 0,
    dropped: u64 = 0,

    pub fn push(q: *Queue, m: Message) Enqueued {
        q.mutex.lock();
        defer q.mutex.unlock();
        if (q.len == capacity) {
            q.refused += 1;
            return .full;
        }
        q.items[(q.head + q.len) % capacity] = m;
        q.len += 1;
        q.queued += 1;
        return .queued;
    }

    /// Takes the next message due at `now`, or null.
    ///
    /// A message still inside its backoff is rotated to the back rather than blocking the
    /// queue behind it: one unlucky recipient must not delay everyone else's code.
    pub fn pop(q: *Queue, now: u32) ?Message {
        q.mutex.lock();
        defer q.mutex.unlock();

        var scanned: usize = 0;
        while (scanned < q.len) : (scanned += 1) {
            const m = q.items[q.head];
            q.head = (q.head + 1) % capacity;
            q.len -= 1;
            if (m.not_before <= now) return m;
            // Not due: put it back at the tail.
            q.items[(q.head + q.len) % capacity] = m;
            q.len += 1;
        }
        return null;
    }

    /// Returns a failed message for another attempt, or drops it.
    pub fn retry(q: *Queue, m: Message, now: u32) void {
        var next = m;
        next.attempts += 1;
        if (next.attempts >= max_attempts) {
            q.mutex.lock();
            defer q.mutex.unlock();
            // Dropped and counted. A lost OTP degrades to a resend, which `06-auth.md`
            // already budgets three of per hour.
            q.dropped += 1;
            return;
        }
        next.not_before = now +| backoff_s[next.attempts];
        _ = q.push(next);
    }

    pub fn depth(q: *Queue) usize {
        q.mutex.lock();
        defer q.mutex.unlock();
        return q.len;
    }
};

pub const Config = struct {
    /// `DOOT_ZEPTOMAIL_TOKEN`.
    token: []const u8,
    /// `DOOT_SUPPORT_EMAIL` — also the From address, so a reply reaches a human.
    support_email: []const u8,
    /// `DOOT_PUBLIC_ORIGIN`, for the links in the body.
    public_origin: []const u8,
};

fn subjectFor(kind: Kind) []const u8 {
    return switch (kind) {
        .verify => "Your Doot verification code",
        .reset => "Your Doot password reset code",
        .credits_80 => "You have used 80% of your Doot credits",
        .credits_100 => "Your Doot write credits are exhausted",
    };
}

/// Renders the plain-text body. No HTML: a code and a sentence do not need it, and an
/// HTML body is a second thing to escape correctly.
fn bodyFor(m: *const Message, cfg: Config, buf: []u8) ![]const u8 {
    return switch (m.kind) {
        .verify => std.fmt.bufPrint(buf,
            \\Your Doot verification code is {s}
            \\
            \\It expires in 10 minutes. If you did not request it, ignore this message.
        , .{m.codeText()}),
        .reset => std.fmt.bufPrint(buf,
            \\Your Doot password reset code is {s}
            \\
            \\It expires in 10 minutes. If you did not request it, ignore this message
            \\and your password will stay as it is.
        , .{m.codeText()}),
        .credits_80 => std.fmt.bufPrint(buf,
            \\You have used 80% of your Doot write credits.
            \\
            \\Reads, lists and deletes are always free and will keep working. To buy more
            \\credits, mail {s}
        , .{cfg.support_email}),
        .credits_100 => std.fmt.bufPrint(buf,
            \\Your Doot write credits are exhausted.
            \\
            \\Your data is safe and still readable, and it continues to expire normally.
            \\Only new writes are refused. To buy more credits, mail {s}
            \\
            \\{s}
        , .{ cfg.support_email, cfg.public_origin }),
    };
}

pub const SendError = error{ Rejected, Transport };

/// Posts one message to ZeptoMail.
///
/// Runs on the mail thread. Uses `std.http.Client` over a `std.Io.Threaded` — which D69
/// measured as working on this toolchain, and whose objection in D27 was about an event loop
/// parking thousands of idle connections rather than a client making one call at a time.
pub fn send(gpa: std.mem.Allocator, m: *const Message, cfg: Config) SendError!void {
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();

    var client: std.http.Client = .{ .allocator = gpa, .io = threaded.io() };
    defer client.deinit();

    var body_buf: [512]u8 = undefined;
    const text = bodyFor(m, cfg, &body_buf) catch return error.Rejected;

    // Built with the JSON writer the rest of the tree uses, so escaping is one
    // implementation rather than two.
    var payload: [1536]u8 = undefined;
    var w = @import("json.zig").Writer.init(&payload);
    buildPayload(&w, m, cfg, text) catch return error.Rejected;

    var auth: [256]u8 = undefined;
    const auth_value = std.fmt.bufPrint(&auth, "Zoho-enczapikey {s}", .{cfg.token}) catch
        return error.Rejected;

    var sink: std.Io.Writer.Discarding = .init(&.{});
    const res = client.fetch(.{
        .location = .{ .url = endpoint },
        .method = .POST,
        .payload = w.done(),
        .response_writer = &sink.writer,
        .extra_headers = &.{
            .{ .name = "authorization", .value = auth_value },
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "accept", .value = "application/json" },
        },
    }) catch return error.Transport;

    const code = @intFromEnum(res.status);
    if (code >= 200 and code < 300) return;
    // 4xx is ours to fix and will not improve with a retry; 5xx might.
    if (code >= 400 and code < 500) return error.Rejected;
    return error.Transport;
}

fn buildPayload(
    w: *@import("json.zig").Writer,
    m: *const Message,
    cfg: Config,
    text: []const u8,
) !void {
    try w.beginObject();
    try w.key("from");
    try w.beginObject();
    try w.stringMember("address", cfg.support_email);
    try w.endObject();
    try w.key("to");
    try w.beginArray();
    try w.beginObject();
    try w.key("email_address");
    try w.beginObject();
    try w.stringMember("address", m.to());
    try w.endObject();
    try w.endObject();
    try w.endArray();
    try w.stringMember("subject", subjectFor(m.kind));
    try w.stringMember("textbody", text);
    try w.endObject();
}

/// One pass over the queue, for the mail thread to call.
///
/// Returns how many were sent. Failures are logged and counted by the caller; a mail failure
/// is never fatal, for the same reason a maintenance failure is not (D63).
pub fn drainOnce(gpa: std.mem.Allocator, q: *Queue, cfg: Config, now: u32) usize {
    var sent: usize = 0;
    while (q.pop(now)) |m| {
        send(gpa, &m, cfg) catch |err| {
            switch (err) {
                // Not worth retrying: the provider refused the request itself.
                error.Rejected => {
                    q.mutex.lock();
                    q.dropped += 1;
                    q.mutex.unlock();
                },
                error.Transport => q.retry(m, now),
            }
            continue;
        };
        q.mutex.lock();
        q.sent += 1;
        q.mutex.unlock();
        sent += 1;
    }
    return sent;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const test_cfg: Config = .{
    .token = "test-token",
    .support_email = "support@doot.run",
    .public_origin = "https://doot.run",
};

test "a message copies its recipient rather than borrowing it" {
    var buf: [32]u8 = undefined;
    @memcpy(buf[0..16], "someone@test.com");
    const m = Message.init(.verify, buf[0..16], "123456").?;
    // Scribble over the source: a queue of pointers would now hold garbage.
    @memset(buf[0..16], 'x');
    try testing.expectEqualStrings("someone@test.com", m.to());
    try testing.expectEqualStrings("123456", m.codeText());
}

test "an over-long recipient or code is refused at construction" {
    try testing.expect(Message.init(.verify, "", "123456") == null);
    try testing.expect(Message.init(.verify, "a" ** (api.email.max_bytes + 1), "1") == null);
    try testing.expect(Message.init(.verify, "a@b.co", "123456789") == null);
}

test "the queue is bounded, and a full one refuses the enqueue" {
    var q: Queue = .{};
    const m = Message.init(.verify, "a@b.co", "123456").?;

    var i: usize = 0;
    while (i < capacity) : (i += 1) try testing.expectEqual(Enqueued.queued, q.push(m));
    // A full queue fails the enqueue rather than growing: the request becomes a 503 and the
    // user retries, which is better than a backlog that kills the box (D78).
    try testing.expectEqual(Enqueued.full, q.push(m));
    try testing.expectEqual(@as(u64, 1), q.refused);
    try testing.expectEqual(capacity, q.depth());
}

test "messages come out in the order they went in" {
    var q: Queue = .{};
    _ = q.push(Message.init(.verify, "first@b.co", "1").?);
    _ = q.push(Message.init(.verify, "second@b.co", "2").?);

    try testing.expectEqualStrings("first@b.co", q.pop(100).?.to());
    try testing.expectEqualStrings("second@b.co", q.pop(100).?.to());
    try testing.expect(q.pop(100) == null);
}

test "a message inside its backoff does not block the ones behind it" {
    var q: Queue = .{};
    var deferred = Message.init(.verify, "later@b.co", "1").?;
    deferred.not_before = 1_000;
    _ = q.push(deferred);
    _ = q.push(Message.init(.verify, "now@b.co", "2").?);

    // One unlucky recipient must not delay everyone else's code.
    try testing.expectEqualStrings("now@b.co", q.pop(100).?.to());
    try testing.expect(q.pop(100) == null);
    try testing.expectEqualStrings("later@b.co", q.pop(1_000).?.to());
}

test "retries back off and then the message is dropped and counted" {
    var q: Queue = .{};
    var m = Message.init(.verify, "a@b.co", "1").?;

    q.retry(m, 100);
    const first = q.pop(100 + backoff_s[1]).?;
    try testing.expectEqual(@as(u8, 1), first.attempts);

    // Walk it to the ceiling.
    m.attempts = max_attempts - 1;
    q.retry(m, 100);
    try testing.expectEqual(@as(u64, 1), q.dropped);
    try testing.expect(q.pop(1_000_000) == null);
}

test "the ring wraps without losing or duplicating a message" {
    var q: Queue = .{};
    var i: usize = 0;
    // Fill, drain most, refill past the wrap point.
    while (i < capacity) : (i += 1) _ = q.push(Message.init(.verify, "a@b.co", "1").?);
    i = 0;
    while (i < capacity - 1) : (i += 1) _ = q.pop(100);
    try testing.expectEqual(@as(usize, 1), q.depth());

    i = 0;
    while (i < capacity - 1) : (i += 1) {
        try testing.expectEqual(Enqueued.queued, q.push(Message.init(.verify, "b@b.co", "2").?));
    }
    try testing.expectEqual(capacity, q.depth());
}

test "the payload is valid JSON with the recipient, subject and code in it" {
    const m = Message.init(.verify, "someone@test.com", "483927").?;
    var body_buf: [512]u8 = undefined;
    const text = try bodyFor(&m, test_cfg, &body_buf);

    var payload: [1536]u8 = undefined;
    var w = @import("json.zig").Writer.init(&payload);
    try buildPayload(&w, &m, test_cfg, text);
    const out = w.done();

    try testing.expect(std.mem.indexOf(u8, out, "\"address\":\"someone@test.com\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Your Doot verification code") != null);
    try testing.expect(std.mem.indexOf(u8, out, "483927") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"from\"") != null);
    // Parseable, which is the point of using the tree's own writer rather than bufPrint.
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out, .{});
    defer parsed.deinit();
}

test "an address that would break out of the JSON string cannot" {
    // The recipient reaches the payload, so a quote or a control byte in it must be escaped
    // rather than terminating the string early. api/email.zig refuses these upstream; this
    // asserts the writer would hold anyway, because two defences are the right number for a
    // value that crosses into another system.
    const m = Message.init(.verify, "a\"b\\c@test.com", "1").?;
    var body_buf: [512]u8 = undefined;
    const text = try bodyFor(&m, test_cfg, &body_buf);
    var payload: [1536]u8 = undefined;
    var w = @import("json.zig").Writer.init(&payload);
    try buildPayload(&w, &m, test_cfg, text);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, w.done(), .{});
    defer parsed.deinit();
}

test "every kind renders a body, and the two credit ones name the support address" {
    inline for (@typeInfo(Kind).@"enum".fields) |f| {
        const kind: Kind = @enumFromInt(f.value);
        const m = Message.init(kind, "a@b.co", "123456").?;
        var buf: [512]u8 = undefined;
        const text = try bodyFor(&m, test_cfg, &buf);
        try testing.expect(text.len > 0);
        try testing.expect(subjectFor(kind).len > 0);
        switch (kind) {
            .credits_80, .credits_100 => {
                // 01-product.md promises the support address appears in the notification.
                try testing.expect(std.mem.indexOf(u8, text, test_cfg.support_email) != null);
            },
            .verify, .reset => {
                try testing.expect(std.mem.indexOf(u8, text, "123456") != null);
                try testing.expect(std.mem.indexOf(u8, text, "10 minutes") != null);
            },
        }
    }
}

test "the endpoint matches the region this zone's DKIM points at" {
    // cluster89.zeptomail.in, so the Indian region. Asserted rather than commented, because
    // a wrong region fails at the first real signup and nowhere earlier.
    try testing.expect(std.mem.indexOf(u8, endpoint, "zeptomail.in") != null);
    try testing.expect(std.mem.startsWith(u8, endpoint, "https://"));
}
