//! Published account and key identifiers (D59).
//!
//! `<prefix>_` followed by the `u32` in uppercase Crockford base32, zero-padded to seven
//! characters: `acct_0000001`, `key_0000001`.
//!
//! Crockford because `api/ulid.zig` already uses it for server-assigned names, and because
//! it drops `I`, `L`, `O` and `U` — so an identifier read off a screen into a support
//! ticket arrives as the same identifier. Seven characters because that is what a `u32`
//! needs, so the width never changes and no identifier is ever a prefix of a longer one.
//! Padded because unpadded identifiers sort wrongly as text.

const std = @import("std");

/// Digits a `u32` needs in base32: 32 bits at 5 bits each.
pub const digits = 7;

/// The longest identifier: `acct` + `_` + seven digits.
pub const len = 4 + 1 + digits;

const alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

/// Renders `<prefix>_<id>` into `out`, returning the slice used.
pub fn render(comptime prefix: []const u8, id: u32, out: *[len]u8) []const u8 {
    comptime std.debug.assert(prefix.len + 1 + digits <= len);

    @memcpy(out[0..prefix.len], prefix);
    out[prefix.len] = '_';

    // Most significant digit first, so the text sorts the way the numbers do.
    var value = id;
    var i: usize = prefix.len + 1 + digits;
    while (i > prefix.len + 1) {
        i -= 1;
        out[i] = alphabet[@intCast(value & 0x1f)];
        value >>= 5;
    }
    return out[0 .. prefix.len + 1 + digits];
}

/// Reads `<prefix>_<id>` back into the `u32` it names.
///
/// The other half of `render`, needed the moment an identifier appears in a *path* rather
/// than only in a response body — `DELETE /app/keys/{id}`.
///
/// Null for anything that is not exactly one of ours: wrong prefix, wrong width, or a
/// character outside the alphabet. Strict on width as well as content, because a short
/// identifier is not a valid one and accepting `key_1` would mean two spellings of the same
/// key — the sorting problem the padding exists to avoid, reintroduced at the parser.
///
/// Deliberately **not** case-insensitive. Crockford's specification folds case on input, and
/// that is right for a human transcribing a code; this is a machine echoing back a value we
/// rendered, so accepting a second spelling would only widen what "the same identifier" means
/// for no benefit.
pub fn parse(comptime prefix: []const u8, text: []const u8) ?u32 {
    if (text.len != prefix.len + 1 + digits) return null;
    if (!std.mem.eql(u8, text[0..prefix.len], prefix)) return null;
    if (text[prefix.len] != '_') return null;

    var value: u32 = 0;
    for (text[prefix.len + 1 ..]) |ch| {
        const d = std.mem.indexOfScalar(u8, alphabet, ch) orelse return null;
        // Seven base-32 digits carry 35 bits and a u32 holds 32, so the top digit must not
        // overflow. Shifting blindly would silently wrap and name a different key.
        const shifted = @mulWithOverflow(value, 32);
        if (shifted[1] != 0) return null;
        const added = @addWithOverflow(shifted[0], @as(u32, @intCast(d)));
        if (added[1] != 0) return null;
        value = added[0];
    }
    return value;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "an identifier round-trips" {
    var buf: [len]u8 = undefined;
    for ([_]u32{ 0, 1, 31, 32, 1_000, 4_000_000_000, std.math.maxInt(u32) }) |id| {
        try testing.expectEqual(id, parse("key", render("key", id, &buf)).?);
        try testing.expectEqual(id, parse("acct", render("acct", id, &buf)).?);
    }
}

test "parsing refuses anything that is not exactly one of ours" {
    // Wrong prefix, including the other valid one.
    try testing.expect(parse("key", "acct_0000001") == null);
    try testing.expect(parse("acct", "key_0000001") == null);
    // Missing or wrong separator.
    try testing.expect(parse("key", "key-0000001") == null);
    // Wrong width: a short identifier is not a valid one, and accepting `key_1` would mean
    // two spellings of one key.
    try testing.expect(parse("key", "key_1") == null);
    try testing.expect(parse("key", "key_00000001") == null);
    try testing.expect(parse("key", "") == null);
    // Characters Crockford drops precisely because they are misread.
    try testing.expect(parse("key", "key_000000I") == null);
    try testing.expect(parse("key", "key_000000L") == null);
    try testing.expect(parse("key", "key_000000O") == null);
    try testing.expect(parse("key", "key_000000U") == null);
    // Lowercase is a different spelling of a value we rendered, so it is not accepted.
    try testing.expect(parse("key", "key_000000a") == null);
}

test "a value beyond a u32 is refused rather than wrapping" {
    // Seven base-32 digits carry 35 bits. Shifting blindly would wrap and name a different
    // key, which is the worst possible outcome for a revocation.
    try testing.expect(parse("key", "key_ZZZZZZZ") == null);
    var buf: [len]u8 = undefined;
    try testing.expectEqualStrings("key_3ZZZZZZ", render("key", std.math.maxInt(u32), &buf));
    try testing.expectEqual(std.math.maxInt(u32), parse("key", "key_3ZZZZZZ").?);
    try testing.expect(parse("key", "key_4000000") == null);
}

test "the shapes D59 settled" {
    var buf: [len]u8 = undefined;
    try testing.expectEqualStrings("acct_0000001", render("acct", 1, &buf));
    try testing.expectEqualStrings("key_0000001", render("key", 1, &buf));
    try testing.expectEqualStrings("acct_0000000", render("acct", 0, &buf));
}

test "every identifier is the same width, whatever the id" {
    var buf: [len]u8 = undefined;
    const small = render("acct", 1, &buf).len;
    var big_buf: [len]u8 = undefined;
    const big = render("acct", std.math.maxInt(u32), &big_buf).len;
    try testing.expectEqual(small, big);
    // A fixed width is what stops one identifier being a prefix of another.
    try testing.expectEqual(@as(usize, 4 + 1 + digits), small);
}

test "the full u32 range is representable" {
    var buf: [len]u8 = undefined;
    // 2^32 - 1 = 0xFFFFFFFF. Seven base32 digits hold 35 bits, so the top digit is 0b1111.
    try testing.expectEqualStrings("acct_3ZZZZZZ", render("acct", std.math.maxInt(u32), &buf));
    try testing.expectEqualStrings("acct_0000010", render("acct", 32, &buf));
    try testing.expectEqualStrings("acct_000000Z", render("acct", 31, &buf));
}

test "identifiers sort as text in the order their numbers do" {
    // The reason for padding. Unpadded, "acct_10" would sort before "acct_9".
    var previous: [len]u8 = undefined;
    var current: [len]u8 = undefined;
    _ = render("acct", 0, &previous);

    for ([_]u32{ 1, 9, 10, 31, 32, 1000, 100_000, std.math.maxInt(u32) }) |id| {
        _ = render("acct", id, &current);
        try testing.expect(std.mem.order(u8, &previous, &current) == .lt);
        previous = current;
    }
}

test "the alphabet is Crockford's, with the misreadable letters absent" {
    try testing.expectEqual(@as(usize, 32), alphabet.len);
    for ("ILOU") |bad| {
        try testing.expect(std.mem.indexOfScalar(u8, alphabet, bad) == null);
    }
    // And it agrees with the one the engine already uses for names.
    try testing.expectEqualStrings(api_alphabet, alphabet);
}

/// The alphabet `api/ulid.zig` encodes names with, restated here only so the test above
/// can fail if the two ever diverge.
const api_alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

test "a rendered identifier contains only alphabet characters and the separator" {
    var buf: [len]u8 = undefined;
    for ([_]u32{ 0, 1, 12345, std.math.maxInt(u32) }) |id| {
        const text = render("key", id, &buf);
        try testing.expect(std.mem.startsWith(u8, text, "key_"));
        for (text[4..]) |c| try testing.expect(std.mem.indexOfScalar(u8, alphabet, c) != null);
    }
}
