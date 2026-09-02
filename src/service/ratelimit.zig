//! Rate limiting for the unauthenticated control plane (D74).
//!
//! The authenticated buckets live on the `Account` in `Control`, behind the mutex that
//! already serialises every per-account mutation — one for the data plane (D6, D58) and one
//! for the dashboard. Neither is here.
//!
//! What is here is the problem those cannot solve: **signup, login and password reset have
//! no account yet.** A per-account bucket cannot limit a request that has not established
//! which account it concerns — or whether that account exists, which enumeration resistance
//! forbids revealing at all (D75).
//!
//! Two mechanisms, because they defend different things:
//!
//! - a **per-address** bucket over a fixed table, which is the actual per-client limit;
//! - a **global** bucket over the whole unauthenticated surface, which bounds the total cost
//!   regardless of whether the address is trustworthy.
//!
//! ## Why the global one is not redundant
//!
//! The per-address bucket is only as trustworthy as the address, and behind Cloudflare the
//! origin sees Cloudflare's address on every connection — the real client is in
//! `CF-Connecting-IP`. Believing that header is sound **only once nothing but Cloudflare can
//! reach the origin**, which is what `Full (strict)`, Authenticated Origin Pulls and the
//! Cloudflare-ranges firewall establish, and which D68 moved to the end of M5. Until then an
//! attacker can vary the header freely and therefore command an unlimited number of
//! per-address buckets. The global ceiling is what makes the surface safe in the meantime,
//! and a per-IP limit that silently depended on an unbuilt firewall would be worse than none
//! — because it would look like a defence.
//!
//! **This module takes the address as opaque bytes and does not decide what they are.**
//! Choosing between the header and the socket peer is the caller's job: it is the layer that
//! knows about HTTP and about the trust boundary, and a table that reached for either would
//! be a table that could not be tested without one.

const std = @import("std");
const storage = @import("storage");
const control = @import("control");

const plan = control.plan;

/// The same shape the data-plane bucket returns, so a handler emits the same headers
/// whichever bucket answered (`02-api.md`).
pub const Decision = control.RateDecision;

/// One token bucket. Identical arithmetic to `Control.takeToken`, kept as its own type
/// because these buckets are not attached to an account and cannot live on one.
pub const Bucket = struct {
    tokens: f64 = 0,
    /// When `tokens` was last brought up to date.
    ///
    /// Zero means "never", which makes the first call see an elapsed time of the whole
    /// epoch and fill the bucket. Deliberate, and the same trick `Account` uses: there is
    /// no initialisation to forget, and a fresh bucket behaves like an idle one.
    at: u32 = 0,

    pub fn take(b: *Bucket, now: u32, rate_per_min: u32, burst: u32, per_second: f64) Decision {
        const cap: f64 = @floatFromInt(burst);

        // Saturating subtraction, so a clock that steps backwards grants nothing rather
        // than underflowing. A forwards jump only ever refills, which errs toward letting
        // the caller through — the only direction a rate limit may err by accident (D33).
        const elapsed: f64 = @floatFromInt(now -| b.at);
        b.tokens = @min(cap, b.tokens + elapsed * per_second);
        b.at = now;

        const allowed = b.tokens >= 1.0;
        if (allowed) b.tokens -= 1.0;

        return .{
            .allowed = allowed,
            .limit = rate_per_min,
            .remaining = @intFromFloat(@floor(b.tokens)),
            .reset_s = secondsToAccrue(cap - b.tokens, per_second),
            .retry_after_s = if (allowed) 0 else secondsToAccrue(1.0 - b.tokens, per_second),
        };
    }
};

/// Rounded up, because rounding down advertises a retry that is still too early and a
/// client honouring `Retry-After` would earn a second `429`.
fn secondsToAccrue(wanted: f64, per_second: f64) u32 {
    if (wanted <= 0) return 0;
    return @intFromFloat(@ceil(wanted / per_second));
}

/// The unauthenticated control-plane limiter: a fixed address table plus a global ceiling.
///
/// **Fixed size, and lossy on collision.** Two addresses that hash together share a bucket,
/// which makes the limit *stricter* for both and never looser — and a fixed table cannot be
/// grown without bound by an attacker rotating addresses. A map that allocated per address
/// would be a memory-exhaustion vector on the one surface that has to survive being
/// attacked, which is the opposite of what a rate limiter is for.
pub const Unauthenticated = struct {
    buckets: [plan.control_address_buckets]Bucket = @splat(.{}),
    global: Bucket = .{},
    /// Randomised per process, so collisions cannot be aimed.
    ///
    /// Sharing a bucket makes the limit stricter, so a collision does not help an attacker
    /// get *through* — but with a fixed seed it would let one pick an address that collides
    /// with a chosen victim and exhaust the victim's bucket on their behalf. A random seed
    /// makes that unaimable, which is cheaper than any structural defence.
    seed: u64,

    /// Counts requests refused by each mechanism, so the two are distinguishable in
    /// `/admin/stats` (M5). "The surface is being attacked" and "one client is looping"
    /// need different operator responses, and a single counter cannot tell them apart.
    address_rejections: u64 = 0,
    global_rejections: u64 = 0,

    pub fn init() storage.os.Error!Unauthenticated {
        var seed_bytes: [8]u8 = undefined;
        try storage.os.getRandom(&seed_bytes);
        return .{ .seed = std.mem.readInt(u64, &seed_bytes, .little) };
    }

    /// Deterministic construction, for tests that need reproducible bucket placement.
    pub fn initSeeded(seed: u64) Unauthenticated {
        return .{ .seed = seed };
    }

    fn index(self: *const Unauthenticated, address: []const u8) usize {
        const h = std.hash.Wyhash.hash(self.seed, address);
        return @intCast(h % plan.control_address_buckets);
    }

    /// Takes one token for `address`.
    ///
    /// **The global ceiling is charged first, and charged even when the address bucket then
    /// refuses.** Order matters: if the address bucket were charged first and returned
    /// early, an attacker rotating addresses would never touch the global bucket at all —
    /// which is precisely the case the global bucket exists for. So both are always
    /// charged, and the caller is refused if either says no.
    ///
    /// Returns the decision whose headers a handler should emit, which is the *refusing*
    /// one when there is one, because that is the wait the client actually faces.
    pub fn take(self: *Unauthenticated, address: []const u8, now: u32) Decision {
        const g = self.global.take(
            now,
            plan.control_global_rate_per_min,
            plan.control_global_burst,
            plan.controlGlobalRefillPerSecond(),
        );

        const a = self.buckets[self.index(address)].take(
            now,
            plan.control_unauth_rate_per_min,
            plan.control_unauth_burst,
            plan.controlUnauthRefillPerSecond(),
        );

        if (!g.allowed) {
            self.global_rejections += 1;
            // The global limit is reported under the per-address limit's numbers, because
            // publishing the global capacity would tell a caller how much headroom the
            // whole surface has left — which is a number an attacker can use and a
            // legitimate client has no use for.
            return .{
                .allowed = false,
                .limit = plan.control_unauth_rate_per_min,
                .remaining = 0,
                .reset_s = g.reset_s,
                .retry_after_s = @max(1, g.retry_after_s),
            };
        }
        if (!a.allowed) {
            self.address_rejections += 1;
            return a;
        }
        return a;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "a fresh bucket is full, and the burst is spendable at once" {
    var b: Bucket = .{};
    const now: u32 = 1_700_000_000;

    var taken: u32 = 0;
    while (b.take(now, 20, 20, 20.0 / 60.0).allowed) : (taken += 1) {}
    try testing.expectEqual(@as(u32, 20), taken);
}

test "an empty bucket refills at the sustained rate" {
    var b: Bucket = .{};
    var now: u32 = 1_700_000_000;
    const per_s = 20.0 / 60.0;

    while (b.take(now, 20, 20, per_s).allowed) {}
    // 20 per minute is one token every three seconds.
    now += 3;
    try testing.expect(b.take(now, 20, 20, per_s).allowed);
    try testing.expect(!b.take(now, 20, 20, per_s).allowed);
}

test "retry-after is rounded up, so honouring it does not earn a second refusal" {
    var b: Bucket = .{};
    const now: u32 = 1_700_000_000;
    const per_s = 20.0 / 60.0;
    while (b.take(now, 20, 20, per_s).allowed) {}

    const d = b.take(now, 20, 20, per_s);
    try testing.expect(!d.allowed);
    try testing.expectEqual(@as(u32, 3), d.retry_after_s);
}

test "a clock stepping backwards grants nothing and does not underflow" {
    var b: Bucket = .{};
    const per_s = 20.0 / 60.0;
    var now: u32 = 1_700_000_000;
    while (b.take(now, 20, 20, per_s).allowed) {}

    now -= 10_000;
    try testing.expect(!b.take(now, 20, 20, per_s).allowed);
}

test "two addresses get their own buckets" {
    var u = Unauthenticated.initSeeded(1);
    const now: u32 = 1_700_000_000;

    var taken: u32 = 0;
    while (u.take("1.2.3.4", now).allowed) : (taken += 1) {}
    try testing.expectEqual(plan.control_unauth_burst, taken);

    // A different address is unaffected, which is the whole point of the table.
    try testing.expect(u.take("5.6.7.8", now).allowed);
}

test "the global ceiling refuses even a fresh address" {
    var u = Unauthenticated.initSeeded(2);
    const now: u32 = 1_700_000_000;

    // Spend the global budget across many distinct addresses, so no address bucket is ever
    // the thing that refuses. This is the attack the global bucket exists for: rotating the
    // address defeats a per-address limit completely.
    var buf: [32]u8 = undefined;
    var i: u32 = 0;
    var allowed: u32 = 0;
    while (i < plan.control_global_burst + 50) : (i += 1) {
        const addr = std.fmt.bufPrint(&buf, "10.0.{d}.{d}", .{ i / 256, i % 256 }) catch unreachable;
        if (u.take(addr, now).allowed) allowed += 1;
    }
    try testing.expectEqual(plan.control_global_burst, allowed);
    try testing.expect(u.global_rejections > 0);

    // And a brand-new address is still refused, because the surface as a whole is spent.
    try testing.expect(!u.take("192.168.1.1", now).allowed);
}

test "the global bucket is charged even when the address bucket refuses" {
    // If the address bucket short-circuited, an attacker hammering one address would never
    // touch the global bucket — and one rotating addresses would never be caught by it.
    var u = Unauthenticated.initSeeded(3);
    const now: u32 = 1_700_000_000;

    var i: u32 = 0;
    while (i < plan.control_unauth_burst * 3) : (i += 1) _ = u.take("1.1.1.1", now);

    // Well past the address burst, so most of those were refusals — and each still spent a
    // global token.
    try testing.expect(u.address_rejections > 0);
    try testing.expect(u.global.tokens <
        @as(f64, @floatFromInt(plan.control_global_burst)) -
        @as(f64, @floatFromInt(plan.control_unauth_burst)));
}

test "a refusal does not advertise how much the whole surface has left" {
    var u = Unauthenticated.initSeeded(4);
    const now: u32 = 1_700_000_000;

    var buf: [32]u8 = undefined;
    var i: u32 = 0;
    while (i < plan.control_global_burst + 5) : (i += 1) {
        const addr = std.fmt.bufPrint(&buf, "10.1.{d}.{d}", .{ i / 256, i % 256 }) catch unreachable;
        _ = u.take(addr, now);
    }

    const d = u.take("172.16.0.1", now);
    try testing.expect(!d.allowed);
    // Reported under the per-address numbers: the global capacity is a figure an attacker
    // can use and a legitimate client cannot.
    try testing.expectEqual(plan.control_unauth_rate_per_min, d.limit);
    try testing.expectEqual(@as(u32, 0), d.remaining);
    try testing.expect(d.retry_after_s >= 1);
}

test "the two rejection counters are distinguishable" {
    // "The surface is being attacked" and "one client is looping" need different operator
    // responses, so one counter could not serve both (M5's /admin/stats).
    var u = Unauthenticated.initSeeded(5);
    const now: u32 = 1_700_000_000;

    var i: u32 = 0;
    while (i < plan.control_unauth_burst + 10) : (i += 1) _ = u.take("9.9.9.9", now);
    try testing.expect(u.address_rejections >= 10);
    try testing.expectEqual(@as(u64, 0), u.global_rejections);
}

test "collisions make the limit stricter, never looser" {
    // The table is lossy by design. What must never happen is a collision letting a caller
    // through — so find two addresses in one bucket and check the burst is shared, not
    // doubled.
    var u = Unauthenticated.initSeeded(7);
    const now: u32 = 1_700_000_000;

    var buf_a: [32]u8 = undefined;
    var buf_b: [32]u8 = undefined;
    const first = std.fmt.bufPrint(&buf_a, "203.0.113.1", .{}) catch unreachable;
    const target = u.index(first);

    var found: ?[]const u8 = null;
    var i: u32 = 2;
    while (i < 60_000) : (i += 1) {
        const cand = std.fmt.bufPrint(&buf_b, "203.0.{d}.{d}", .{ i / 256, i % 256 }) catch unreachable;
        if (u.index(cand) == target and !std.mem.eql(u8, cand, first)) {
            found = cand;
            break;
        }
    }
    const second = found orelse return error.SkipZigTest;

    var taken: u32 = 0;
    while (u.take(first, now).allowed) : (taken += 1) {}
    // The colliding address finds the bucket already empty: stricter for both, which is the
    // safe direction.
    try testing.expect(!u.take(second, now).allowed);
    try testing.expectEqual(plan.control_unauth_burst, taken);
}

test "the seed is randomised per process, so collisions cannot be aimed" {
    const a = try Unauthenticated.init();
    const b = try Unauthenticated.init();
    // With a fixed seed an attacker could pick an address colliding with a chosen victim
    // and exhaust the victim's bucket for them.
    try testing.expect(a.seed != b.seed);
}

test "the limits are the ones D74 settled" {
    try testing.expectEqual(@as(u32, 20), plan.control_unauth_rate_per_min);
    try testing.expectEqual(@as(u32, 600), plan.control_global_rate_per_min);
    try testing.expectEqual(@as(u32, 300), plan.control_rate_per_min);
    try testing.expectEqual(@as(usize, 4096), plan.control_address_buckets);
    // The table has to be a power of two for the modulo to be cheap and uniform-ish; more
    // importantly it must be fixed, which is what stops it being grown by an attacker.
    try testing.expect(std.math.isPowerOfTwo(plan.control_address_buckets));
}

test "the fixed table is the whole memory cost" {
    // A map that allocated per address would be a memory-exhaustion vector on the one
    // surface that has to survive being attacked. 4096 buckets is 64 KiB.
    const bytes = @sizeOf(Unauthenticated);
    try testing.expect(bytes < 128 * 1024);
    try testing.expectEqual(@as(usize, 16), @sizeOf(Bucket));
}
