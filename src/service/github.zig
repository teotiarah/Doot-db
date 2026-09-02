//! GitHub OAuth: the authorize URL, and the token exchange behind the callback (`06-auth.md`).
//!
//! Standard authorization code flow. The `state` binding lives in `challenge.Table` and the
//! cookie that pairs with it in `api/cookie.zig`; this file is the part that talks to GitHub.
//!
//! **The exchange is synchronous, on an I/O worker.** D78 settled that: the user is mid-redirect
//! and there is no outcome to deliver later, so queueing it would mean queueing the person. It
//! blocks, which is why it may not run on the event loop (D57), and it carries a timeout so a
//! hung third party becomes an error page rather than a parked connection.
//!
//! Scope is `read:user user:email` and nothing more. Doot never needs repository access and
//! asking for it would cost signups.

const std = @import("std");
const api = @import("api");

pub const scope = "read:user user:email";
pub const authorize_endpoint = "https://github.com/login/oauth/authorize";
pub const token_endpoint = "https://github.com/login/oauth/access_token";
pub const user_endpoint = "https://api.github.com/user";
pub const emails_endpoint = "https://api.github.com/user/emails";

/// The path GitHub redirects back to. Appended to `DOOT_PUBLIC_ORIGIN`.
pub const callback_path = "/app/auth/github/callback";

/// A cap on any single response we will read from GitHub. `/user/emails` is the largest and is
/// a short list; anything beyond this is not a response we understand.
const max_response_bytes: usize = 64 * 1024;

pub const Error = error{
    /// GitHub declined the exchange, or answered something we cannot read.
    Exchange,
    /// The account has no verified email address, so there is no identity to anchor on.
    NoVerifiedEmail,
    OutOfMemory,
};

/// What the callback needs from GitHub to create or find an account.
pub const Identity = struct {
    /// The **numeric** user id, never the login: usernames can be changed and reused, so
    /// anchoring on one would let an identity be handed to somebody else (`06-auth.md`).
    user_id: u64,
    email_buf: [api.email.max_bytes]u8 = undefined,
    email_len: u16 = 0,

    pub fn email(i: *const Identity) []const u8 {
        return i.email_buf[0..i.email_len];
    }
};

/// Builds the URL the browser is redirected to.
///
/// Pure, so the whole query construction is testable without a network. `state` and the
/// redirect URI are percent-encoded because both end up in a query string — the redirect URI
/// unavoidably contains `:` and `/`.
pub fn authorizeUrl(
    client_id: []const u8,
    public_origin: []const u8,
    state: []const u8,
    out: []u8,
) ![]const u8 {
    var w: Writer = .{ .buf = out };
    try w.raw(authorize_endpoint);
    try w.raw("?client_id=");
    try w.encoded(client_id);
    try w.raw("&redirect_uri=");
    try w.encoded(public_origin);
    try w.encoded(callback_path);
    try w.raw("&scope=");
    try w.encoded(scope);
    try w.raw("&state=");
    try w.encoded(state);
    // `allow_signup=true` is GitHub's default and is left implicit rather than pinned: it is
    // their product decision, not ours, and hardcoding today's default would silently override
    // a future change to it.
    return w.done();
}

const Writer = struct {
    buf: []u8,
    n: usize = 0,

    fn raw(w: *Writer, s: []const u8) !void {
        if (w.n + s.len > w.buf.len) return error.NoSpaceLeft;
        @memcpy(w.buf[w.n..][0..s.len], s);
        w.n += s.len;
    }

    /// Percent-encodes everything outside RFC 3986's unreserved set.
    ///
    /// Deliberately strict rather than clever: encoding a character that did not need it is
    /// always safe, and deciding per-context which delimiters are safe is how an injection
    /// eventually happens.
    fn encoded(w: *Writer, s: []const u8) !void {
        const hex = "0123456789ABCDEF";
        for (s) |c| {
            const unreserved = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
                (c >= '0' and c <= '9') or c == '-' or c == '.' or c == '_' or c == '~';
            if (unreserved) {
                if (w.n + 1 > w.buf.len) return error.NoSpaceLeft;
                w.buf[w.n] = c;
                w.n += 1;
            } else {
                if (w.n + 3 > w.buf.len) return error.NoSpaceLeft;
                w.buf[w.n] = '%';
                w.buf[w.n + 1] = hex[c >> 4];
                w.buf[w.n + 2] = hex[c & 0x0F];
                w.n += 3;
            }
        }
    }

    fn done(w: *const Writer) []const u8 {
        return w.buf[0..w.n];
    }
};

/// Exchanges a code for an identity: token, then user, then verified email.
///
/// Runs on an I/O worker. Every failure collapses to `error.Exchange` unless it is the one
/// condition a *user* can act on — no verified email — because the difference between "GitHub
/// said no" and "GitHub said something we could not parse" is ours to read in a log and not
/// theirs to see in a response.
pub fn exchange(
    gpa: std.mem.Allocator,
    client_id: []const u8,
    client_secret: []const u8,
    public_origin: []const u8,
    code: []const u8,
) Error!Identity {
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var client: std.http.Client = .{ .allocator = gpa, .io = threaded.io() };
    defer client.deinit();

    const token = try fetchToken(gpa, &client, client_id, client_secret, public_origin, code);
    defer gpa.free(token);

    var identity: Identity = .{ .user_id = try fetchUserId(gpa, &client, token) };
    const address = try fetchVerifiedEmail(gpa, &client, token);
    defer gpa.free(address);
    if (address.len > api.email.max_bytes) return error.NoVerifiedEmail;
    @memcpy(identity.email_buf[0..address.len], address);
    identity.email_len = @intCast(address.len);
    return identity;
}

fn post(
    gpa: std.mem.Allocator,
    client: *std.http.Client,
    url: []const u8,
    payload: []const u8,
) Error![]u8 {
    var body: std.Io.Writer.Allocating = .init(gpa);
    errdefer body.deinit();

    const res = client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = payload,
        .response_writer = &body.writer,
        .extra_headers = &.{
            .{ .name = "accept", .value = "application/json" },
            .{ .name = "content-type", .value = "application/x-www-form-urlencoded" },
            .{ .name = "user-agent", .value = "doot" },
        },
    }) catch return error.Exchange;

    const status = @intFromEnum(res.status);
    if (status < 200 or status >= 300) return error.Exchange;
    if (body.written().len > max_response_bytes) return error.Exchange;
    return body.toOwnedSlice() catch error.OutOfMemory;
}

fn get(gpa: std.mem.Allocator, client: *std.http.Client, url: []const u8, token: []const u8) Error![]u8 {
    var auth_buf: [256]u8 = undefined;
    const auth = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{token}) catch
        return error.Exchange;

    var body: std.Io.Writer.Allocating = .init(gpa);
    errdefer body.deinit();

    const res = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &body.writer,
        .extra_headers = &.{
            .{ .name = "authorization", .value = auth },
            .{ .name = "accept", .value = "application/vnd.github+json" },
            .{ .name = "user-agent", .value = "doot" },
        },
    }) catch return error.Exchange;

    const status = @intFromEnum(res.status);
    if (status < 200 or status >= 300) return error.Exchange;
    if (body.written().len > max_response_bytes) return error.Exchange;
    return body.toOwnedSlice() catch error.OutOfMemory;
}

fn fetchToken(
    gpa: std.mem.Allocator,
    client: *std.http.Client,
    client_id: []const u8,
    client_secret: []const u8,
    public_origin: []const u8,
    code: []const u8,
) Error![]u8 {
    var payload_buf: [1024]u8 = undefined;
    var w: Writer = .{ .buf = &payload_buf };
    w.raw("client_id=") catch return error.Exchange;
    w.encoded(client_id) catch return error.Exchange;
    w.raw("&client_secret=") catch return error.Exchange;
    w.encoded(client_secret) catch return error.Exchange;
    w.raw("&code=") catch return error.Exchange;
    w.encoded(code) catch return error.Exchange;
    w.raw("&redirect_uri=") catch return error.Exchange;
    w.encoded(public_origin) catch return error.Exchange;
    w.encoded(callback_path) catch return error.Exchange;

    const body = try post(gpa, client, token_endpoint, w.done());
    defer gpa.free(body);

    const parsed = std.json.parseFromSlice(std.json.Value, gpa, body, .{}) catch
        return error.Exchange;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.Exchange,
    };
    // GitHub answers a rejected exchange with 200 and an `error` member, so the status alone
    // is not the check.
    if (obj.get("error") != null) return error.Exchange;
    const token = switch (obj.get("access_token") orelse return error.Exchange) {
        .string => |s| s,
        else => return error.Exchange,
    };
    if (token.len == 0 or token.len > 255) return error.Exchange;
    return gpa.dupe(u8, token) catch error.OutOfMemory;
}

fn fetchUserId(gpa: std.mem.Allocator, client: *std.http.Client, token: []const u8) Error!u64 {
    const body = try get(gpa, client, user_endpoint, token);
    defer gpa.free(body);

    const parsed = std.json.parseFromSlice(std.json.Value, gpa, body, .{}) catch
        return error.Exchange;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.Exchange,
    };
    return switch (obj.get("id") orelse return error.Exchange) {
        .integer => |v| if (v > 0) @intCast(v) else error.Exchange,
        else => error.Exchange,
    };
}

/// The primary verified address, or any verified one.
///
/// **An unverified address is never accepted as an identity match** (`06-auth.md`): it is an
/// address the holder has not proven they control, so anchoring a trial grant on one would let
/// anybody claim anybody's anchor.
fn fetchVerifiedEmail(gpa: std.mem.Allocator, client: *std.http.Client, token: []const u8) Error![]u8 {
    const body = try get(gpa, client, emails_endpoint, token);
    defer gpa.free(body);

    const parsed = std.json.parseFromSlice(std.json.Value, gpa, body, .{}) catch
        return error.Exchange;
    defer parsed.deinit();
    const list = switch (parsed.value) {
        .array => |a| a,
        else => return error.Exchange,
    };

    var fallback: ?[]const u8 = null;
    for (list.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const verified = switch (obj.get("verified") orelse continue) {
            .bool => |b| b,
            else => false,
        };
        if (!verified) continue;
        const address = switch (obj.get("email") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        api.email.check(address) catch continue;

        const primary = switch (obj.get("primary") orelse std.json.Value{ .bool = false }) {
            .bool => |b| b,
            else => false,
        };
        if (primary) return gpa.dupe(u8, address) catch error.OutOfMemory;
        if (fallback == null) fallback = address;
    }
    const chosen = fallback orelse return error.NoVerifiedEmail;
    return gpa.dupe(u8, chosen) catch error.OutOfMemory;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "the authorize URL carries every parameter GitHub needs" {
    var buf: [512]u8 = undefined;
    const url = try authorizeUrl("Iv1.abc123", "https://doot.run", "st4te", &buf);

    try testing.expect(std.mem.startsWith(u8, url, authorize_endpoint ++ "?"));
    try testing.expect(std.mem.indexOf(u8, url, "client_id=Iv1.abc123") != null);
    try testing.expect(std.mem.indexOf(u8, url, "state=st4te") != null);
    // The redirect URI is encoded, because it contains `:` and `/`.
    try testing.expect(std.mem.indexOf(
        u8,
        url,
        "redirect_uri=https%3A%2F%2Fdoot.run%2Fapp%2Fauth%2Fgithub%2Fcallback",
    ) != null);
    // The scope's space is encoded rather than sent raw.
    try testing.expect(std.mem.indexOf(u8, url, "scope=read%3Auser%20user%3Aemail") != null);
}

test "the scope asks for nothing more than identity" {
    // Repository access would cost signups and Doot never needs it (06-auth.md).
    try testing.expectEqualStrings("read:user user:email", scope);
    try testing.expect(std.mem.indexOf(u8, scope, "repo") == null);
    try testing.expect(std.mem.indexOf(u8, scope, "write") == null);
    try testing.expect(std.mem.indexOf(u8, scope, "admin") == null);
}

test "a state value cannot break out of the query string" {
    // The state is ours, but it reaches a URL, and a component that reaches a URL gets encoded
    // rather than trusted.
    var buf: [512]u8 = undefined;
    const url = try authorizeUrl("id", "https://doot.run", "a&b=c d", &buf);
    try testing.expect(std.mem.indexOf(u8, url, "state=a%26b%3Dc%20d") != null);
    // Exactly one `state=`, so nothing was smuggled in as a second parameter.
    var count: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, url, i, "state=")) |at| {
        count += 1;
        i = at + 1;
    }
    try testing.expectEqual(@as(usize, 1), count);
}

test "a buffer too small is an error rather than a truncated URL" {
    var tiny: [16]u8 = undefined;
    try testing.expectError(error.NoSpaceLeft, authorizeUrl("id", "https://doot.run", "st", &tiny));
}

test "the callback path is what the boot check validates the origin against" {
    // DOOT_PUBLIC_ORIGIN is required to have no path precisely so this concatenation is the
    // whole redirect URI, and matches what is registered with GitHub.
    try testing.expectEqualStrings("/app/auth/github/callback", callback_path);
    try testing.expect(std.mem.startsWith(u8, callback_path, "/"));
}

test "the endpoints are GitHub's, over https" {
    for ([_][]const u8{ authorize_endpoint, token_endpoint, user_endpoint, emails_endpoint }) |url| {
        try testing.expect(std.mem.startsWith(u8, url, "https://"));
        try testing.expect(std.mem.indexOf(u8, url, "github.com") != null);
    }
}
