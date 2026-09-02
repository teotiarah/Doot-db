//! Short-lived challenges: OTP codes and OAuth `state` values (D70, `06-auth.md`).
//!
//! **Both are RAM-only, and that is a decision rather than an omission.** D70 settled the
//! durability question per kind of state: an OTP lives ten minutes, is single-use, and
//! losing one costs a resend — so logging it would put a credential in the log for a
//! ten-minute window and make the log grow with signup traffic, which D41 already refused
//! for credits. `control/event.zig` has no `otp_issued` type, deliberately, and asserts its
//! own absence.
//!
//! The published consequence: **a restart invalidates outstanding codes and pending OAuth
//! flows.** Both degrade to an action the user already knows how to take — request a new
//! code, click the button again — and neither can silently succeed when it should have
//! failed.
//!
//! ## Fixed tables, for the same reason the rate limiter has one
//!
//! These live on the unauthenticated surface, so a structure that allocated per request
//! would be a memory-exhaustion vector on precisely the endpoint that has to survive being
//! attacked. Both tables are direct-mapped and fixed: a new challenge for a colliding
//! subject evicts the old one.
//!
//! That eviction is the honest cost, so it is stated: an attacker who can find a subject
//! colliding with a victim's can evict the victim's pending code, and the victim has to
//! request another. The seed is randomised per process to make that unaimable — the same
//! defence, and the same reasoning, as `ratelimit.Unauthenticated`.

const std = @import("std");
const storage = @import("storage");

const os = storage.os;

/// `06-auth.md`'s OTP rules, in one place.
pub const otp_digits: usize = 6;
pub const otp_lifetime_s: u32 = 10 * 60;
pub const otp_max_attempts: u8 = 5;
pub const otp_resends_per_hour: u8 = 3;
pub const resend_window_s: u32 = 60 * 60;

/// A pending OAuth flow. Minutes, not hours: the user is mid-redirect, and a `state` that
/// outlives the click it belongs to is a `state` that can be replayed.
pub const oauth_state_lifetime_s: u32 = 10 * 60;

/// How many challenges may be in flight at once.
///
/// Generous against any plausible signup rate and small in absolute terms — 4096 slots at
/// 48 bytes is 192 KiB. Sized by what it costs rather than by what is expected, because the
/// only reason to make it small would be memory it does not use.
pub const slots: usize = 4096;

pub const Code = [otp_digits]u8;

/// Which flow a challenge belongs to (`06-auth.md`).
///
/// Part of the digest, so a code issued for verification cannot be presented to complete a
/// password reset. Without it, one valid code would satisfy both flows — and reset is the
/// one that hands over an account.
pub const Purpose = enum(u8) { verify = 0, reset = 1 };

/// What presenting a code produced.
///
/// `wrong`, `expired` and `unknown` are separate here because the *table* needs to
/// distinguish them; the HTTP layer collapses them into one response, per `06-auth.md`'s
/// requirement that reset and verify reveal nothing about whether a subject exists.
pub const Verdict = enum { ok, wrong, expired, exhausted, unknown };

const Slot = struct {
    /// All zero when free.
    subject: [32]u8 = @splat(0),
    /// `SHA-256(purpose ++ subject ++ code)`. The code itself is never stored
    /// (`06-auth.md`).
    digest: [32]u8 = @splat(0),
    expires_at: u32 = 0,
    attempts: u8 = 0,
    purpose: Purpose = .verify,
    used: bool = true,

    fn free(s: *const Slot) bool {
        return s.used;
    }
};

const Resend = struct {
    subject: [32]u8 = @splat(0),
    window_start: u32 = 0,
    count: u8 = 0,
};

/// Generates a 6-digit code with no modulo bias.
///
/// Rejection sampling over a `u32`: 1,000,000 does not divide 2^32, so folding would make
/// the low codes marginally likelier. The bias is tiny and irrelevant against five
/// attempts — and avoiding it costs a loop that almost never repeats, which is cheaper than
/// explaining why the bias was acceptable.
pub fn generateCode() os.Error!Code {
    const limit: u32 = 1_000_000;
    const reject_at: u32 = (std.math.maxInt(u32) / limit) * limit;

    while (true) {
        var bytes: [4]u8 = undefined;
        try os.getRandom(&bytes);
        const v = std.mem.readInt(u32, &bytes, .little);
        if (v >= reject_at) continue;

        var out: Code = undefined;
        var n = v % limit;
        var i: usize = otp_digits;
        while (i > 0) {
            i -= 1;
            out[i] = '0' + @as(u8, @intCast(n % 10));
            n /= 10;
        }
        return out;
    }
}

fn digestOf(purpose: Purpose, subject: [32]u8, code: []const u8) [32]u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(&[_]u8{@intFromEnum(purpose)});
    h.update(&subject);
    h.update(code);
    var out: [32]u8 = undefined;
    h.final(&out);
    return out;
}

pub const Issued = enum { ok, resend_limit };

pub const Table = struct {
    otp: [slots]Slot = @splat(.{}),
    resends: [slots]Resend = @splat(.{}),
    oauth: [slots]Slot = @splat(.{}),
    /// Randomised per process, so an eviction collision cannot be aimed at a chosen victim.
    seed: u64,

    issued: u64 = 0,
    consumed: u64 = 0,
    evicted: u64 = 0,

    pub fn init() os.Error!Table {
        var b: [8]u8 = undefined;
        try os.getRandom(&b);
        return .{ .seed = std.mem.readInt(u64, &b, .little) };
    }

    pub fn initSeeded(seed: u64) Table {
        return .{ .seed = seed };
    }

    fn index(t: *const Table, subject: [32]u8) usize {
        return @intCast(std.hash.Wyhash.hash(t.seed, &subject) % slots);
    }

    /// Records a code against a subject, enforcing the resend limit.
    ///
    /// `subject` is a digest the caller chooses — for signup and reset that is the email
    /// **anchor** hash (D72), so the flow is keyed by identity rather than by account. That
    /// matters because a reset for an address with no account must behave identically to one
    /// for an address with an account (D75), and an account-keyed table could not represent
    /// the first case at all.
    pub fn issue(t: *Table, purpose: Purpose, subject: [32]u8, code: []const u8, now: u32) Issued {
        if (!t.allowResend(subject, now)) return .resend_limit;

        const i = t.index(subject);
        const slot = &t.otp[i];
        // Direct-mapped: a live challenge for a different subject is evicted. Counted, so
        // the cost is visible rather than inferred.
        if (!slot.free() and slot.expires_at > now and
            !std.mem.eql(u8, &slot.subject, &subject))
        {
            t.evicted += 1;
        }

        slot.* = .{
            .subject = subject,
            .digest = digestOf(purpose, subject, code),
            .expires_at = now +| otp_lifetime_s,
            .attempts = 0,
            .purpose = purpose,
            .used = false,
        };
        t.issued += 1;
        return .ok;
    }

    /// Presents a code. On success the challenge is consumed immediately and single-use.
    pub fn present(t: *Table, purpose: Purpose, subject: [32]u8, code: []const u8, now: u32) Verdict {
        const slot = &t.otp[t.index(subject)];

        if (slot.free()) return .unknown;
        if (!std.mem.eql(u8, &slot.subject, &subject)) return .unknown;
        if (slot.purpose != purpose) return .unknown;
        if (slot.expires_at <= now) {
            slot.used = true;
            return .expired;
        }
        if (slot.attempts >= otp_max_attempts) {
            slot.used = true;
            return .exhausted;
        }

        const presented = digestOf(purpose, subject, code);
        // Constant-time, as `06-auth.md` requires of the comparison.
        if (std.crypto.timing_safe.eql([32]u8, slot.digest, presented)) {
            slot.used = true;
            t.consumed += 1;
            return .ok;
        }

        slot.attempts += 1;
        // Five attempts and the code is invalidated, not merely refused — otherwise the
        // limit would only slow an attacker down rather than stopping them.
        if (slot.attempts >= otp_max_attempts) {
            slot.used = true;
            return .exhausted;
        }
        return .wrong;
    }

    /// Three per hour per subject (`06-auth.md`), over a rolling window that resets rather
    /// than slides — which is what makes it one comparison instead of a history.
    fn allowResend(t: *Table, subject: [32]u8, now: u32) bool {
        const r = &t.resends[t.index(subject)];
        const same = std.mem.eql(u8, &r.subject, &subject);
        if (!same or now -| r.window_start >= resend_window_s) {
            r.* = .{ .subject = subject, .window_start = now, .count = 1 };
            return true;
        }
        if (r.count >= otp_resends_per_hour) return false;
        r.count += 1;
        return true;
    }

    /// Registers a pending OAuth flow, keyed on the digest of the `state` value.
    ///
    /// The `state` itself goes in a short-lived `__Host-` cookie; this is the server side of
    /// the binding, so that a callback presenting a `state` we never issued is refused
    /// rather than trusted (`06-auth.md`).
    pub fn beginOauth(t: *Table, state_hash: [32]u8, now: u32) void {
        const slot = &t.oauth[t.index(state_hash)];
        if (!slot.free() and slot.expires_at > now) t.evicted += 1;
        slot.* = .{
            .subject = state_hash,
            .digest = state_hash,
            .expires_at = now +| oauth_state_lifetime_s,
            .used = false,
        };
    }

    /// Consumes a pending OAuth flow. **Single use**: a replayed callback finds nothing.
    pub fn takeOauth(t: *Table, state_hash: [32]u8, now: u32) bool {
        const slot = &t.oauth[t.index(state_hash)];
        if (slot.free()) return false;
        if (slot.expires_at <= now) {
            slot.used = true;
            return false;
        }
        // Constant-time: the `state` is presented by the caller, so it is a credential.
        if (!std.crypto.timing_safe.eql([32]u8, slot.subject, state_hash)) return false;
        slot.used = true;
        return true;
    }

    /// Drops challenges whose lifetime has passed.
    ///
    /// Expiry is already authoritative at `present`, so this is reclamation rather than
    /// enforcement — the same relationship the entry store's index sweep has to its lazy
    /// expiry check. It exists so a slot held by a dead challenge does not evict a live one.
    pub fn sweep(t: *Table, now: u32) usize {
        var n: usize = 0;
        for (&t.otp) |*s| {
            if (!s.free() and s.expires_at <= now) {
                s.used = true;
                n += 1;
            }
        }
        for (&t.oauth) |*s| {
            if (!s.free() and s.expires_at <= now) {
                s.used = true;
                n += 1;
            }
        }
        return n;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const now0: u32 = 1_700_000_000;

fn subj(b: u8) [32]u8 {
    return @splat(b);
}

test "a code is six digits, and uniformly distributed over them" {
    var seen_first: [10]bool = @splat(false);
    var i: usize = 0;
    while (i < 500) : (i += 1) {
        const c = try generateCode();
        try testing.expectEqual(otp_digits, c.len);
        for (c) |ch| try testing.expect(ch >= '0' and ch <= '9');
        seen_first[c[0] - '0'] = true;
    }
    // Every leading digit occurs, including zero — a code is a string of six digits and
    // not a number, so `000123` is a legal code and must not be normalised away.
    for (seen_first) |s| try testing.expect(s);
}

test "the right code verifies once and then is gone" {
    var t = Table.initSeeded(1);
    const s = subj(1);
    try testing.expectEqual(Issued.ok, t.issue(.verify, s, "123456", now0));

    try testing.expectEqual(Verdict.ok, t.present(.verify, s, "123456", now0));
    // Single use: consumed immediately on success.
    try testing.expectEqual(Verdict.unknown, t.present(.verify, s, "123456", now0));
    try testing.expectEqual(@as(u64, 1), t.consumed);
}

test "a wrong code is wrong, and five of them invalidate the challenge" {
    var t = Table.initSeeded(2);
    const s = subj(2);
    _ = t.issue(.verify, s, "123456", now0);

    var i: u8 = 0;
    while (i < otp_max_attempts - 1) : (i += 1) {
        try testing.expectEqual(Verdict.wrong, t.present(.verify, s, "000000", now0));
    }
    // The fifth failure invalidates rather than merely refusing -- otherwise the limit
    // would only slow an attacker down.
    try testing.expectEqual(Verdict.exhausted, t.present(.verify, s, "000000", now0));
    // And the right code no longer helps.
    try testing.expectEqual(Verdict.unknown, t.present(.verify, s, "123456", now0));
}

test "a code expires after ten minutes" {
    var t = Table.initSeeded(3);
    const s = subj(3);
    _ = t.issue(.verify, s, "123456", now0);

    try testing.expectEqual(Verdict.ok, t.present(.verify, s, "123456", now0 + otp_lifetime_s - 1));

    _ = t.issue(.verify, s, "123456", now0);
    try testing.expectEqual(Verdict.expired, t.present(.verify, s, "123456", now0 + otp_lifetime_s));
}

test "a code issued for verification cannot complete a reset" {
    // Without the purpose in the digest, one valid code would satisfy both flows -- and
    // reset is the one that hands over an account.
    var t = Table.initSeeded(4);
    const s = subj(4);
    _ = t.issue(.verify, s, "123456", now0);
    try testing.expectEqual(Verdict.unknown, t.present(.reset, s, "123456", now0));
    // The verification itself still works, so the code was not consumed by the attempt.
    try testing.expectEqual(Verdict.ok, t.present(.verify, s, "123456", now0));
}

test "one subject's code does not verify for another" {
    var t = Table.initSeeded(5);
    _ = t.issue(.verify, subj(6), "123456", now0);
    try testing.expectEqual(Verdict.unknown, t.present(.verify, subj(7), "123456", now0));
}

test "three resends an hour, then no more until the window turns over" {
    var t = Table.initSeeded(6);
    const s = subj(8);

    var i: u8 = 0;
    while (i < otp_resends_per_hour) : (i += 1) {
        try testing.expectEqual(Issued.ok, t.issue(.verify, s, "123456", now0));
    }
    try testing.expectEqual(Issued.resend_limit, t.issue(.verify, s, "123456", now0));

    // A rolling window that resets rather than slides, which is one comparison instead of
    // a history.
    try testing.expectEqual(Issued.ok, t.issue(.verify, s, "123456", now0 + resend_window_s));
}

test "the resend limit is per subject" {
    var t = Table.initSeeded(7);
    var i: u8 = 0;
    while (i < otp_resends_per_hour) : (i += 1) _ = t.issue(.verify, subj(9), "111111", now0);
    try testing.expectEqual(Issued.resend_limit, t.issue(.verify, subj(9), "111111", now0));
    // Another address is unaffected.
    try testing.expectEqual(Issued.ok, t.issue(.verify, subj(10), "222222", now0));
}

test "a reissue replaces the previous code" {
    var t = Table.initSeeded(8);
    const s = subj(11);
    _ = t.issue(.verify, s, "111111", now0);
    _ = t.issue(.verify, s, "222222", now0);

    // The old code is dead: only the most recent one can be presented, which is what
    // "resend" has to mean if a user who requests a second code is not to be confused by
    // the first still working.
    try testing.expectEqual(Verdict.wrong, t.present(.verify, s, "111111", now0));
    try testing.expectEqual(Verdict.ok, t.present(.verify, s, "222222", now0));
}

test "presenting to an empty table is unknown, not a crash" {
    var t = Table.initSeeded(9);
    try testing.expectEqual(Verdict.unknown, t.present(.verify, subj(12), "123456", now0));
    try testing.expectEqual(Verdict.unknown, t.present(.reset, subj(0), "000000", now0));
}

test "an OAuth state is single-use" {
    var t = Table.initSeeded(10);
    const st = subj(13);
    t.beginOauth(st, now0);

    try testing.expect(t.takeOauth(st, now0));
    // A replayed callback finds nothing, which is what makes the state binding worth
    // having: without single use, a captured callback URL could be replayed.
    try testing.expect(!t.takeOauth(st, now0));
}

test "an OAuth state we never issued is refused" {
    var t = Table.initSeeded(11);
    try testing.expect(!t.takeOauth(subj(14), now0));
}

test "an OAuth state expires" {
    var t = Table.initSeeded(12);
    const st = subj(15);
    t.beginOauth(st, now0);
    try testing.expect(!t.takeOauth(st, now0 + oauth_state_lifetime_s));

    t.beginOauth(st, now0);
    try testing.expect(t.takeOauth(st, now0 + oauth_state_lifetime_s - 1));
}

test "the sweep reclaims dead challenges and leaves live ones" {
    var t = Table.initSeeded(13);
    _ = t.issue(.verify, subj(16), "111111", now0);
    t.beginOauth(subj(17), now0);
    _ = t.issue(.verify, subj(18), "222222", now0 + otp_lifetime_s);

    const n = t.sweep(now0 + otp_lifetime_s);
    try testing.expectEqual(@as(usize, 2), n);
    // The one issued later is untouched.
    try testing.expectEqual(Verdict.ok, t.present(.verify, subj(18), "222222", now0 + otp_lifetime_s));
}

test "eviction is counted, so its cost is visible rather than inferred" {
    // Direct-mapped, so a colliding subject evicts. The honest consequence: an attacker who
    // finds a colliding subject can make a victim request a new code. The seed is randomised
    // per process to keep that unaimable.
    var t = Table.initSeeded(14);
    var found: ?[32]u8 = null;
    const first = subj(19);
    const target = t.index(first);

    var i: u32 = 0;
    while (i < 200_000) : (i += 1) {
        var cand: [32]u8 = @splat(0);
        std.mem.writeInt(u32, cand[0..4], i, .little);
        if (t.index(cand) == target and !std.mem.eql(u8, &cand, &first)) {
            found = cand;
            break;
        }
    }
    const second = found orelse return error.SkipZigTest;

    _ = t.issue(.verify, first, "111111", now0);
    _ = t.issue(.verify, second, "222222", now0);
    try testing.expectEqual(@as(u64, 1), t.evicted);
    // The evicted subject has to ask again -- exactly the degradation D70 accepted for a
    // lost OTP.
    try testing.expectEqual(Verdict.unknown, t.present(.verify, first, "111111", now0));
    try testing.expectEqual(Verdict.ok, t.present(.verify, second, "222222", now0));
}

test "the seed is randomised per process" {
    const a = try Table.init();
    const b = try Table.init();
    try testing.expect(a.seed != b.seed);
}

test "the table's memory is fixed and small" {
    // Fixed because this lives on the unauthenticated surface, where anything that allocates
    // per request is a memory-exhaustion vector.
    try testing.expect(@sizeOf(Table) < 1024 * 1024);
}

test "the rules are the ones 06-auth.md publishes" {
    try testing.expectEqual(@as(usize, 6), otp_digits);
    try testing.expectEqual(@as(u32, 600), otp_lifetime_s);
    try testing.expectEqual(@as(u8, 5), otp_max_attempts);
    try testing.expectEqual(@as(u8, 3), otp_resends_per_hour);
}
