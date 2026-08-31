//! Pagination cursors: opaque, signed, account-bound, one-hour lifetime (D46).
//!
//! `tagchain.Cursor` is 40 bytes of internal traversal state — four class frontiers
//! and a sequence bound. Handing that to a caller raw would let anyone walk another
//! account's chains by editing a number, so it is wrapped, bound to the issuing
//! account, and signed.
//!
//! ```
//! offset  size  field
//!   0       1   format version (1)
//!   1       4   account_id
//!   5       4   issued_at              unix seconds
//!   9      40   cursor state           4 x u64 class frontier, then u64 seq bound
//!  49      16   HMAC-SHA256 truncated  over bytes 0..48
//! ```
//!
//! 65 bytes, base64url without padding, 87 characters. Truncating the tag to 16 bytes
//! leaves forgery at 2^128, which is not the weak link in anything here.
//!
//! Unlike the index hash key (D43), the signing secret is genuinely rotatable:
//! rotation invalidates outstanding cursors, and a client's documented response to
//! `invalid_cursor` is to restart pagination.

const std = @import("std");
const storage = @import("storage");

const tagchain = storage.tagchain;
const config = storage.config;

const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const base64 = std.base64.url_safe_no_pad;

pub const version: u8 = 1;

const state_offset: usize = 9;
const state_bytes: usize = 40;
const tag_offset: usize = 49;
pub const tag_bytes: usize = 16;

pub const raw_bytes: usize = tag_offset + tag_bytes;
pub const encoded_bytes: usize = base64.Encoder.calcSize(raw_bytes);

/// One hour, as `02-api.md` publishes.
pub const max_age_s: u32 = 60 * 60;

pub const Error = error{InvalidCursor};

comptime {
    std.debug.assert(raw_bytes == 65);
    std.debug.assert(encoded_bytes == 87);
    // Four class frontiers plus the sequence bound.
    std.debug.assert(state_bytes == (config.class_count + 1) * 8);
}

/// Writes the signed, encoded cursor. Never fails: every length is fixed.
pub fn encode(
    secret: [32]u8,
    account_id: u32,
    issued_at: u32,
    c: tagchain.Cursor,
    out: *[encoded_bytes]u8,
) void {
    var raw: [raw_bytes]u8 = undefined;
    raw[0] = version;
    std.mem.writeInt(u32, raw[1..5], account_id, .little);
    std.mem.writeInt(u32, raw[5..9], issued_at, .little);

    var p: usize = state_offset;
    for (c.next) |frontier| {
        std.mem.writeInt(u64, raw[p..][0..8], frontier, .little);
        p += 8;
    }
    std.mem.writeInt(u64, raw[p..][0..8], c.last_seq, .little);

    var full: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&full, raw[0..tag_offset], &secret);
    @memcpy(raw[tag_offset..], full[0..tag_bytes]);

    _ = base64.Encoder.encode(out, &raw);
}

/// Verifies and unwraps a cursor.
///
/// Checks run in this order, and every failure returns the same error so nothing here
/// is an oracle:
///
/// 1. decodes as base64url to exactly 65 bytes
/// 2. version is 1
/// 3. the tag verifies, under a constant-time comparison
/// 4. `account_id` matches the authenticated account
/// 5. `issued_at` is within the last hour
///
/// The tag is checked **before** the account on purpose: an attacker learns nothing
/// about which accounts exist, and step 4 then becomes a check on data already proven
/// to be ours rather than on attacker-supplied bytes.
pub fn decode(
    secret: [32]u8,
    account_id: u32,
    now: u32,
    text: []const u8,
) Error!tagchain.Cursor {
    if (text.len != encoded_bytes) return error.InvalidCursor;

    var raw: [raw_bytes]u8 = undefined;
    base64.Decoder.decode(&raw, text) catch return error.InvalidCursor;

    if (raw[0] != version) return error.InvalidCursor;

    var expected: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&expected, raw[0..tag_offset], &secret);
    var presented: [tag_bytes]u8 = undefined;
    @memcpy(&presented, raw[tag_offset..]);
    var truncated: [tag_bytes]u8 = undefined;
    @memcpy(&truncated, expected[0..tag_bytes]);
    if (!std.crypto.timing_safe.eql([tag_bytes]u8, presented, truncated)) {
        return error.InvalidCursor;
    }

    if (std.mem.readInt(u32, raw[1..5], .little) != account_id) return error.InvalidCursor;

    const issued_at = std.mem.readInt(u32, raw[5..9], .little);
    // A cursor from the future cannot have been issued by this box, so it is a
    // tampered or replayed value rather than clock skew — there is only one clock.
    if (issued_at > now) return error.InvalidCursor;
    if (now - issued_at > max_age_s) return error.InvalidCursor;

    var c: tagchain.Cursor = .{ .next = @splat(0), .last_seq = 0 };
    var p: usize = state_offset;
    for (&c.next) |*frontier| {
        frontier.* = std.mem.readInt(u64, raw[p..][0..8], .little);
        p += 8;
    }
    c.last_seq = std.mem.readInt(u64, raw[p..][0..8], .little);
    return c;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const test_secret: [32]u8 = @splat(0x5A);
const wrong_secret: [32]u8 = @splat(0xA5);
const now0: u32 = 1_700_000_000;

fn sample() tagchain.Cursor {
    return .{ .next = .{ 1, 2, 3, 4 }, .last_seq = 999 };
}

test "a cursor round-trips" {
    var text: [encoded_bytes]u8 = undefined;
    encode(test_secret, 42, now0, sample(), &text);

    const back = try decode(test_secret, 42, now0, &text);
    try testing.expectEqual(@as(u64, 1), back.next[0]);
    try testing.expectEqual(@as(u64, 4), back.next[3]);
    try testing.expectEqual(@as(u64, 999), back.last_seq);
}

test "a start cursor round-trips, including its sentinel sequence bound" {
    const start: tagchain.Cursor = .{};
    try testing.expect(start.isStart());

    var text: [encoded_bytes]u8 = undefined;
    encode(test_secret, 1, now0, start, &text);
    const back = try decode(test_secret, 1, now0, &text);

    try testing.expectEqual(start.last_seq, back.last_seq);
    try testing.expect(back.isStart());
}

test "the encoded form is 87 base64url characters" {
    var text: [encoded_bytes]u8 = undefined;
    encode(test_secret, 1, now0, sample(), &text);
    try testing.expectEqual(@as(usize, 87), text.len);

    // Opaque and URL-safe: no padding, and nothing needing escaping in a query
    // string or a JSON body.
    for (text) |ch| {
        const ok = (ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z') or
            (ch >= '0' and ch <= '9') or ch == '-' or ch == '_';
        try testing.expect(ok);
    }
}

test "a cursor issued to another account is refused" {
    // The isolation D46 exists for: editing the account out of a cursor must not
    // reach another account's chains.
    var text: [encoded_bytes]u8 = undefined;
    encode(test_secret, 42, now0, sample(), &text);
    try testing.expectError(error.InvalidCursor, decode(test_secret, 43, now0, &text));
}

test "a forged or re-signed cursor is refused" {
    var text: [encoded_bytes]u8 = undefined;
    encode(wrong_secret, 42, now0, sample(), &text);
    try testing.expectError(error.InvalidCursor, decode(test_secret, 42, now0, &text));
}

test "every single-bit flip is refused" {
    var text: [encoded_bytes]u8 = undefined;
    encode(test_secret, 42, now0, sample(), &text);

    for (0..encoded_bytes) |i| {
        for (0..8) |bit| {
            var flipped = text;
            flipped[i] ^= (@as(u8, 1) << @intCast(bit));
            if (std.mem.eql(u8, &flipped, &text)) continue;
            try testing.expectError(error.InvalidCursor, decode(test_secret, 42, now0, &flipped));
        }
    }
}

test "a cursor expires after an hour" {
    var text: [encoded_bytes]u8 = undefined;
    encode(test_secret, 42, now0, sample(), &text);

    _ = try decode(test_secret, 42, now0, &text);
    _ = try decode(test_secret, 42, now0 + max_age_s, &text);
    try testing.expectError(error.InvalidCursor, decode(test_secret, 42, now0 + max_age_s + 1, &text));
}

test "a cursor from the future is refused" {
    // One box, one clock, so this is tampering rather than skew.
    var text: [encoded_bytes]u8 = undefined;
    encode(test_secret, 42, now0, sample(), &text);
    try testing.expectError(error.InvalidCursor, decode(test_secret, 42, now0 - 1, &text));
}

test "a wrong version is refused rather than reinterpreted" {
    var raw: [raw_bytes]u8 = undefined;
    raw[0] = 2;
    std.mem.writeInt(u32, raw[1..5], 42, .little);
    std.mem.writeInt(u32, raw[5..9], now0, .little);
    @memset(raw[state_offset..tag_offset], 0);

    var full: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&full, raw[0..tag_offset], &test_secret);
    @memcpy(raw[tag_offset..], full[0..tag_bytes]);

    var text: [encoded_bytes]u8 = undefined;
    _ = base64.Encoder.encode(&text, &raw);

    // Correctly signed, and still refused: a future layout must not be guessed at.
    try testing.expectError(error.InvalidCursor, decode(test_secret, 42, now0, &text));
}

test "anything that is not a cursor is refused" {
    for ([_][]const u8{
        "",
        "x",
        "not-a-cursor",
        "!" ** encoded_bytes,
        "A" ** (encoded_bytes - 1),
        "A" ** (encoded_bytes + 1),
    }) |bad| {
        try testing.expectError(error.InvalidCursor, decode(test_secret, 42, now0, bad));
    }
}

test "a cursor survives the traversal state the engine actually produces" {
    // Frontiers are packed locations, so exercise the extremes rather than small
    // integers that would hide a truncation.
    const c: tagchain.Cursor = .{
        .next = .{ 0, std.math.maxInt(u64), 1 << 63, 0xDEAD_BEEF_CAFE_F00D },
        .last_seq = std.math.maxInt(u64) - 1,
    };
    var text: [encoded_bytes]u8 = undefined;
    encode(test_secret, 7, now0, c, &text);
    const back = try decode(test_secret, 7, now0, &text);

    try testing.expectEqualSlices(u64, &c.next, &back.next);
    try testing.expectEqual(c.last_seq, back.last_seq);
}
