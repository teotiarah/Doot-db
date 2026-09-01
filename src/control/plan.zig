//! Per-plan limits.
//!
//! Mirrors the Tiers table in `docs/01-product.md`, which stays the source of the
//! numbers. Lives with the control plane because a plan is a property of an account,
//! and accounts are the control plane's business (D56).
//!
//! Three separate things read these and had been about to hardcode them independently:
//! the pooled rate limit needs a bucket size, `GET /v1/whoami` publishes a `limits`
//! object, and `ttl_too_long`'s message promises "the maximum for this plan".

const std = @import("std");
const storage = @import("storage");
const event = @import("event.zig");

const config = storage.config;

pub const Plan = event.Plan;

pub const Limits = struct {
    /// Sustained operations per minute, pooled across every key on the account (D6).
    rate_per_min: u32,
    /// Bucket capacity — how much of the sustained rate may be spent at once.
    burst: u32,
    /// Maximum entry lifetime, or `null` when the plan's ceiling is whatever the store
    /// is configured for. See `maxTtl`.
    max_ttl_s: ?u32,
    /// One-time grant at activation. Zero means the plan does not grant credits.
    granted_credits: u32,

    /// Tokens added per second. The bucket refills at `rate_per_min / 60`, so a caller
    /// may spend the whole burst instantly and then proceeds at the sustained rate
    /// (`01-product.md`).
    pub fn refillPerSecond(l: Limits) f64 {
        return @as(f64, @floatFromInt(l.rate_per_min)) / 60.0;
    }
};

/// The table. Ordered by the enum so a new plan cannot be added without filling it in.
const table = [_]Limits{
    // trial
    .{
        .rate_per_min = 100,
        .burst = 100,
        .max_ttl_s = 14 * 24 * 60 * 60,
        .granted_credits = 10_000,
    },
    // paid (beta)
    .{
        .rate_per_min = 500,
        .burst = 500,
        // Deliberately absent. `01-product.md` states the 30-day figure "is a starting
        // point, not a commitment", that it "moves with observed usage", and that
        // **nothing may hardcode it** — it is `DOOT_MAX_TTL`, and the storage layout
        // derives from it. Writing 30 days here would be the hardcoding that forbids.
        .max_ttl_s = null,
        // Purchased in blocks rather than granted, so there is no figure here.
        .granted_credits = 0,
    },
};

pub fn limits(plan: Plan) Limits {
    return table[@intFromEnum(plan)];
}

/// The effective maximum lifetime for a plan, given what the store is configured for.
///
/// There are two ceilings and the lower one wins: the **engine** ceiling
/// (`Options.max_ttl_s`, which class 3's bound derives from — D10) and the **plan**
/// ceiling from the table above. A plan ceiling above the engine's would be a limit the
/// storage layout cannot honour, so it is clamped here and asserted in the tests rather
/// than being allowed to promise something the engine would refuse.
pub fn maxTtl(plan: Plan, engine_max_ttl_s: u32) u32 {
    const cap = limits(plan).max_ttl_s orelse return engine_max_ttl_s;
    return @min(cap, engine_max_ttl_s);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "the table matches the Tiers table in 01-product.md" {
    const trial = limits(.trial);
    try testing.expectEqual(@as(u32, 100), trial.rate_per_min);
    try testing.expectEqual(@as(u32, 100), trial.burst);
    try testing.expectEqual(@as(u32, 14 * 24 * 60 * 60), trial.max_ttl_s.?);
    try testing.expectEqual(@as(u32, 10_000), trial.granted_credits);

    const paid = limits(.paid);
    try testing.expectEqual(@as(u32, 500), paid.rate_per_min);
    try testing.expectEqual(@as(u32, 500), paid.burst);
    try testing.expect(paid.max_ttl_s == null);
}

test "every plan has an entry" {
    // Adding a variant without a row would otherwise be an out-of-bounds read the first
    // time an account carried it.
    try testing.expectEqual(@typeInfo(Plan).@"enum".fields.len, table.len);
    inline for (@typeInfo(Plan).@"enum".fields) |f| {
        const l = limits(@enumFromInt(f.value));
        try testing.expect(l.rate_per_min > 0);
        try testing.expect(l.burst > 0);
    }
}

test "the paid ceiling follows configuration rather than the table" {
    // The whole point of D56's carve-out: raising DOOT_MAX_TTL raises the paid maximum
    // with no code change.
    try testing.expectEqual(@as(u32, 30 * 24 * 60 * 60), maxTtl(.paid, 30 * 24 * 60 * 60));
    try testing.expectEqual(@as(u32, 90 * 24 * 60 * 60), maxTtl(.paid, 90 * 24 * 60 * 60));
    // And lowering it lowers the plan's ceiling too, because the engine cannot honour
    // more than it is laid out for.
    try testing.expectEqual(@as(u32, 60 * 60), maxTtl(.paid, 60 * 60));
}

test "the trial ceiling is capped by the plan, and by the engine when that is lower" {
    const fourteen_days = 14 * 24 * 60 * 60;
    try testing.expectEqual(@as(u32, fourteen_days), maxTtl(.trial, 30 * 24 * 60 * 60));
    // A generous engine does not raise the trial.
    try testing.expectEqual(@as(u32, fourteen_days), maxTtl(.trial, 365 * 24 * 60 * 60));
    // A mean engine does lower it.
    try testing.expectEqual(@as(u32, 24 * 60 * 60), maxTtl(.trial, 24 * 60 * 60));
}

test "no plan ceiling exceeds the default engine ceiling" {
    // If this fails, the shipped default would advertise a lifetime the storage layout
    // refuses, and the failure would surface as `ttl_too_long` on a value `whoami` had
    // just published as legal.
    const default_engine: u32 = (config.Options{}).max_ttl_s;
    inline for (@typeInfo(Plan).@"enum".fields) |f| {
        const plan: Plan = @enumFromInt(f.value);
        if (limits(plan).max_ttl_s) |cap| try testing.expect(cap <= default_engine);
        // And every effective ceiling is still a legal lifetime.
        try testing.expect(maxTtl(plan, default_engine) >= config.min_ttl_s);
    }
}

test "refill is the sustained rate spread over a minute" {
    try testing.expectApproxEqAbs(@as(f64, 100.0 / 60.0), limits(.trial).refillPerSecond(), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 500.0 / 60.0), limits(.paid).refillPerSecond(), 1e-9);
    // A full bucket refills in exactly the window it is quoted over.
    inline for (@typeInfo(Plan).@"enum".fields) |f| {
        const l = limits(@enumFromInt(f.value));
        const seconds = @as(f64, @floatFromInt(l.burst)) / l.refillPerSecond();
        try testing.expectApproxEqAbs(@as(f64, 60.0), seconds, 1e-9);
    }
}
