//! Credential generation: API keys and session tokens (D76, `06-auth.md`).
//!
//! Everything here produces a value that exists **once**, in one response, and is never
//! recoverable afterwards. Only a `SHA-256` of it is ever stored, which is correct for a
//! credential of this shape and deliberately not Argon2id: 190 bits of uniform randomness
//! has no dictionary to attack, so a slow hash would buy nothing and would cost latency on
//! something checked on every single request (D21).
//!
//! Follows `ulid.zig`'s split — a pure encoder that takes its entropy as a parameter, and a
//! thin wrapper that reaches for the kernel — because that is what makes the encoding
//! exactly testable without a source of randomness in the test.

const std = @import("std");
const storage = @import("storage");

const os = storage.os;

/// `06-auth.md`. The prefix makes a leaked key greppable in a repository, and reserving a
/// second one now means adding it later changes nothing about how an existing key parses.
pub const live_prefix = "doot_live_";
pub const test_prefix = "doot_test_";

/// 32 × log₂(62) = 190.5 bits, which is where `06-auth.md`'s figure comes from. Recorded
/// as a derivation so that changing the length has to confront the number we publish.
pub const key_chars: usize = 32;
pub const api_key_len: usize = live_prefix.len + key_chars;
pub const ApiKey = [api_key_len]u8;

/// Base62, not base64url.
///
/// `-` and `_` survive a double-click selection differently across terminals and chat
/// clients, and a credential a human copies by hand should be one alphanumeric token.
const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";

comptime {
    std.debug.assert(alphabet.len == 62);
}

/// Bytes at or above this are discarded rather than folded.
///
/// 256 is not a multiple of 62, so `byte % 62` would make the first eight characters of
/// the alphabet about 1.6% more likely than the rest. 248 is the largest multiple of 62
/// below 256, so discarding `>= 248` leaves a uniform distribution. Not exploitable at
/// this length — and free to avoid, which is the whole argument: three lines removes a
/// question a reader would otherwise have to reason about.
const reject_at: u8 = 248;

comptime {
    std.debug.assert(reject_at == (256 / 62) * 62);
}

/// Roughly 3% of draws are rejected, so this is generous rather than tight. A fixed draw
/// means one syscall, which matters because the alternative is a loop that occasionally
/// asks the kernel again.
const draw_bytes: usize = key_chars * 2;

pub const Error = error{OutOfEntropy} || os.Error;

/// Encodes `entropy` into a key body by rejection sampling.
///
/// Returns `error.OutOfEntropy` if the supplied bytes ran out before 32 characters were
/// produced — which a caller passing `draw_bytes` will not see in practice, and which is
/// an error rather than a silent short key because a short credential is a weak one.
pub fn encodeBody(entropy: []const u8, out: *[key_chars]u8) error{OutOfEntropy}!void {
    var n: usize = 0;
    for (entropy) |b| {
        if (b >= reject_at) continue;
        out[n] = alphabet[b % 62];
        n += 1;
        if (n == key_chars) return;
    }
    return error.OutOfEntropy;
}

/// A fresh API key. The plaintext returned here is the only copy that will ever exist.
pub fn apiKey() Error!ApiKey {
    var out: ApiKey = undefined;
    @memcpy(out[0..live_prefix.len], live_prefix);

    var entropy: [draw_bytes]u8 = undefined;
    try os.getRandom(&entropy);
    try encodeBody(&entropy, out[live_prefix.len..][0..key_chars]);
    return out;
}

/// Does this look like one of ours, before we spend a hash and a lookup on it?
///
/// Cheap and deliberately not authoritative — an unknown key is still `401`. It exists so
/// that a caller pasting a truncated key gets the same answer as one pasting a wrong key,
/// which is the answer `06-auth.md` requires either way.
pub fn hasKeyPrefix(token: []const u8) bool {
    return std.mem.startsWith(u8, token, live_prefix) or
        std.mem.startsWith(u8, token, test_prefix);
}

/// `06-auth.md`: 32 random bytes, base64url, held server-side as `SHA-256`.
pub const session_token_bytes: usize = 32;
pub const session_token_len: usize = std.base64.url_safe_no_pad.Encoder.calcSize(session_token_bytes);
pub const SessionToken = [session_token_len]u8;

/// A session token is not typed by a human — it lives in a cookie — so base64url is right
/// here where base62 was right for an API key. Fewer bytes on every request, and the
/// characters that make base64url awkward to transcribe are irrelevant to a cookie.
pub fn encodeSessionToken(entropy: [session_token_bytes]u8) SessionToken {
    var out: SessionToken = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&out, &entropy);
    return out;
}

pub fn sessionToken() Error!SessionToken {
    var entropy: [session_token_bytes]u8 = undefined;
    try os.getRandom(&entropy);
    return encodeSessionToken(entropy);
}

/// The synchroniser token for state-changing control-plane requests.
///
/// Derived rather than stored: a keyed hash of the session's digest under
/// `DOOT_HMAC_SECRET`. That needs no storage, no event type and no checkpoint, and it
/// survives a restart without the control log carrying it — while remaining unguessable
/// without the secret. The session digest rather than the token itself, so that nothing
/// which can reconstruct the cookie is derivable from a value the page hands to
/// JavaScript.
pub const csrf_token_len: usize = std.base64.url_safe_no_pad.Encoder.calcSize(32);
pub const CsrfToken = [csrf_token_len]u8;

pub fn csrfToken(hmac_secret: [32]u8, session_token_hash: [32]u8) CsrfToken {
    const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;
    var mac: [32]u8 = undefined;
    var h = Hmac.init(&hmac_secret);
    // Domain-separated, so this value can never coincide with a pagination cursor's MAC
    // over the same secret (D46).
    h.update("doot-csrf-v1");
    h.update(&session_token_hash);
    h.final(&mac);

    var out: CsrfToken = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&out, &mac);
    return out;
}

/// Constant-time comparison, because this is a credential check.
pub fn csrfMatches(expected: CsrfToken, presented: []const u8) bool {
    if (presented.len != csrf_token_len) return false;
    return std.crypto.timing_safe.eql(CsrfToken, expected, presented[0..csrf_token_len].*);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "an API key has the published shape" {
    const k = try apiKey();
    try testing.expectEqual(api_key_len, k.len);
    try testing.expect(std.mem.startsWith(u8, &k, live_prefix));
    try testing.expect(hasKeyPrefix(&k));
    for (k[live_prefix.len..]) |c| {
        try testing.expect(std.mem.indexOfScalar(u8, alphabet, c) != null);
    }
}

test "the published entropy figure is what the length actually gives" {
    // 32 characters of base62. If either number moves, the claim in 06-auth.md moves with
    // it and this fails rather than the document quietly becoming wrong.
    const bits = @as(f64, @floatFromInt(key_chars)) * std.math.log2(@as(f64, 62.0));
    try testing.expect(bits > 190.0 and bits < 191.0);
}

test "rejection sampling discards the biased tail" {
    // A byte at the boundary is used; one above it is not. Folding 248..255 back over the
    // alphabet is exactly the 1.6% bias this avoids.
    var out: [key_chars]u8 = undefined;

    var all_low: [key_chars]u8 = @splat(0);
    try encodeBody(&all_low, &out);
    try testing.expectEqualStrings("A" ** key_chars, &out);

    // 247 is the last accepted byte, and 247 % 62 == 61 — the final character of the
    // alphabet. That it lands exactly on the end is the point: 248 is 62 × 4, so the
    // accepted range covers whole cycles and nothing is over-represented.
    var boundary: [key_chars]u8 = @splat(247);
    try encodeBody(&boundary, &out);
    try testing.expectEqualStrings("9" ** key_chars, &out);

    // Nothing at or above 248 contributes at all.
    var rejected: [key_chars * 2]u8 = @splat(248);
    try testing.expectError(error.OutOfEntropy, encodeBody(&rejected, &out));
}

test "entropy that runs out is an error rather than a short key" {
    var out: [key_chars]u8 = undefined;
    var short: [key_chars - 1]u8 = @splat(0);
    try testing.expectError(error.OutOfEntropy, encodeBody(&short, &out));
}

test "the standard draw is enough in practice" {
    // 3% rejection over 64 bytes leaving fewer than 32 usable is vanishingly unlikely, but
    // the wrapper returns an error rather than asserting, so this exercises the real path
    // repeatedly rather than reasoning about it.
    var i: usize = 0;
    while (i < 200) : (i += 1) _ = try apiKey();
}

test "two keys are not the same key" {
    const a = try apiKey();
    const b = try apiKey();
    try testing.expect(!std.mem.eql(u8, &a, &b));
}

test "a session token is base64url of 32 bytes" {
    const t = try sessionToken();
    try testing.expectEqual(session_token_len, t.len);
    var decoded: [session_token_bytes]u8 = undefined;
    try std.base64.url_safe_no_pad.Decoder.decode(&decoded, &t);
}

test "the reserved test prefix parses but is never issued" {
    try testing.expect(hasKeyPrefix(test_prefix ++ ("a" ** key_chars)));
    // Nothing generates one, which is what "reserved" means.
    const k = try apiKey();
    try testing.expect(!std.mem.startsWith(u8, &k, test_prefix));
}

test "a token without a known prefix is not one of ours" {
    try testing.expect(!hasKeyPrefix("sk_live_whatever"));
    try testing.expect(!hasKeyPrefix(""));
    try testing.expect(!hasKeyPrefix("doot_"));
}

test "a synchroniser token is stable for a session and differs across sessions" {
    const secret: [32]u8 = @splat(0x11);
    const s1: [32]u8 = @splat(0xAA);
    const s2: [32]u8 = @splat(0xBB);

    const a = csrfToken(secret, s1);
    // Derived, so it survives a restart: the same inputs give the same token with nothing
    // stored in between.
    try testing.expectEqualStrings(&a, &csrfToken(secret, s1));
    try testing.expect(!std.mem.eql(u8, &a, &csrfToken(secret, s2)));
    // And it moves with the secret, so rotating invalidates outstanding tokens.
    try testing.expect(!std.mem.eql(u8, &a, &csrfToken(@splat(0x22), s1)));
}

test "a synchroniser token is compared in constant time, and length-checked first" {
    const secret: [32]u8 = @splat(0x11);
    const expected = csrfToken(secret, @splat(0xAA));
    try testing.expect(csrfMatches(expected, &expected));
    try testing.expect(!csrfMatches(expected, "short"));
    try testing.expect(!csrfMatches(expected, ""));

    var wrong = expected;
    wrong[0] = if (wrong[0] == 'A') 'B' else 'A';
    try testing.expect(!csrfMatches(expected, &wrong));
}

test "the synchroniser token is domain-separated from a cursor MAC" {
    // Both are HMAC-SHA256 under DOOT_HMAC_SECRET (D46). Without the label, a value valid
    // in one role could be valid in the other.
    const secret: [32]u8 = @splat(0x11);
    const digest: [32]u8 = @splat(0xAA);

    const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;
    var unlabelled: [32]u8 = undefined;
    var h = Hmac.init(&secret);
    h.update(&digest);
    h.final(&unlabelled);

    var encoded: [csrf_token_len]u8 = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&encoded, &unlabelled);
    try testing.expect(!std.mem.eql(u8, &encoded, &csrfToken(secret, digest)));
}
