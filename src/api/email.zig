//! Email addresses have two forms, and they are never interchanged (D72).
//!
//! The **delivery address** is exactly what the user typed, byte for byte. It is what
//! outbound mail goes to and what the dashboard and `whoami` display. Nothing in this
//! file produces it, because producing it is not an operation — it is the input.
//!
//! The **anchor** is a normalised form that exists for exactly one comparison: has this
//! identity already claimed a trial grant (`01-product.md`, `06-auth.md`)? It is
//! lowercased, plus-addressing is stripped, and Gmail's dots are removed. Only its
//! `SHA-256` is ever stored, because equality is the only operation and holding
//! normalised addresses in the clear would mean a second copy of everyone's email for
//! no extra capability.
//!
//! Getting these the wrong way round is a real defect, not a tidiness issue: mail sent
//! to a plus-stripped address arrives somewhere the user did not choose, and the local
//! part of an address is case-sensitive under RFC 5321, so a lowercased address is not
//! even reliably deliverable.
//!
//! Pure, per `api.zig`: no allocation, no clock, no I/O.

const std = @import("std");

/// RFC 5321's practical ceiling. Not a Doot limit — simply the largest thing that can be
/// a real address. `control/event.zig` carries the same number as the log's bound; this
/// module cannot import it, because `api` is specified not to depend on `control`.
pub const max_bytes: usize = 254;

pub const Error = error{
    Empty,
    TooLong,
    NoAtSign,
    EmptyLocalPart,
    EmptyDomain,
    DomainHasNoDot,
    ForbiddenByte,
};

/// A pragmatic structural check, and deliberately nothing more.
///
/// **Deliverability is proven by the OTP round-trip, not by a syntax rule.** An account
/// does not activate until a code sent to the address comes back (`06-auth.md`), so the
/// only job here is to catch an obvious typo before we spend a mail on it, and to refuse
/// bytes that must never reach a header or a log line. A stricter grammar would reject
/// real addresses — RFC 5322 permits quoted local parts, and every regex that claims to
/// implement it is wrong somewhere — while adding no security the OTP does not already
/// provide.
pub fn check(address: []const u8) Error!void {
    if (address.len == 0) return error.Empty;
    if (address.len > max_bytes) return error.TooLong;

    // Printable ASCII only. Same reasoning as D64 for `Content-Type`: this value is
    // echoed into responses and into outbound mail headers, so a control byte here is a
    // value that can be stored and never safely read back.
    for (address) |c| {
        if (c < 0x21 or c > 0x7E) return error.ForbiddenByte;
    }

    const at = std.mem.lastIndexOfScalar(u8, address, '@') orelse return error.NoAtSign;
    const local = address[0..at];
    const domain = address[at + 1 ..];
    if (local.len == 0) return error.EmptyLocalPart;
    if (domain.len == 0) return error.EmptyDomain;

    // A domain with no dot is either a local hostname or a typo. Neither can receive
    // mail from the internet.
    const dot = std.mem.indexOfScalar(u8, domain, '.') orelse return error.DomainHasNoDot;
    if (dot == 0 or dot == domain.len - 1) return error.DomainHasNoDot;
}

/// Google's mailbox, under both of its spellings.
///
/// Exactly these, and no more. A general "strip dots" rule would be wrong: at most
/// providers `a.b@` and `ab@` are different people, so a broader rule would merge
/// strangers' identities and hand one of them a zero-credit account.
const google_domains = [_][]const u8{ "gmail.com", "googlemail.com" };

/// The spelling every Google address is folded onto.
///
/// `googlemail.com` is not a second provider, it is a second spelling of one mailbox — so
/// an anchor that kept them distinct would produce two identities for one inbox, and a
/// second trial grant for anyone who noticed. Dot-stripping without this fold defends the
/// harder half of the vector and leaves the easy half open (D72 amendment).
const google_canonical = "gmail.com";

/// Writes the normalised anchor form into `out` and returns the slice used.
///
/// `out` must be at least `max_bytes`. Normalisation only ever shortens, so that is
/// always enough.
pub fn normalise(address: []const u8, out: []u8) Error![]const u8 {
    try check(address);
    std.debug.assert(out.len >= max_bytes);

    const at = std.mem.lastIndexOfScalar(u8, address, '@').?;
    const local = address[0..at];
    const domain = address[at + 1 ..];

    // Lowercase for matching only. This is the step that must never touch the delivery
    // address.
    var dbuf: [max_bytes]u8 = undefined;
    const lower_domain = std.ascii.lowerString(dbuf[0..domain.len], domain);

    var is_google = false;
    for (google_domains) |d| {
        if (std.mem.eql(u8, lower_domain, d)) is_google = true;
    }
    const canonical_domain = if (is_google) google_canonical else lower_domain;

    var n: usize = 0;
    for (local) |c| {
        // Plus-addressing: everything from the first `+` in the local part is a label the
        // user chose per-signup, and it is the cheapest way to farm a trial grant.
        if (c == '+') break;
        if (is_google and c == '.') continue;
        out[n] = std.ascii.toLower(c);
        n += 1;
    }
    // Stripping can empty a local part — `+tag@example.com` — and an anchor that is just
    // a domain would collide every user of that domain onto one identity.
    if (n == 0) return error.EmptyLocalPart;

    out[n] = '@';
    n += 1;
    @memcpy(out[n..][0..canonical_domain.len], canonical_domain);
    n += canonical_domain.len;
    return out[0..n];
}

/// The anchor as it is stored: a digest, never the address (D72).
pub fn anchorHash(address: []const u8) Error![32]u8 {
    var buf: [max_bytes]u8 = undefined;
    const norm = try normalise(address, &buf);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(norm, &digest, .{});
    return digest;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// `expected` against the normalised form of `address`.
///
/// The buffer lives in this frame and the slice is compared before it returns, which is
/// the shape that avoids the dead-frame slice this project has been bitten by before
/// (`record.decode`, M1).
fn expectNorm(expected: []const u8, address: []const u8) !void {
    var buf: [max_bytes]u8 = undefined;
    try testing.expectEqualStrings(expected, try normalise(address, &buf));
}

test "case is folded for matching" {
    try expectNorm("someone@example.com", "SomeOne@Example.COM");
}

test "plus-addressing is stripped" {
    try expectNorm("someone@example.com", "someone+ci@example.com");
    // Everything after the first plus goes, including further plusses.
    try expectNorm("someone@example.com", "someone+a+b@example.com");
}

test "dots are removed for Gmail and kept everywhere else" {
    try expectNorm("someone@gmail.com", "some.one@gmail.com");
    // The rule is deliberately not general: at most providers these are two people.
    try expectNorm("some.one@example.com", "some.one@example.com");
    try expectNorm("some.one@fastmail.com", "Some.One@FastMail.com");
}

test "googlemail folds onto gmail, because they are one mailbox" {
    // Without this, `someone@googlemail.com` is a second identity for the same inbox and
    // therefore a second trial grant (D72 amendment).
    try expectNorm("someone@gmail.com", "someone@googlemail.com");
    try expectNorm("someone@gmail.com", "s.o.m.e.one+ci@GoogleMail.COM");
    // And nothing else is folded: a lookalike domain is a different provider.
    try expectNorm("someone@gmail.com.co", "someone@gmail.com.co");
    try expectNorm("someone@notgmail.com", "someone@notgmail.com");
}

test "the anchor collapses the farming variants onto one identity" {
    const a = try anchorHash("someone@gmail.com");
    for ([_][]const u8{
        "SomeOne@Gmail.com",
        "some.one@gmail.com",
        "someone+trial1@gmail.com",
        "S.O.M.E.O.N.E+whatever@GOOGLEMAIL.com",
    }) |variant| {
        try testing.expectEqualSlices(u8, &a, &(try anchorHash(variant)));
    }
}

test "different identities do not collide" {
    const a = try anchorHash("someone@example.com");
    const b = try anchorHash("someone.else@example.com");
    const c = try anchorHash("someone@other.com");
    try testing.expect(!std.mem.eql(u8, &a, &b));
    try testing.expect(!std.mem.eql(u8, &a, &c));
}

test "the delivery address is never what this file returns" {
    // The property that keeps D72 honest: normalisation is lossy, so a caller that
    // mailed the anchor would be mailing the wrong person.
    var buf: [max_bytes]u8 = undefined;
    const supplied = "Some.One+ci@Gmail.com";
    const anchor = try normalise(supplied, &buf);
    try testing.expect(!std.mem.eql(u8, supplied, anchor));
}

test "structural rejections" {
    try testing.expectError(error.Empty, check(""));
    try testing.expectError(error.TooLong, check(("a" ** 250) ++ "@b.co"));
    try testing.expectError(error.NoAtSign, check("someone.example.com"));
    try testing.expectError(error.EmptyLocalPart, check("@example.com"));
    try testing.expectError(error.EmptyDomain, check("someone@"));
    try testing.expectError(error.DomainHasNoDot, check("someone@localhost"));
    try testing.expectError(error.DomainHasNoDot, check("someone@.com"));
    try testing.expectError(error.DomainHasNoDot, check("someone@com."));
    try testing.expectError(error.ForbiddenByte, check("some one@example.com"));
    try testing.expectError(error.ForbiddenByte, check("someone@exa\x00mple.com"));
}

test "an address that normalises to nothing is refused" {
    // `+tag@example.com` would otherwise become `@example.com`, collapsing every user of
    // that domain onto one anchor and denying them all a trial grant.
    var buf: [max_bytes]u8 = undefined;
    try testing.expectError(error.EmptyLocalPart, normalise("+tag@example.com", &buf));
}

test "the last at-sign separates, so a quoted local part survives" {
    // RFC 5322 permits `@` inside a quoted local part. Splitting on the first one would
    // put the rest of the local part into the domain.
    try expectNorm("\"odd@name\"@example.com", "\"odd@name\"@example.com");
}

test "a maximum-length address is accepted" {
    const domain = "@example.com";
    const local_len = max_bytes - domain.len;
    var addr: [max_bytes]u8 = undefined;
    @memset(addr[0..local_len], 'a');
    @memcpy(addr[local_len..], domain);
    try check(&addr);
    var buf: [max_bytes]u8 = undefined;
    _ = try normalise(&addr, &buf);
}
