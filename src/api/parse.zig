//! Request parsing, specified rather than improvised (D47).
//!
//! Four wire-format questions had no answer in the published spec until D47, and each
//! is the kind of gap every implementer fills differently before it becomes a
//! compatibility obligation. The grammars here are the settled ones; the reasoning is
//! in `docs/02-api.md` and `docs/07-decisions.md` D47.
//!
//! Everything in this file is a pure function over caller-supplied bytes. No
//! allocation, no clock, no I/O — which is what makes the whole surface testable
//! without a server.

const std = @import("std");
const storage = @import("storage");

const config = storage.config;

pub const Error = error{
    InvalidTtl,
    InvalidTag,
    TooManyTags,
    InvalidName,
    InvalidLimit,
};

// ---------------------------------------------------------------------------
// Content-Type
// ---------------------------------------------------------------------------

/// Whether every byte is printable US-ASCII, `0x20`–`0x7E`.
///
/// Used on `Content-Type`, which `03-data-model.md` stores verbatim and echoes into a
/// response header on read. That pair of promises is only keepable if the value is
/// something a header can carry: `response.headerSafe` refuses `CR`, `LF` and `NUL`,
/// so without this check a write succeeds, charges a credit, and produces an entry
/// whose every subsequent read is a `500` (D64).
///
/// Deliberately stricter than the three bytes the response writer rejects. A media
/// type is `token "/" token` under RFC 9110 and cannot legitimately hold a control
/// byte, a `DEL`, or anything above `0x7F` — and a rule stated in terms of what the
/// field *is* does not quietly reopen when the writer's prohibitions change.
///
/// An empty slice is printable by this definition. Absent and empty content types are
/// the caller's business, not this predicate's.
pub fn printableAscii(text: []const u8) bool {
    for (text) |c| {
        if (c < 0x20 or c > 0x7E) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// X-Doot-TTL
// ---------------------------------------------------------------------------

/// The largest number of digits that could ever be meaningful. Ten digits covers
/// every `u32`, so anything longer is a typo or an attack and is refused before
/// arithmetic happens.
const max_ttl_digits: usize = 10;

/// Parses a lifetime into seconds.
///
/// One or more ASCII digits, optionally followed by exactly one lowercase suffix from
/// `s`, `m`, `h`, `d`. Nothing else: no compound forms (`1h30m`), no fractions
/// (`1.5h`), no sign, no whitespace, no uppercase.
///
/// Compound forms are refused because they are the start of a duration language, and
/// each extension invites the next — `1h30m` invites `1h 30m`, then `90 minutes`.
///
/// **Range is not checked here.** `0` parses successfully and is then rejected as
/// `ttl_too_short` by the caller, which keeps "I typed it wrong" (`invalid_ttl`)
/// distinct from "my plan will not allow it" (`ttl_too_short` / `ttl_too_long`).
pub fn ttl(text: []const u8) Error!u32 {
    if (text.len == 0) return error.InvalidTtl;

    const suffix: ?u64 = switch (text[text.len - 1]) {
        's' => 1,
        'm' => 60,
        'h' => 60 * 60,
        'd' => 24 * 60 * 60,
        else => null,
    };
    const multiplier = suffix orelse 1;
    const digits = if (suffix != null) text[0 .. text.len - 1] else text;

    // A bare suffix has no digits, and eleven digits cannot describe a `u32`.
    if (digits.len == 0 or digits.len > max_ttl_digits) return error.InvalidTtl;

    var value: u64 = 0;
    for (digits) |ch| {
        if (ch < '0' or ch > '9') return error.InvalidTtl;
        value = value * 10 + (ch - '0');
    }

    // Overflow is a parse failure, never a wraparound: a lifetime that silently
    // became small would expire someone's data early.
    const total = std.math.mul(u64, value, multiplier) catch return error.InvalidTtl;
    if (total > std.math.maxInt(u32)) return error.InvalidTtl;
    return @intCast(total);
}

// ---------------------------------------------------------------------------
// X-Doot-Tags
// ---------------------------------------------------------------------------

/// Normalised tags, owned inline so parsing needs no allocator.
pub const TagSet = struct {
    bytes: [config.max_tags][config.max_tag_bytes]u8 = undefined,
    lens: [config.max_tags]u8 = @splat(0),
    count: u8 = 0,

    pub fn get(self: *const TagSet, i: usize) []const u8 {
        return self.bytes[i][0..self.lens[i]];
    }

    /// Fills `out` with slices into this set and returns the used prefix, which is
    /// the shape `Store.put` takes. The slices borrow `self`.
    pub fn slices(self: *const TagSet, out: *[config.max_tags][]const u8) []const []const u8 {
        var i: usize = 0;
        while (i < self.count) : (i += 1) out[i] = self.get(i);
        return out[0..self.count];
    }

    fn contains(self: *const TagSet, tag: []const u8) bool {
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            if (std.mem.eql(u8, self.get(i), tag)) return true;
        }
        return false;
    }
};

fn isTagByte(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or (ch >= '0' and ch <= '9') or
        ch == '.' or ch == '_' or ch == '-' or ch == ':';
}

/// Parses the `X-Doot-Tags` header.
///
/// In order: split on `,`; trim spaces and tabs; drop empty elements; lowercase;
/// de-duplicate keeping first-occurrence order; then enforce the maximum of 5 and
/// validate the character set.
///
/// Empty elements are dropped rather than rejected because `ci,main,` is a shell
/// artefact, not a caller bug, and `03-data-model.md` already sets the tolerant
/// precedent that duplicates collapse instead of erroring.
///
/// The count is enforced **after** de-duplication, so `ci,ci,ci,ci,ci,ci` is one tag
/// rather than `too_many_tags`.
///
/// Lowercasing here is what lets the engine's `validateTag` keep treating uppercase
/// as a caller bug rather than normalising it: normalisation is this layer's job, and
/// this is that job.
pub fn tags(header: []const u8, set: *TagSet) Error!void {
    set.count = 0;

    var it = std.mem.splitScalar(u8, header, ',');
    while (it.next()) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t");
        if (trimmed.len == 0) continue;
        // Checked here rather than with the character set below because it is also
        // the bound on the buffer being copied into.
        if (trimmed.len > config.max_tag_bytes) return error.InvalidTag;

        var lowered: [config.max_tag_bytes]u8 = undefined;
        for (trimmed, 0..) |ch, i| lowered[i] = std.ascii.toLower(ch);
        const tag = lowered[0..trimmed.len];

        if (set.contains(tag)) continue;
        if (set.count == config.max_tags) return error.TooManyTags;

        @memcpy(set.bytes[set.count][0..tag.len], tag);
        set.lens[set.count] = @intCast(tag.len);
        set.count += 1;
    }

    var i: usize = 0;
    while (i < set.count) : (i += 1) {
        for (set.get(i)) |ch| {
            if (!isTagByte(ch)) return error.InvalidTag;
        }
    }
}

// ---------------------------------------------------------------------------
// Names in the path
// ---------------------------------------------------------------------------

/// Percent-decodes a name exactly once.
///
/// `out` must be at least `config.max_name_bytes`. A `%` not followed by two
/// hexadecimal digits is rejected, as is a decoded name outside 1..256 bytes.
///
/// Character-set validation is deliberately **not** done here — `Store.validateName`
/// owns it, and duplicating the rule is how the two drift apart.
///
/// One consequence worth knowing: `%2F` and a literal `/` produce the same name.
/// Names are byte strings compared after decoding and `/` is a permitted byte, so
/// `a%2Fb` and `a/b` are one entry. Treating an escaped slash as distinct would make
/// identity depend on spelling.
pub fn decodeName(raw: []const u8, out: []u8) Error![]u8 {
    std.debug.assert(out.len >= config.max_name_bytes);

    var n: usize = 0;
    var i: usize = 0;
    while (i < raw.len) {
        if (n == config.max_name_bytes) return error.InvalidName;
        const ch = raw[i];
        if (ch == '%') {
            if (i + 2 >= raw.len) return error.InvalidName;
            const hi = hexDigit(raw[i + 1]) orelse return error.InvalidName;
            const lo = hexDigit(raw[i + 2]) orelse return error.InvalidName;
            out[n] = (hi << 4) | lo;
            i += 3;
        } else {
            out[n] = ch;
            i += 1;
        }
        n += 1;
    }
    if (n < config.min_name_bytes) return error.InvalidName;
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
// Query parameters
// ---------------------------------------------------------------------------

/// Parses `limit`, defaulting when absent. Outside 1..100 is `invalid_limit`.
pub fn limit(raw: ?[]const u8) Error!u32 {
    const text = raw orelse return config.list_default_limit;
    if (text.len == 0 or text.len > 3) return error.InvalidLimit;

    var value: u32 = 0;
    for (text) |ch| {
        if (ch < '0' or ch > '9') return error.InvalidLimit;
        value = value * 10 + (ch - '0');
    }
    if (value < 1 or value > config.list_max_limit) return error.InvalidLimit;
    return value;
}

// ---------------------------------------------------------------------------
// Authorization
// ---------------------------------------------------------------------------

/// Extracts the token from `Authorization: Bearer <key>`.
///
/// Returns null when the header is absent, uses another scheme, or carries an empty
/// token — the caller turns that into `missing_credentials` or `invalid_credentials`
/// as appropriate. The scheme is matched case-insensitively, as RFC 7235 requires;
/// the token is not, because it is an opaque secret.
pub fn bearer(authorization: ?[]const u8) ?[]const u8 {
    const header = authorization orelse return null;
    const prefix = "bearer ";
    if (header.len <= prefix.len) return null;
    if (!std.ascii.eqlIgnoreCase(header[0..prefix.len], prefix)) return null;

    const token = std.mem.trim(u8, header[prefix.len..], " \t");
    if (token.len == 0) return null;
    return token;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "a bare integer is seconds" {
    try testing.expectEqual(@as(u32, 3600), try ttl("3600"));
    try testing.expectEqual(@as(u32, 0), try ttl("0"));
    try testing.expectEqual(@as(u32, 60), try ttl("60"));
}

test "the four suffixes are exact, and 3600 equals 1h" {
    try testing.expectEqual(@as(u32, 90), try ttl("90s"));
    try testing.expectEqual(@as(u32, 900), try ttl("15m"));
    try testing.expectEqual(@as(u32, 86_400), try ttl("24h"));
    try testing.expectEqual(@as(u32, 1_209_600), try ttl("14d"));
    try testing.expectEqual(try ttl("3600"), try ttl("1h"));
}

test "a lifetime out of range parses, so the caller can name the right error" {
    // 0 must reach the caller as a valid parse, or `ttl_too_short` can never be
    // distinguished from `invalid_ttl`.
    try testing.expectEqual(@as(u32, 0), try ttl("0s"));
    try testing.expectEqual(@as(u32, 7_776_000), try ttl("90d"));
}

test "everything outside the grammar is refused" {
    const bad = [_][]const u8{
        "",      "s",     "d",      "-1",   "+1",    "1.5h",  "1h30m",
        "1 h",   " 1h",   "1h ",    "24H",  "15M",   "14D",   "90S",
        "1h2",   "h1",    "1x",     "abc",  "1e3",   "0x10",  "١٢٣",
        "12345678901", // eleven digits
    };
    for (bad) |s| {
        try testing.expectError(error.InvalidTtl, ttl(s));
    }
}

test "an overflowing lifetime is a parse failure, never a wraparound" {
    // A silent wraparound would expire someone's data early, which is the worst
    // available outcome for a mistyped header.
    try testing.expectError(error.InvalidTtl, ttl("4294967296"));
    try testing.expectError(error.InvalidTtl, ttl("9999999999d"));
    try testing.expectError(error.InvalidTtl, ttl("4294967295d"));
    // The largest representable value still works.
    try testing.expectEqual(@as(u32, 4_294_967_295), try ttl("4294967295"));
}

fn parsed(header: []const u8) !TagSet {
    var set: TagSet = .{};
    try tags(header, &set);
    return set;
}

test "tags are split, trimmed and lowercased" {
    const set = try parsed("CI, Main ,\trun-42");
    try testing.expectEqual(@as(u8, 3), set.count);
    try testing.expectEqualStrings("ci", set.get(0));
    try testing.expectEqualStrings("main", set.get(1));
    try testing.expectEqualStrings("run-42", set.get(2));
}

test "an absent or empty header is zero tags" {
    try testing.expectEqual(@as(u8, 0), (try parsed("")).count);
    try testing.expectEqual(@as(u8, 0), (try parsed("   ")).count);
    try testing.expectEqual(@as(u8, 0), (try parsed(",,,")).count);
}

test "a trailing comma is a shell artefact, not an error" {
    const set = try parsed("ci,main,");
    try testing.expectEqual(@as(u8, 2), set.count);
    try testing.expectEqualStrings("main", set.get(1));
}

test "duplicates collapse and keep first-occurrence order" {
    const set = try parsed("beta,alpha,BETA,alpha");
    try testing.expectEqual(@as(u8, 2), set.count);
    try testing.expectEqualStrings("beta", set.get(0));
    try testing.expectEqualStrings("alpha", set.get(1));
}

test "the maximum is enforced after de-duplication" {
    // Six copies of one tag is one tag, not too_many_tags. This is the whole reason
    // the order is written down.
    const set = try parsed("ci,ci,ci,ci,ci,ci");
    try testing.expectEqual(@as(u8, 1), set.count);

    _ = try parsed("a,b,c,d,e");
    try testing.expectError(error.TooManyTags, parsed("a,b,c,d,e,f"));
    // Five distinct plus duplicates is still fine.
    _ = try parsed("a,b,c,d,e,a,b,c");
}

test "the tag character set is enforced after normalisation" {
    // Uppercase is normalised, not rejected — unlike the engine, which treats it as a
    // caller bug precisely because this layer is supposed to have handled it.
    _ = try parsed("A.B_c-d:1");
    // Inner whitespace survives trimming and is not a tag byte; trimming only takes
    // the edges.
    for ([_][]const u8{ "a b", "a@b", "a/b", "a+b", "héllo", "a\tb", "a\"b" }) |bad| {
        try testing.expectError(error.InvalidTag, parsed(bad));
    }

    // A comma is the separator, so this is two valid tags rather than one bad one.
    const split = try parsed("a,b");
    try testing.expectEqual(@as(u8, 2), split.count);
}

test "an over-long tag is rejected at its own boundary" {
    _ = try parsed("t" ** config.max_tag_bytes);
    try testing.expectError(error.InvalidTag, parsed("t" ** (config.max_tag_bytes + 1)));
    // Rejected even when trimming would not save it.
    try testing.expectError(error.InvalidTag, parsed("ok, " ++ "t" ** 65));
}

test "tag slices are the shape the engine takes" {
    const set = try parsed("one,two");
    var out: [config.max_tags][]const u8 = undefined;
    const s = set.slices(&out);
    try testing.expectEqual(@as(usize, 2), s.len);
    try testing.expectEqualStrings("one", s[0]);
    try testing.expectEqualStrings("two", s[1]);
}

fn decoded(raw: []const u8) ![]const u8 {
    var buf: [config.max_name_bytes]u8 = undefined;
    const out = try decodeName(raw, &buf);
    // Copied out, because `out` borrows a frame that is about to disappear.
    return testing.allocator.dupe(u8, out);
}

test "a name is percent-decoded exactly once" {
    const a = try decoded("ci/last-green-sha");
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("ci/last-green-sha", a);

    const b = try decoded("a%20b");
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("a b", b);

    // Once, not twice: %2525 decodes to %25 and stops there.
    const c = try decoded("%2525");
    defer testing.allocator.free(c);
    try testing.expectEqualStrings("%25", c);
}

test "an escaped slash and a literal slash are the same name" {
    const a = try decoded("a%2Fb");
    defer testing.allocator.free(a);
    const b = try decoded("a/b");
    defer testing.allocator.free(b);
    try testing.expectEqualStrings(a, b);
}

test "a malformed escape is rejected" {
    var buf: [config.max_name_bytes]u8 = undefined;
    for ([_][]const u8{ "%", "%2", "%zz", "%2z", "%z2", "a%", "a%g0" }) |bad| {
        try testing.expectError(error.InvalidName, decodeName(bad, &buf));
    }
}

test "the length limit applies to the decoded bytes" {
    var buf: [config.max_name_bytes]u8 = undefined;

    // 256 encoded triples decode to 256 bytes, which is exactly the limit.
    const at_limit = "%41" ** config.max_name_bytes;
    const out = try decodeName(at_limit, &buf);
    try testing.expectEqual(@as(usize, config.max_name_bytes), out.len);

    try testing.expectError(error.InvalidName, decodeName("%41" ** (config.max_name_bytes + 1), &buf));
    try testing.expectError(error.InvalidName, decodeName("n" ** (config.max_name_bytes + 1), &buf));
    try testing.expectError(error.InvalidName, decodeName("", &buf));
}

test "a decoded name still has to satisfy the engine" {
    // Decoding does not validate the character set, so a decoded control byte is
    // caught by the engine rather than here. Splitting it this way keeps one owner
    // for the rule.
    var buf: [config.max_name_bytes]u8 = undefined;
    const out = try decodeName("a%00b", &buf);
    try testing.expectEqual(@as(usize, 3), out.len);
    try testing.expectError(error.NameInvalid, storage.store.validateName(out));
}

test "limit defaults when absent and is bounded when present" {
    try testing.expectEqual(config.list_default_limit, try limit(null));
    try testing.expectEqual(@as(u32, 1), try limit("1"));
    try testing.expectEqual(config.list_max_limit, try limit("100"));

    for ([_][]const u8{ "0", "101", "999", "", "-1", "1.0", "abc", "1000", " 5" }) |bad| {
        try testing.expectError(error.InvalidLimit, limit(bad));
    }
}

test "a bearer token is extracted, and anything else is not a credential" {
    try testing.expectEqualStrings("doot_live_abc", bearer("Bearer doot_live_abc").?);
    // RFC 7235: the scheme is case-insensitive.
    try testing.expectEqualStrings("doot_live_abc", bearer("bearer doot_live_abc").?);
    try testing.expectEqualStrings("doot_live_abc", bearer("BEARER  doot_live_abc  ").?);

    try testing.expectEqual(@as(?[]const u8, null), bearer(null));
    try testing.expectEqual(@as(?[]const u8, null), bearer(""));
    try testing.expectEqual(@as(?[]const u8, null), bearer("Bearer"));
    try testing.expectEqual(@as(?[]const u8, null), bearer("Bearer "));
    try testing.expectEqual(@as(?[]const u8, null), bearer("Bearer   "));
    // No other mechanism exists for the data plane.
    try testing.expectEqual(@as(?[]const u8, null), bearer("Basic dXNlcjpwYXNz"));
    try testing.expectEqual(@as(?[]const u8, null), bearer("doot_live_abc"));
}


// ---------------------------------------------------------------------------
// Content-Type (D64)
// ---------------------------------------------------------------------------

test "ordinary media types are printable" {
    for ([_][]const u8{
        "text/plain",
        "application/json",
        "application/octet-stream",
        "text/plain; charset=utf-8",
        "multipart/form-data; boundary=----abc123",
        "application/vnd.api+json",
        "",
    }) |ct| {
        try std.testing.expect(printableAscii(ct));
    }
}

test "the bytes that made an entry unreadable are refused" {
    // The three the response writer rejects, which is the defect D64 closes: each of
    // these was stored happily and then failed on every read.
    try std.testing.expect(!printableAscii("text/plain\x00evil"));
    try std.testing.expect(!printableAscii("text/plain\revil"));
    try std.testing.expect(!printableAscii("text/plain\nevil"));
    // Leading and embedded, not only trailing.
    try std.testing.expect(!printableAscii("\x00text/plain"));
    try std.testing.expect(!printableAscii("text/\x00plain"));
}

test "every control byte, DEL, and everything above ASCII is refused" {
    var b: u16 = 0;
    while (b <= 0xFF) : (b += 1) {
        const c: u8 = @intCast(b);
        const one = [_]u8{c};
        const want = c >= 0x20 and c <= 0x7E;
        try std.testing.expectEqual(want, printableAscii(&one));
    }
}

test "the boundaries are inclusive" {
    try std.testing.expect(printableAscii(" ")); // 0x20
    try std.testing.expect(printableAscii("~")); // 0x7E
    try std.testing.expect(!printableAscii("\x1F"));
    try std.testing.expect(!printableAscii("\x7F"));
    try std.testing.expect(!printableAscii("\x80"));
}

test "tab is refused, because a media type has no use for one" {
    // Legal in an HTTP field value, but not in a media type — and accepting it would
    // mean the stored value depends on which whitespace the caller happened to send.
    try std.testing.expect(!printableAscii("text/plain\tx"));
}
