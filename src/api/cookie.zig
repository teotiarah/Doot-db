//! Cookies for the control plane (`06-auth.md`).
//!
//! Two of them, and only the control plane ever sees either: `/v1` authenticates with a
//! bearer token and never reads a cookie, which is what removes CSRF from the data plane
//! entirely (D73). A browser does not attach an `Authorization` header on its own, and
//! that asymmetry is the whole defence.
//!
//! ## Why `__Host-`
//!
//! The prefix is enforced by the browser, not by us: a cookie named `__Host-…` is only
//! accepted if it is `Secure`, has `Path=/`, and carries **no `Domain` attribute** — which
//! means no subdomain can set it. Without it, anything able to write a cookie on a sibling
//! subdomain could fixate a session on `doot.run`. The constraint costs nothing here
//! because the control plane is served from one origin.
//!
//! `SameSite=Lax` rather than `Strict` because the GitHub OAuth callback is a top-level
//! cross-site navigation back to us, and `Strict` would withhold the pre-session cookie
//! exactly when the `state` check needs it. `Lax` sends cookies on top-level `GET`
//! navigations and withholds them on cross-site `POST`, which is the shape that keeps the
//! callback working while leaving the synchroniser token to cover state-changing routes.
//!
//! Pure, per `api.zig`: no allocation, no clock, no I/O. Serialisation writes into a
//! caller-supplied buffer.

const std = @import("std");

/// The session cookie. `__Host-` prefixed, so the browser refuses it unless it is
/// `Secure`, `Path=/` and domain-less.
pub const session_name = "__Host-doot_session";

/// The OAuth pre-session cookie, holding the `state` binding (`06-auth.md`).
///
/// A separate cookie rather than a field in the session cookie, because it exists
/// *before* there is a session and must be consumable exactly once. Short-lived by
/// `Max-Age` as well as by the server-side entry it names, so a browser that never
/// completes the flow forgets it without our help.
pub const oauth_name = "__Host-doot_oauth";

/// Longest `Set-Cookie` any function here produces, so a caller can size a buffer without
/// guessing. Derived rather than rounded: the longest is the session cookie at its full
/// value plus every attribute.
pub const max_set_cookie_bytes: usize = 256;

pub const Error = error{BufferTooSmall};

/// Extracts one cookie's value from a `Cookie` request header.
///
/// The header is a `;`-separated list of `name=value` pairs. Whitespace after a separator
/// is optional in practice and ubiquitous in reality, so it is trimmed. A name is matched
/// **case-sensitively**, because cookie names are case-sensitive and `__host-` is not the
/// prefix the browser enforces.
///
/// Returns null rather than an error for anything malformed: a missing or unreadable
/// cookie and a wrong one are the same answer to the caller — no session — and giving them
/// separate outcomes would only invite a handler to distinguish them.
pub fn get(header: ?[]const u8, name: []const u8) ?[]const u8 {
    const all = header orelse return null;

    var it = std.mem.splitScalar(u8, all, ';');
    while (it.next()) |raw| {
        const pair = std.mem.trim(u8, raw, " \t");
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;

        // Both sides are trimmed. RFC 6265 puts no space around the `=` and no browser
        // emits one, so this is tolerance rather than necessity — but it is free, and it
        // costs nothing in safety: the value is still checked against a stored digest, so
        // a laxer parse cannot admit a credential a stricter one would have rejected.
        if (!std.mem.eql(u8, std.mem.trim(u8, pair[0..eq], " \t"), name)) continue;

        const value = std.mem.trim(u8, pair[eq + 1 ..], " \t");
        if (value.len == 0) return null;
        // A quoted cookie value is legal under RFC 6265 and nothing we issue is quoted,
        // so a quoted one is not ours. Refusing it is safer than unwrapping it: unwrapping
        // would make `"abc"` and `abc` the same credential.
        if (value[0] == '"') return null;
        return value;
    }
    return null;
}

/// Is every byte legal in a cookie value?
///
/// RFC 6265's `cookie-octet`, minus the characters that would need quoting. Everything we
/// issue is base64url or base62 and passes trivially; the check exists because a value
/// that reached a `Set-Cookie` header with a `;` or a control byte in it would be header
/// injection, and the response writer's own refusal (D64) would turn it into a `500`
/// rather than a caught mistake.
pub fn valueIsSafe(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |c| {
        const ok = (c >= 0x21 and c <= 0x7E) and
            c != '"' and c != ',' and c != ';' and c != '\\';
        if (!ok) return false;
    }
    return true;
}

/// Writes a `Set-Cookie` value (without the header name) into `out`.
///
/// `max_age_s` of null omits the attribute, making it a session cookie the browser drops
/// when it closes; that is what the OAuth pre-session wants if its own lifetime is shorter
/// than any sensible `Max-Age`.
pub fn set(out: []u8, name: []const u8, value: []const u8, max_age_s: ?u32) Error![]const u8 {
    std.debug.assert(valueIsSafe(value));

    var w: Writer = .{ .buf = out };
    try w.str(name);
    try w.str("=");
    try w.str(value);
    // Path=/ and Secure are not stylistic: the browser rejects a `__Host-` cookie without
    // both, and no `Domain` may appear for the same reason.
    try w.str("; Path=/; HttpOnly; Secure; SameSite=Lax");
    if (max_age_s) |age| {
        try w.str("; Max-Age=");
        try w.int(age);
    }
    return w.written();
}

/// Writes a `Set-Cookie` that deletes the cookie.
///
/// `Max-Age=0` with an empty value, and **the same attributes as when it was set** — a
/// browser matches a deletion on name, path and security attributes, so a deletion that
/// omits them silently leaves the cookie in place. That is the classic logout bug, and it
/// is why this is a function rather than a string literal at each call site.
pub fn clear(out: []u8, name: []const u8) Error![]const u8 {
    var w: Writer = .{ .buf = out };
    try w.str(name);
    try w.str("=; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=0");
    return w.written();
}

/// A bounded writer, so nothing here can allocate or overrun.
const Writer = struct {
    buf: []u8,
    n: usize = 0,

    fn str(w: *Writer, s: []const u8) Error!void {
        if (w.n + s.len > w.buf.len) return error.BufferTooSmall;
        @memcpy(w.buf[w.n..][0..s.len], s);
        w.n += s.len;
    }

    fn int(w: *Writer, v: u32) Error!void {
        var tmp: [10]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, "{d}", .{v}) catch unreachable;
        try w.str(s);
    }

    fn written(w: *const Writer) []const u8 {
        return w.buf[0..w.n];
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "a cookie is found among others, with or without spaces" {
    try testing.expectEqualStrings("abc", get("__Host-doot_session=abc", session_name).?);
    try testing.expectEqualStrings(
        "abc",
        get("other=1; __Host-doot_session=abc; third=3", session_name).?,
    );
    // No space after the separator is legal too.
    try testing.expectEqualStrings(
        "abc",
        get("other=1;__Host-doot_session=abc", session_name).?,
    );
    // Leading and trailing whitespace around the value.
    try testing.expectEqualStrings("abc", get("__Host-doot_session =  abc  ", session_name).?);
}

test "an absent, empty or differently-named cookie is no cookie" {
    try testing.expect(get(null, session_name) == null);
    try testing.expect(get("", session_name) == null);
    try testing.expect(get("other=1", session_name) == null);
    try testing.expect(get("__Host-doot_session=", session_name) == null);
    try testing.expect(get("__Host-doot_session", session_name) == null);
}

test "the cookie name is matched case-sensitively" {
    // Cookie names are case-sensitive, and `__host-` is not the prefix a browser enforces
    // — so accepting it would accept a cookie the browser never protected.
    try testing.expect(get("__host-doot_session=abc", session_name) == null);
    try testing.expect(get("__HOST-DOOT_SESSION=abc", session_name) == null);
}

test "a name that merely contains ours does not match" {
    try testing.expect(get("x__Host-doot_session=abc", session_name) == null);
    try testing.expect(get("__Host-doot_session_extra=abc", session_name) == null);
}

test "a quoted value is refused rather than unwrapped" {
    // Unwrapping would make `\"abc\"` and `abc` the same credential. Nothing we issue is
    // quoted, so a quoted one is not ours.
    try testing.expect(get("__Host-doot_session=\"abc\"", session_name) == null);
}

test "the two cookies do not collide" {
    const header = "__Host-doot_session=sess; __Host-doot_oauth=state";
    try testing.expectEqualStrings("sess", get(header, session_name).?);
    try testing.expectEqualStrings("state", get(header, oauth_name).?);
}

test "a value with an equals sign in it survives" {
    // base64url is unpadded so we never issue one, but splitting on the *first* equals is
    // what makes this true, and a future padded value should not silently truncate.
    try testing.expectEqualStrings("ab=cd", get("__Host-doot_session=ab=cd", session_name).?);
}

test "Set-Cookie carries every attribute __Host- requires" {
    var buf: [max_set_cookie_bytes]u8 = undefined;
    const s = try set(&buf, session_name, "tok", 2_592_000);

    try testing.expectEqualStrings(
        "__Host-doot_session=tok; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=2592000",
        s,
    );
    // The browser rejects a `__Host-` cookie without these, so their absence would be a
    // silently broken login rather than a style problem.
    try testing.expect(std.mem.indexOf(u8, s, "; Secure") != null);
    try testing.expect(std.mem.indexOf(u8, s, "; Path=/") != null);
    try testing.expect(std.mem.indexOf(u8, s, "; HttpOnly") != null);
    // And no Domain, which the prefix also forbids.
    try testing.expect(std.mem.indexOf(u8, s, "Domain") == null);
}

test "Max-Age is omitted when there is none" {
    var buf: [max_set_cookie_bytes]u8 = undefined;
    const s = try set(&buf, oauth_name, "st", null);
    try testing.expectEqualStrings(
        "__Host-doot_oauth=st; Path=/; HttpOnly; Secure; SameSite=Lax",
        s,
    );
}

test "clearing repeats the attributes, because a browser matches on them" {
    var buf: [max_set_cookie_bytes]u8 = undefined;
    const s = try clear(&buf, session_name);
    try testing.expectEqualStrings(
        "__Host-doot_session=; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=0",
        s,
    );
    // The classic logout bug is a deletion whose attributes do not match the cookie it
    // means to remove, which leaves it in place.
    try testing.expect(std.mem.indexOf(u8, s, "Max-Age=0") != null);
    try testing.expect(std.mem.indexOf(u8, s, "; Path=/") != null);
    try testing.expect(std.mem.indexOf(u8, s, "; Secure") != null);
}

test "a round trip: what we set is what get reads back" {
    var buf: [max_set_cookie_bytes]u8 = undefined;
    const s = try set(&buf, session_name, "V4lu3-with_chars", 60);
    // Take the pair up to the first attribute and read it as a request header.
    const semi = std.mem.indexOfScalar(u8, s, ';').?;
    try testing.expectEqualStrings("V4lu3-with_chars", get(s[0..semi], session_name).?);
}

test "an unsafe value is refused by the guard rather than reaching a header" {
    // A `;` or a control byte here would be header injection, and the response writer's
    // own refusal would surface it as a 500 rather than as a caught mistake (D64).
    try testing.expect(!valueIsSafe(""));
    try testing.expect(!valueIsSafe("a;b"));
    try testing.expect(!valueIsSafe("a b"));
    try testing.expect(!valueIsSafe("a\x00b"));
    try testing.expect(!valueIsSafe("a\rb"));
    try testing.expect(!valueIsSafe("a\nb"));
    try testing.expect(!valueIsSafe("a\"b"));
    try testing.expect(!valueIsSafe("a,b"));
    try testing.expect(!valueIsSafe("a\\b"));

    // Everything we actually issue passes.
    try testing.expect(valueIsSafe("abcXYZ012"));
    try testing.expect(valueIsSafe("aBc-_9"));
}

test "the stated buffer ceiling holds for the longest cookie we issue" {
    const secret = @import("secret.zig");
    var buf: [max_set_cookie_bytes]u8 = undefined;

    const token: [secret.session_token_len]u8 = @splat('A');
    const s = try set(&buf, session_name, &token, 30 * 24 * 60 * 60);
    try testing.expect(s.len <= max_set_cookie_bytes);
    // Headroom, so a future attribute does not silently overflow a caller's buffer.
    try testing.expect(max_set_cookie_bytes >= s.len + 64);
}

test "a buffer too small is an error, not a truncated cookie" {
    var tiny: [8]u8 = undefined;
    try testing.expectError(error.BufferTooSmall, set(&tiny, session_name, "tok", 60));
    try testing.expectError(error.BufferTooSmall, clear(&tiny, session_name));
}
