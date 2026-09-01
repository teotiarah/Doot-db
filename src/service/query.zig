//! Query-string parameter lookup.
//!
//! Pure, and deliberately minimal: `02-api.md` defines exactly three parameters, all on
//! one endpoint — `tag`, `limit` and `cursor` on the list. There is no form decoding, no
//! repeated-key semantics and no nested structure, because none of those appear anywhere
//! in the API and each is a thing to get wrong.
//!
//! Percent-decoding is not done here. `tag` and `cursor` are drawn from character sets
//! that have no encodable characters in them — lowercase alphanumerics with `.`, `_`, `-`
//! and `:` for a tag (`03-data-model.md`), base64url for a cursor (D46) — so a `%` in
//! either is a malformed value rather than an escape, and it is rejected by the
//! validation that follows rather than silently decoded into something legal.

const std = @import("std");

/// The first value for `name`, or null when absent.
///
/// First rather than last: a repeated parameter is a client bug either way, and taking
/// the first makes the result independent of how many times it was repeated.
pub fn get(query: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        if (pair.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse {
            // A bare key. Present, with an empty value — `?tag` and `?tag=` mean the
            // same thing to a caller, so they mean the same thing here.
            if (std.mem.eql(u8, pair, name)) return "";
            continue;
        };
        if (std.mem.eql(u8, pair[0..eq], name)) return pair[eq + 1 ..];
    }
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "a single parameter" {
    try testing.expectEqualStrings("ci", get("tag=ci", "tag").?);
    try testing.expect(get("tag=ci", "limit") == null);
}

test "the parameters the list endpoint actually takes" {
    const q = "tag=ci&limit=10&cursor=abc123";
    try testing.expectEqualStrings("ci", get(q, "tag").?);
    try testing.expectEqualStrings("10", get(q, "limit").?);
    try testing.expectEqualStrings("abc123", get(q, "cursor").?);
}

test "an empty query has nothing in it" {
    try testing.expect(get("", "tag") == null);
    try testing.expect(get("&", "tag") == null);
    try testing.expect(get("&&", "tag") == null);
}

test "a present but empty value is present" {
    // `missing_tag` is for a *absent* tag; an empty one is `invalid_tag`, and the two
    // have to be distinguishable here for that to be possible upstream.
    try testing.expectEqualStrings("", get("tag=", "tag").?);
    try testing.expectEqualStrings("", get("tag", "tag").?);
    try testing.expectEqualStrings("", get("limit=5&tag=", "tag").?);
}

test "a name is matched whole, not as a prefix or a suffix" {
    try testing.expect(get("tagx=ci", "tag") == null);
    try testing.expect(get("xtag=ci", "tag") == null);
    try testing.expect(get("mytag=ci", "tag") == null);
    // ...including when a decoy comes first.
    try testing.expectEqualStrings("real", get("tagx=decoy&tag=real", "tag").?);
}

test "a repeated parameter takes the first value" {
    try testing.expectEqualStrings("first", get("tag=first&tag=second", "tag").?);
}

test "a value containing an equals sign keeps it" {
    // Base64url does not produce `=` with padding stripped (D46), but a malformed cursor
    // may well contain one, and it must reach validation intact to be rejected.
    try testing.expectEqualStrings("a=b=c", get("cursor=a=b=c", "cursor").?);
}

test "order does not matter" {
    try testing.expectEqualStrings("ci", get("limit=10&cursor=x&tag=ci", "tag").?);
    try testing.expectEqualStrings("10", get("tag=ci&limit=10", "limit").?);
}
