//! Server-assigned names (D5, D47).
//!
//! 26 characters of Crockford base32: a 48-bit millisecond timestamp followed by 80
//! bits of randomness. Chosen over UUIDv4 because the timestamp leads, so a caller
//! listing dumped webhooks gets chronological order from a plain lexicographic sort.
//!
//! **The non-monotonic form is used deliberately.** The monotonic variant of the
//! spec adds a per-millisecond counter so that two names created in the same
//! millisecond still sort in creation order. Nothing in Doot observes that ordering —
//! list-by-tag orders by write sequence, not by name — and a counter would put shared
//! mutable state on the write path to fix an ordering nobody can see.
//!
//! The encoder takes its timestamp and entropy as parameters and does no I/O, which
//! is what makes it exactly testable. `generate` is the thin wrapper that reaches for
//! the kernel.

const std = @import("std");
const storage = @import("storage");

const os = storage.os;

pub const len: usize = 26;
pub const Ulid = [len]u8;

/// Crockford base32: no `I`, `L`, `O` or `U`, so a transcribed name cannot be
/// confused with a digit or turn into a word.
const alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

const time_chars: usize = 10;
const entropy_chars: usize = 16;
pub const entropy_bytes: usize = 10;

comptime {
    std.debug.assert(alphabet.len == 32);
    std.debug.assert(time_chars + entropy_chars == len);
    std.debug.assert(entropy_bytes * 8 == entropy_chars * 5);
}

/// Encodes a timestamp and entropy into a name. Pure and total.
pub fn encode(ms: u48, entropy: [entropy_bytes]u8) Ulid {
    var out: Ulid = undefined;

    // Most significant character first, so lexicographic order matches time order.
    // Ten characters carry 50 bits and the timestamp is 48, leaving the top two bits
    // of the first character always zero.
    var t: u64 = ms;
    var i: usize = time_chars;
    while (i > 0) {
        i -= 1;
        out[i] = alphabet[@intCast(t & 0x1f)];
        t >>= 5;
    }

    // Sixteen characters carry exactly the 80 entropy bits, with nothing to spare.
    var v: u80 = std.mem.readInt(u80, &entropy, .big);
    var j: usize = len;
    while (j > time_chars) {
        j -= 1;
        out[j] = alphabet[@intCast(v & 0x1f)];
        v >>= 5;
    }

    return out;
}

/// Generates a name for `ms`, taking entropy from the kernel.
///
/// The timestamp is a parameter rather than read here: the engine's rule is that
/// nothing reaches for the system clock on its own (D33), and the request layer
/// already knows what time it is.
pub fn generate(ms: u48) os.Error!Ulid {
    var entropy: [entropy_bytes]u8 = undefined;
    try os.getRandom(&entropy);
    return encode(ms, entropy);
}

/// Recovers the timestamp from a name. Exists for tests and for the dashboard, which
/// can show when a server-assigned entry was created without a lookup.
pub fn timestampOf(name: []const u8) ?u48 {
    if (name.len != len) return null;
    var t: u64 = 0;
    for (name[0..time_chars]) |ch| {
        const v = std.mem.indexOfScalar(u8, alphabet, ch) orelse return null;
        t = (t << 5) | v;
    }
    if (t > std.math.maxInt(u48)) return null;
    return @intCast(t);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "a name is 26 characters, all from the alphabet" {
    const u = encode(1_700_000_000_000, @splat(0xAB));
    try testing.expectEqual(len, u.len);
    for (u) |ch| {
        try testing.expect(std.mem.indexOfScalar(u8, alphabet, ch) != null);
    }
}

test "the alphabet excludes the letters that get misread" {
    for ("ILOU") |ch| {
        try testing.expectEqual(@as(?usize, null), std.mem.indexOfScalar(u8, alphabet, ch));
    }
}

test "the timestamp round-trips" {
    const cases = [_]u48{ 0, 1, 1_700_000_000_000, std.math.maxInt(u48) };
    for (cases) |ms| {
        const u = encode(ms, @splat(0));
        try testing.expectEqual(ms, timestampOf(&u).?);
    }
}

test "encoding is deterministic in its inputs" {
    const a = encode(12345, @splat(0x5A));
    const b = encode(12345, @splat(0x5A));
    try testing.expectEqualSlices(u8, &a, &b);
}

test "lexicographic order is creation order" {
    // The property D5 wants: sorting names sorts by time, with no index involved.
    var previous = encode(0, @splat(0xFF));
    for ([_]u48{ 1, 999, 1_000, 1_699_999_999_999, 1_700_000_000_000 }) |ms| {
        // Worst case for ordering: the later name has minimal entropy and the earlier
        // one maximal, so only the timestamp can be carrying the order.
        const next = encode(ms, @splat(0x00));
        try testing.expect(std.mem.order(u8, &previous, &next) == .lt);
        previous = encode(ms, @splat(0xFF));
    }
}

test "entropy fills the trailing sixteen characters exactly" {
    const zero = encode(7, @splat(0x00));
    const ones = encode(7, @splat(0xFF));

    // Same timestamp, so the first ten characters match and the rest do not.
    try testing.expectEqualSlices(u8, zero[0..time_chars], ones[0..time_chars]);
    try testing.expectEqualStrings("0000000000000000", zero[time_chars..]);
    try testing.expectEqualStrings("ZZZZZZZZZZZZZZZZ", ones[time_chars..]);
}

test "a generated name is a valid entry name" {
    // A server-assigned name goes through the same validation as a caller's, so this
    // has to hold or POST /v1/entries could mint names its own GET would reject.
    const u = try generate(1_700_000_000_000);
    try storage.store.validateName(&u);
}

test "two generated names differ" {
    const a = try generate(1_700_000_000_000);
    const b = try generate(1_700_000_000_000);
    try testing.expect(!std.mem.eql(u8, &a, &b));
}

test "a malformed name has no timestamp" {
    try testing.expectEqual(@as(?u48, null), timestampOf("tooshort"));
    try testing.expectEqual(@as(?u48, null), timestampOf("0" ** 27));
    // 'I' is not in the alphabet.
    try testing.expectEqual(@as(?u48, null), timestampOf("I" ** 26));
}
