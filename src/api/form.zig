//! `application/x-www-form-urlencoded` request bodies, for the control plane.
//!
//! ## Why not JSON
//!
//! The dashboard is our own plain HTML and vanilla JavaScript (`05-architecture.md`), so the
//! request format is ours to pick and nothing external depends on it — `06-auth.md` says the
//! control plane is neither public API nor versioned.
//!
//! Form encoding is what an HTML form posts natively, and it parses in place with **no
//! allocator**. That matters more than it looks: the control plane's cheap validation runs on
//! the event loop, and `std.json` needs an allocator there. D57's rule is that the loop does
//! memory-only work, and "memory-only" is a weaker promise than "allocation-free" — a parser
//! that can take a heap lock on the loop is a parser that can stall every connection the loop
//! is serving.
//!
//! The data plane is unaffected: `/v1` bodies are **opaque bytes** and always were
//! (`02-api.md`). Nothing here touches them.
//!
//! Pure, per `api.zig`: no allocation, no clock, no I/O.

const std = @import("std");

pub const Error = error{
    /// A `%` not followed by two hex digits, which is a malformed body rather than a value we
    /// should guess at.
    BadEncoding,
    /// The decoded value did not fit the caller's buffer.
    TooLong,
};

/// Finds `name` and writes its decoded value into `out`, returning the slice used.
///
/// Null when the field is absent. **An empty value is `null` too**, deliberately: for every
/// field the control plane reads, "" and "missing" are the same mistake, and giving them
/// separate outcomes would mean every caller writing the same two-branch check.
///
/// The **last** occurrence wins, matching how HTML forms and every server-side parser behave
/// when a field repeats — and refusing a repeat instead would reject a browser doing something
/// legitimate.
pub fn field(body: []const u8, name: []const u8, out: []u8) Error!?[]const u8 {
    var found: ?[]const u8 = null;

    var it = std.mem.splitScalar(u8, body, '&');
    while (it.next()) |pair| {
        if (pair.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;

        // Names are encoded too — a `+` in a field name is a space — so the comparison has to
        // happen after decoding, not before.
        var name_buf: [64]u8 = undefined;
        const raw_name = pair[0..eq];
        if (raw_name.len > name_buf.len) continue;
        const decoded_name = decode(raw_name, &name_buf) catch continue;
        if (!std.mem.eql(u8, decoded_name, name)) continue;

        const value = try decode(pair[eq + 1 ..], out);
        found = if (value.len == 0) null else value;
    }
    return found;
}

/// Percent- and plus-decodes `raw` into `out`.
///
/// Separate from `parse.decodeName`, which shares the mechanism and not the rules: a name is
/// decoded from a *path*, where `+` is a literal plus and must stay one, while in a form body
/// `+` means space. Sharing one function would mean a flag, and a flag on a decoder is how a
/// name eventually gets a space in it.
pub fn decode(raw: []const u8, out: []u8) Error![]const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < raw.len) {
        if (n == out.len) return error.TooLong;
        const c = raw[i];
        if (c == '+') {
            out[n] = ' ';
            i += 1;
        } else if (c == '%') {
            if (i + 2 >= raw.len) return error.BadEncoding;
            const hi = hexDigit(raw[i + 1]) orelse return error.BadEncoding;
            const lo = hexDigit(raw[i + 2]) orelse return error.BadEncoding;
            out[n] = (hi << 4) | lo;
            i += 3;
        } else {
            out[n] = c;
            i += 1;
        }
        n += 1;
    }
    return out[0..n];
}

fn hexDigit(ch: u8) ?u8 {
    return switch (ch) {
        '0'...'9' => ch - '0',
        'a'...'f' => ch - 'a' + 10,
        'A'...'F' => ch - 'A' + 10,
        else => null,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectField(expected: ?[]const u8, body: []const u8, name: []const u8) !void {
    var buf: [256]u8 = undefined;
    const got = try field(body, name, &buf);
    if (expected) |e| {
        try testing.expectEqualStrings(e, got.?);
    } else {
        try testing.expect(got == null);
    }
}

test "a field is found among others" {
    const body = "email=a%40b.co&password=hunter2&remember=1";
    try expectField("a@b.co", body, "email");
    try expectField("hunter2", body, "password");
    try expectField("1", body, "remember");
    try expectField(null, body, "absent");
}

test "plus means space in a body, unlike in a path" {
    // parse.decodeName leaves `+` alone because a path's plus is a literal. Sharing one
    // decoder between the two would need a flag, and a flag is how a name gets a space.
    try expectField("hello world", "q=hello+world", "q");
    try expectField("a b c", "q=a+b+c", "q");
}

test "percent escapes decode, including ones that matter here" {
    try expectField("a@b.co", "email=a%40b.co", "email");
    try expectField("p&w=x", "password=p%26w%3Dx", "password");
    // A password may legitimately contain anything, including bytes that would otherwise
    // terminate the pair.
    try expectField("%&=+", "password=%25%26%3D%2B", "password");
    try expectField("üñ", "n=%C3%BC%C3%B1", "n");
}

test "a malformed escape is refused rather than guessed at" {
    var buf: [64]u8 = undefined;
    try testing.expectError(error.BadEncoding, field("password=ab%", "password", &buf));
    try testing.expectError(error.BadEncoding, field("password=ab%z1", "password", &buf));
    try testing.expectError(error.BadEncoding, field("password=ab%1", "password", &buf));
}

test "an empty value reads as absent" {
    // For every field the control plane reads, "" and "missing" are the same mistake.
    try expectField(null, "email=&password=x", "email");
    try expectField(null, "email=", "email");
}

test "the last occurrence wins" {
    // What HTML forms and every server-side parser do. Refusing a repeat would reject a
    // browser behaving legitimately.
    try expectField("second", "q=first&q=second", "q");
}

test "a name is compared after decoding" {
    try expectField("x", "my+field=x", "my field");
    try expectField("x", "my%20field=x", "my field");
}

test "a value too long for the buffer is an error, not a truncation" {
    var small: [4]u8 = undefined;
    try testing.expectError(error.TooLong, field("q=abcdefgh", "q", &small));
}

test "a pair with no equals sign is skipped rather than misread" {
    try expectField("x", "junk&q=x", "q");
    try expectField(null, "justaname", "justaname");
}

test "an empty body has no fields" {
    try expectField(null, "", "q");
    try expectField(null, "&&", "q");
}

test "a name that merely contains ours does not match" {
    try expectField(null, "email_confirm=x", "email");
    try expectField("y", "email_confirm=x&email=y", "email");
}

test "a field whose name is longer than the scratch is skipped, not a crash" {
    // 64 bytes of name is far past anything the control plane asks for, and a body can
    // contain whatever it likes.
    const long = "n" ** 200;
    var buf: [64]u8 = undefined;
    const body = long ++ "=v&q=x";
    try testing.expectEqualStrings("x", (try field(body, "q", &buf)).?);
}
