//! The control plane's state and its pure helpers (D73).
//!
//! The **handlers** are methods on `Service` in `service.zig`, not here, and that is
//! deliberate: `GET /app/entries` and `GET /app/entries/{name}` must go through the *same*
//! list and read path `/v1` uses. `00-vision.md` makes the explorer read-only precisely so
//! there is one code path, and a second implementation of a read is exactly the divergence
//! that boundary exists to prevent.
//!
//! What lives here is everything that has no business being a `Service` field: the
//! control-plane configuration, the derived email index, and the small decisions that are
//! testable on their own.

const std = @import("std");
const storage = @import("storage");
const control = @import("control");
const api = @import("api");
const server = @import("server");

const challenge = @import("challenge.zig");
const password = @import("password.zig");
const ratelimit = @import("ratelimit.zig");
const mail = @import("mail.zig");

/// Configuration the control plane needs, from D78's five environment variables.
///
/// Borrowed rather than copied: `std.process.Init` owns the environment for the life of the
/// process, and a second copy would be a second thing to size.
pub const Config = struct {
    /// `DOOT_PUBLIC_ORIGIN` — builds the OAuth `redirect_uri` and the links in mail.
    public_origin: []const u8,
    /// `DOOT_SUPPORT_EMAIL` — the From address, and what a `402` points at.
    support_email: []const u8,
    /// `DOOT_GITHUB_CLIENT_ID`, `DOOT_GITHUB_CLIENT_SECRET`.
    github_client_id: []const u8,
    github_client_secret: []const u8,
    /// `DOOT_ZEPTOMAIL_TOKEN`.
    zeptomail_token: []const u8,

    pub fn mailConfig(c: Config) mail.Config {
        return .{
            .token = c.zeptomail_token,
            .support_email = c.support_email,
            .public_origin = c.public_origin,
        };
    }
};

/// `06-auth.md`: minimum 10 characters, no composition rules. Length beats character-class
/// theatre.
pub const min_password_bytes: usize = 10;

/// A ceiling, so a signup cannot ask us to hash a megabyte.
///
/// Argon2id's cost is dominated by its memory parameter rather than by input length, so this
/// is not about the hash — it is about not copying an unbounded body into a stack buffer on
/// the way to it.
pub const max_password_bytes: usize = 256;

/// Email anchor digest → account id.
///
/// **Derived state, rebuilt at boot.** Login has to find an account from an address, and the
/// normalisation that makes that work lives in `api`, which `control` may not import — so the
/// index is owned by the layer that can compute it (see `Control.forEachAccount`). Logging it
/// instead would have meant a permanent wire change to `account_created` to serve something a
/// single pass over an in-RAM map reconstructs.
///
/// Keyed on the **anchor**, not the delivery address, so `Some.One@Gmail.com` signs in to the
/// account registered as `someone@gmail.com` — the same identity the trial grant is bound to
/// (D72). Matching the raw address instead would make signing in depend on how the user
/// happened to type it.
pub const EmailIndex = struct {
    map: std.HashMapUnmanaged([32]u8, u32, Context, 80) = .empty,
    gpa: std.mem.Allocator,

    const Context = struct {
        pub fn hash(_: Context, k: [32]u8) u64 {
            return std.mem.readInt(u64, k[0..8], .little);
        }
        pub fn eql(_: Context, a: [32]u8, b: [32]u8) bool {
            return std.mem.eql(u8, &a, &b);
        }
    };

    pub fn init(gpa: std.mem.Allocator) EmailIndex {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *EmailIndex) void {
        self.map.deinit(self.gpa);
    }

    pub fn put(self: *EmailIndex, anchor: [32]u8, account_id: u32) !void {
        try self.map.put(self.gpa, anchor, account_id);
    }

    pub fn get(self: *const EmailIndex, anchor: [32]u8) ?u32 {
        return self.map.get(anchor);
    }

    pub fn remove(self: *EmailIndex, anchor: [32]u8) void {
        _ = self.map.remove(anchor);
    }

    pub fn count(self: *const EmailIndex) usize {
        return self.map.count();
    }

    /// Rebuilds from the control log's account image.
    ///
    /// An address that no longer normalises — which nothing we accepted should be, but a log
    /// written by an older build might contain — is skipped rather than fatal. Refusing to
    /// start over one unindexable account would take the whole service down for a row that
    /// only affects that account's ability to sign in.
    pub fn rebuild(self: *EmailIndex, ctl: *control.Control) void {
        const Visitor = struct {
            index: *EmailIndex,
            fn visit(v: *@This(), account: control.Account) void {
                const anchor = api.email.anchorHash(account.email) catch return;
                v.index.put(anchor, account.id) catch return;
            }
        };
        var v: Visitor = .{ .index = self };
        ctl.forEachAccount(&v, Visitor.visit);
    }
};

/// One connection parked on the live feed (D84, D86, D87).
///
/// Carries no buffer of its own: frames are built in the connection's idle read buffer, which a
/// parked stream is never going to read into (D86). What lives here is the *meaning* — whose
/// events these are, and where in the ring the subscriber has got to.
pub const Subscriber = struct {
    in_use: bool = false,
    /// Whose events. The filter is the whole of the isolation requirement here, and it happens
    /// on the loop where the session's account is already known.
    account_id: u32 = 0,
    /// Position in the ring. This *is* the queue, which is why no queue is needed (D86).
    cursor: storage.feed.Cursor = .{},
    /// When the next heartbeat is due.
    due_s: u32 = 0,
    /// Set once `Feed.poll` reports the subscriber was lapped, so the next frame says so.
    resync: bool = false,
};

/// A fixed table of parked streams.
///
/// Fixed because this is the one surface held open by definition, so a structure that grew per
/// subscriber would make a connection spike an out-of-memory risk (D86). At 1,024 entries of a
/// few dozen bytes it is tens of kilobytes, and the frame buffers cost nothing at all.
pub const Subscribers = struct {
    slots: [server.config.max_subscribers]Subscriber = @splat(.{}),
    live: u32 = 0,
    peak: u32 = 0,

    pub fn acquire(self: *Subscribers) ?u64 {
        for (&self.slots, 0..) |*s, i| {
            if (s.in_use) continue;
            s.* = .{ .in_use = true };
            self.live += 1;
            if (self.live > self.peak) self.peak = self.live;
            return @intCast(i);
        }
        return null;
    }

    pub fn at(self: *Subscribers, token: u64) ?*Subscriber {
        if (token >= self.slots.len) return null;
        const s = &self.slots[@intCast(token)];
        return if (s.in_use) s else null;
    }

    pub fn release(self: *Subscribers, token: u64) void {
        if (token >= self.slots.len) return;
        const s = &self.slots[@intCast(token)];
        if (!s.in_use) return;
        s.* = .{};
        if (self.live > 0) self.live -= 1;
    }
};

/// Everything the control plane needs that the data plane does not.
///
/// One struct behind one pointer on `Service`, rather than eight more `Service` fields: a
/// `Service` is copied by value into a handler vtable, and these are large.
pub const State = struct {
    gpa: std.mem.Allocator,
    cfg: Config,
    challenges: *challenge.Table,
    unauth: *ratelimit.Unauthenticated,
    dummy: *password.Dummy,
    queue: *mail.Queue,
    emails: *EmailIndex,
    /// Guards `emails`, which the loop reads and a worker writes after a signup completes.
    emails_mutex: storage.os.Mutex = .{},

    /// Parked live-feed connections (D86).
    ///
    /// **No mutex, deliberately.** Every access happens on the event loop: subscribing is part
    /// of `respond`, framing is the `Stream` seam the loop calls on its feed timer, and
    /// releasing is `closeConn`. A lock here would be a lock protecting a single thread from
    /// itself — and adding one would invite a future caller to touch this from a worker, which
    /// is exactly what must not happen, because framing may not touch a disk (D85).
    subscribers: *Subscribers,

    pub fn lookupAccount(self: *State, anchor: [32]u8) ?u32 {
        self.emails_mutex.lock();
        defer self.emails_mutex.unlock();
        return self.emails.get(anchor);
    }

    pub fn indexAccount(self: *State, anchor: [32]u8, account_id: u32) void {
        self.emails_mutex.lock();
        defer self.emails_mutex.unlock();
        self.emails.put(anchor, account_id) catch {};
    }

    pub fn unindexAccount(self: *State, anchor: [32]u8) void {
        self.emails_mutex.lock();
        defer self.emails_mutex.unlock();
        self.emails.remove(anchor);
    }
};

/// The bytes that identify a client for rate-limiting purposes (D74).
///
/// `CF-Connecting-IP` when present, the socket peer otherwise, and a fixed placeholder when
/// neither is available. The placeholder matters: without it every address-less request
/// would hash to whatever an empty slice hashes to, which is the same bucket — so naming it
/// makes the sharing deliberate rather than accidental.
///
/// **The header is only trustworthy once the origin refuses connections that did not arrive
/// through Cloudflare**, which lands at the end of M5 (D68). Until then the global ceiling is
/// what actually bounds this surface, and that is why it exists.
pub fn clientAddress(in: server.handler.Incoming, out: []u8) []const u8 {
    std.debug.assert(out.len >= server.net.client_key_bytes);

    if (in.header("cf-connecting-ip")) |ip| {
        const trimmed = std.mem.trim(u8, ip, " \t");
        if (trimmed.len > 0 and trimmed.len <= out.len) {
            @memcpy(out[0..trimmed.len], trimmed);
            return out[0..trimmed.len];
        }
    }
    if (in.peer()) |addr| return addr.clientKey(out);
    return "unknown";
}

/// Is this password acceptable? `06-auth.md`: at least 10 characters, nothing else.
pub fn passwordAcceptable(pw: []const u8) bool {
    return pw.len >= min_password_bytes and pw.len <= max_password_bytes;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "the index is keyed on the anchor, so case and plus-addressing still sign in" {
    var idx = EmailIndex.init(testing.allocator);
    defer idx.deinit();

    try idx.put(try api.email.anchorHash("someone@gmail.com"), 42);

    // The same identity, spelled differently, finds the same account -- which is the point
    // of keying on the anchor rather than on the address the user typed (D72).
    for ([_][]const u8{
        "someone@gmail.com",
        "SomeOne@Gmail.com",
        "some.one@gmail.com",
        "someone+ci@googlemail.com",
    }) |spelling| {
        try testing.expectEqual(@as(u32, 42), idx.get(try api.email.anchorHash(spelling)).?);
    }

    // A different identity does not.
    try testing.expect(idx.get(try api.email.anchorHash("other@gmail.com")) == null);
}

test "removing an entry stops it resolving" {
    var idx = EmailIndex.init(testing.allocator);
    defer idx.deinit();
    const anchor = try api.email.anchorHash("gone@b.co");
    try idx.put(anchor, 7);
    idx.remove(anchor);
    try testing.expect(idx.get(anchor) == null);
    try testing.expectEqual(@as(usize, 0), idx.count());
}

test "the client address prefers the header and falls back to a named placeholder" {
    const head_mod = server.head;
    var h: head_mod.Head = .{};
    var buf: [server.net.client_key_bytes]u8 = undefined;

    // No header and no socket: a deliberate, named bucket rather than whatever an empty
    // slice happens to hash to.
    const in: server.handler.Incoming = .{ .head = &h, .body = &.{}, .socket = -1 };
    try testing.expectEqualStrings("unknown", clientAddress(in, &buf));
}

test "a password is judged only on length" {
    // 06-auth.md: minimum 10 characters, no composition rules -- length beats
    // character-class theatre.
    try testing.expect(!passwordAcceptable(""));
    try testing.expect(!passwordAcceptable("short"));
    try testing.expect(!passwordAcceptable("123456789"));
    try testing.expect(passwordAcceptable("1234567890"));
    try testing.expect(passwordAcceptable("correct horse battery staple"));
    // All-lowercase with no digits is fine, which is the whole point.
    try testing.expect(passwordAcceptable("aaaaaaaaaaaa"));
    // But not unbounded: the ceiling is about not copying a megabyte to the hash, not about
    // the hash's cost.
    try testing.expect(!passwordAcceptable("a" ** (max_password_bytes + 1)));
}

test "the mail config is derived from the one configuration struct" {
    const cfg: Config = .{
        .public_origin = "https://doot.run",
        .support_email = "support@doot.run",
        .github_client_id = "id",
        .github_client_secret = "secret",
        .zeptomail_token = "tok",
    };
    const mc = cfg.mailConfig();
    try testing.expectEqualStrings("tok", mc.token);
    try testing.expectEqualStrings("support@doot.run", mc.support_email);
    try testing.expectEqualStrings("https://doot.run", mc.public_origin);
}
