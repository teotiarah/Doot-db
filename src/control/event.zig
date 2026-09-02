//! Control-plane event framing.
//!
//! The unit in this log is an **event**, not a record: D2 reserves "record" as a
//! banned synonym for *entry*, and `storage/record.zig` already uses it for the
//! physical framing of one.
//!
//! ```
//! offset  size  field
//!   0       4   length      total bytes including this header
//!   4       1   type
//!   5       1   version
//!   6       2   reserved
//!   8       4   crc32c      over bytes 0..7 and 12..length
//!  12       …   payload
//! ```
//!
//! **The checksum covers the framing, not just the payload** — the same defect D32
//! found in the record format. `length` is what replay uses to find the next event,
//! so a single corrupted length byte would walk the scan into garbage with nothing
//! to detect it. Verification is ordered for the same reason: bounds-check the
//! length first, because it cannot be trusted before the checksum, and the checksum
//! cannot be computed without it.
//!
//! Every event carries its own `version`, which is the mechanism by which M3 added
//! signup, sessions and identity anchors without migrating anything: new types took
//! unused numbers, and a changed payload takes a new version of its own type.
//!
//! **There is deliberately no `otp_issued`, and this file used to promise one.** D70
//! settled the durability question per kind of state, and an OTP challenge lives ten
//! minutes, is single-use, and costs a resend if it is lost — so it stays in RAM with
//! the OAuth `state` values, and neither appears here. The rule that decided it: the
//! log holds what must survive a restart and cannot be reconstructed, and anything
//! written per request would make the log grow with traffic, which D41 already refused
//! for credits.

const std = @import("std");
const crc32c = @import("storage").crc32c;

pub const header_bytes: u32 = 12;
const crc_offset: usize = 8;

/// 06-auth.md caps a key label at 64 characters.
pub const max_label_bytes: u8 = 64;

/// RFC 5321's practical ceiling on an address. Not a Doot limit — simply the
/// largest thing that can be a real email address.
pub const max_email_bytes: u16 = 254;

/// A PHC string for the D71 parameters — `$argon2id$v=19$m=19456,t=2,p=1$<22>$<43>`
/// — is 96 bytes. The ceiling is generous because D71 expects the parameters to be
/// *raised* once M5 measures them on real hardware, and a stored hash records the
/// parameters it was made with: a tighter bound here would turn a parameter change
/// into a log-format change.
pub const max_phc_bytes: u16 = 192;

pub const Error = error{
    BadLength,
    BadChecksum,
    Malformed,
    Truncated,
    UnknownEventType,
    UnsupportedEventVersion,
};

/// Numbering is append-only and permanent: nothing here is ever renumbered or
/// reused, because a replayed log from an older build must keep meaning what it
/// meant. 1–4 are M2's; 5–12 are M3's, fixed by D70.
pub const Type = enum(u8) {
    account_created = 1,
    credits_checkpoint = 2,
    key_created = 3,
    key_revoked = 4,
    password_set = 5,
    session_created = 6,
    session_revoked = 7,
    sessions_checkpoint = 8,
    anchor_claimed = 9,
    github_linked = 10,
    account_activated = 11,
    account_deleted = 12,
};

/// A type byte this build does not know is refused, not guessed at: it means the log
/// was written by a newer build, and inventing a meaning for it would be worse than
/// declining to start.
fn typeFrom(v: u8) ?Type {
    inline for (@typeInfo(Type).@"enum".fields) |f| {
        if (f.value == v) return @enumFromInt(v);
    }
    return null;
}

pub const Plan = enum(u8) { trial = 0, paid = 1 };

/// `pending_verification` exists because the auth path must refuse an account that
/// has not completed verification. Only M3's email signup creates one.
pub const AccountState = enum(u8) { pending_verification = 0, active = 1 };

pub const AccountCreated = struct {
    account_id: u32,
    created_at: u32,
    credits_granted: u32,
    plan: Plan,
    state: AccountState,
    email: []const u8,

    pub fn payloadLen(e: AccountCreated) u32 {
        return 16 + @as(u32, @intCast(e.email.len));
    }
};

/// Absolute balance, never a delta (D41). Replay takes the last one seen, so a
/// duplicated or partially applied checkpoint cannot compound, and the log does not
/// grow with write volume.
pub const CreditsCheckpoint = struct {
    account_id: u32,
    credits_remaining: u32,

    pub fn payloadLen(_: CreditsCheckpoint) u32 {
        return 8;
    }
};

pub const KeyCreated = struct {
    key_id: u32,
    account_id: u32,
    created_at: u32,
    /// SHA-256 of the plaintext key. The plaintext is never stored — 190 bits of
    /// uniform randomness has no dictionary to attack, so a slow KDF would buy
    /// nothing and cost latency on a credential checked every request (D21).
    hash: [32]u8,
    label: []const u8,

    pub fn payloadLen(e: KeyCreated) u32 {
        return 45 + @as(u32, @intCast(e.label.len));
    }
};

pub const KeyRevoked = struct {
    key_id: u32,

    pub fn payloadLen(_: KeyRevoked) u32 {
        return 4;
    }
};

/// Which identity a trial grant was claimed against (D72, `06-auth.md`).
///
/// The grant is bound to **both** anchors, so a new account matching either one
/// activates with zero credits. Two kinds rather than one combined value, because a
/// GitHub signup has no verified email at the moment it claims, and an email signup
/// has no GitHub id ever.
pub const AnchorKind = enum(u8) { email = 0, github = 1 };

/// Last-one-wins on replay, which is what an append-only log gives for free — so a
/// password change is one more append rather than a rewrite. Separate from
/// `account_created` because an account is created once and a password changes.
pub const PasswordSet = struct {
    account_id: u32,
    set_at: u32,
    /// PHC string, carrying the Argon2id parameters it was made with (D71). Storing
    /// them per hash is what lets the parameters be raised later without
    /// invalidating every existing password.
    phc: []const u8,

    pub fn payloadLen(e: PasswordSet) u32 {
        return 10 + @as(u32, @intCast(e.phc.len));
    }
};

/// Creation is logged; the **sliding refresh is not** (D70). It rides
/// `sessions_checkpoint` instead, because logging it would mean a log write per
/// dashboard request.
pub const SessionCreated = struct {
    session_id: u32,
    account_id: u32,
    /// SHA-256 of the opaque token. The token itself is a credential and is never
    /// stored, exactly as with an API key.
    token_hash: [32]u8,
    created_at: u32,
    expires_at: u32,

    pub fn payloadLen(_: SessionCreated) u32 {
        return 48;
    }
};

pub const SessionRevoked = struct {
    session_id: u32,

    pub fn payloadLen(_: SessionRevoked) u32 {
        return 4;
    }
};

/// The batched sliding expiry.
///
/// A separate type from `credits_checkpoint` rather than one generalised checkpoint
/// carrying a discriminator: the two have different payloads, different cadences and
/// **opposite recovery directions** — a credit checkpoint is taken as authoritative,
/// a session checkpoint is taken only if it is *earlier* than the log's expiry, because
/// a crash may shorten a credential and never extend one (D70).
pub const SessionsCheckpoint = struct {
    session_id: u32,
    expires_at: u32,

    pub fn payloadLen(_: SessionsCheckpoint) u32 {
        return 8;
    }
};

/// Outlives the account it belongs to (`06-auth.md`), which is why it is a claim on
/// an anchor rather than a field on an account: `account_deleted` must not remove it,
/// or the trial grant could be re-farmed by delete-and-resignup.
pub const AnchorClaimed = struct {
    kind: AnchorKind,
    /// SHA-256 of the normalised anchor. Only the digest, because the only operation
    /// is equality and storing the normalised address in the clear would mean holding
    /// a second copy of everyone's email for no extra capability (D72).
    hash: [32]u8,
    account_id: u32,

    pub fn payloadLen(_: AnchorClaimed) u32 {
        return 37;
    }
};

pub const GithubLinked = struct {
    account_id: u32,
    /// The numeric user id, never the username: usernames can be changed and reused,
    /// so anchoring on one would let an identity be handed to somebody else.
    github_user_id: u64,

    pub fn payloadLen(_: GithubLinked) u32 {
        return 12;
    }
};

/// The `pending_verification` → `active` transition, and the moment credits are
/// granted.
///
/// Carries the granted figure rather than leaving it implied, because the amount
/// depends on anchor evaluation at the time and a replay must reproduce what was
/// actually granted — not re-derive it from anchors that have since changed.
pub const AccountActivated = struct {
    account_id: u32,
    credits_granted: u32,

    pub fn payloadLen(_: AccountActivated) u32 {
        return 8;
    }
};

/// A tombstone, so a replay cannot resurrect a deleted account.
///
/// Deletion revokes access and does **not** delete entries: the index stores no names,
/// so nothing can enumerate an account's entries, and the bytes leave with their expiry
/// instead (D77).
pub const AccountDeleted = struct {
    account_id: u32,
    deleted_at: u32,

    pub fn payloadLen(_: AccountDeleted) u32 {
        return 8;
    }
};

pub const Payload = union(Type) {
    account_created: AccountCreated,
    credits_checkpoint: CreditsCheckpoint,
    key_created: KeyCreated,
    key_revoked: KeyRevoked,
    password_set: PasswordSet,
    session_created: SessionCreated,
    session_revoked: SessionRevoked,
    sessions_checkpoint: SessionsCheckpoint,
    anchor_claimed: AnchorClaimed,
    github_linked: GithubLinked,
    account_activated: AccountActivated,
    account_deleted: AccountDeleted,

    /// `inline else` rather than twelve identical arms: because this is a
    /// `union(Type)`, adding a `Type` without a payload here is a compile error, so
    /// exhaustiveness is already guaranteed by the declaration and spelling it out
    /// twelve times would only be twelve places to make a typo.
    pub fn encodedLen(p: Payload) u32 {
        return header_bytes + switch (p) {
            inline else => |e| e.payloadLen(),
        };
    }
};

/// Writes one framed event into `out`, which must be at least `encodedLen`.
pub fn encode(p: Payload, out: []u8) Error![]u8 {
    const len = p.encodedLen();
    if (out.len < len) return error.BadLength;
    const buf = out[0..len];
    @memset(buf, 0);

    w32(buf, 0, len);
    buf[4] = @intFromEnum(std.meta.activeTag(p));
    buf[5] = 1; // version

    const body = buf[header_bytes..];
    switch (p) {
        .account_created => |e| {
            w32(body, 0, e.account_id);
            w32(body, 4, e.created_at);
            w32(body, 8, e.credits_granted);
            body[12] = @intFromEnum(e.plan);
            body[13] = @intFromEnum(e.state);
            w16(body, 14, @intCast(e.email.len));
            @memcpy(body[16..][0..e.email.len], e.email);
        },
        .credits_checkpoint => |e| {
            w32(body, 0, e.account_id);
            w32(body, 4, e.credits_remaining);
        },
        .key_created => |e| {
            w32(body, 0, e.key_id);
            w32(body, 4, e.account_id);
            w32(body, 8, e.created_at);
            @memcpy(body[12..][0..32], &e.hash);
            body[44] = @intCast(e.label.len);
            @memcpy(body[45..][0..e.label.len], e.label);
        },
        .key_revoked => |e| w32(body, 0, e.key_id),
        .password_set => |e| {
            w32(body, 0, e.account_id);
            w32(body, 4, e.set_at);
            w16(body, 8, @intCast(e.phc.len));
            @memcpy(body[10..][0..e.phc.len], e.phc);
        },
        .session_created => |e| {
            w32(body, 0, e.session_id);
            w32(body, 4, e.account_id);
            @memcpy(body[8..][0..32], &e.token_hash);
            w32(body, 40, e.created_at);
            w32(body, 44, e.expires_at);
        },
        .session_revoked => |e| w32(body, 0, e.session_id),
        .sessions_checkpoint => |e| {
            w32(body, 0, e.session_id);
            w32(body, 4, e.expires_at);
        },
        .anchor_claimed => |e| {
            body[0] = @intFromEnum(e.kind);
            @memcpy(body[1..][0..32], &e.hash);
            w32(body, 33, e.account_id);
        },
        .github_linked => |e| {
            w32(body, 0, e.account_id);
            w64(body, 4, e.github_user_id);
        },
        .account_activated => |e| {
            w32(body, 0, e.account_id);
            w32(body, 4, e.credits_granted);
        },
        .account_deleted => |e| {
            w32(body, 0, e.account_id);
            w32(body, 4, e.deleted_at);
        },
    }

    w32(buf, crc_offset, checksum(buf));
    return buf;
}

/// Total length of the event starting at `header`, bounds-checked before it is
/// trusted as a length.
pub fn peekLength(header: []const u8) Error!u32 {
    if (header.len < header_bytes) return error.Truncated;
    const len = r32(header, 0);
    if (len < header_bytes or len > max_event_bytes) return error.BadLength;
    return len;
}

/// The largest any event can be, so `peekLength` can reject a corrupt length
/// without ever using it.
///
/// Computed as the maximum over the types rather than as a sum of the widest fields.
/// The previous form added `max_label_bytes` and `max_email_bytes` together even though
/// no event carries both, which made the bound 375 where the true one is 282 — harmless,
/// but a looser bound than necessary is a wider corrupt length accepted before the
/// checksum gets a chance to reject it. D70 asked for it recomputed rather than nudged
/// as M3's types landed, and a test below pins it to the real maximum so the two cannot
/// drift.
pub const max_event_bytes: u32 = header_bytes + max_payload_bytes;

const max_payload_bytes: u32 = blk: {
    const sizes = [_]u32{
        16 + @as(u32, max_email_bytes), // account_created
        8, // credits_checkpoint
        45 + @as(u32, max_label_bytes), // key_created
        4, // key_revoked
        10 + @as(u32, max_phc_bytes), // password_set
        48, // session_created
        4, // session_revoked
        8, // sessions_checkpoint
        37, // anchor_claimed
        12, // github_linked
        8, // account_activated
        8, // account_deleted
    };
    var m: u32 = 0;
    for (sizes) |s| m = @max(m, s);
    break :blk m;
};

/// Decoded payload borrows `buf`; the caller copies anything it intends to keep.
pub fn decode(buf: []const u8) Error!Payload {
    const len = try peekLength(buf);
    if (buf.len < len) return error.Truncated;
    const ev = buf[0..len];

    if (r32(ev, crc_offset) != checksum(ev)) return error.BadChecksum;

    const version = ev[5];
    if (version != 1) return error.UnsupportedEventVersion;

    const body = ev[header_bytes..];
    return switch (typeFrom(ev[4]) orelse return error.UnknownEventType) {
        .account_created => blk: {
            if (body.len < 16) return error.Malformed;
            const email_len = r16(body, 14);
            if (email_len == 0 or email_len > max_email_bytes) return error.Malformed;
            if (body.len != 16 + @as(usize, email_len)) return error.Malformed;
            break :blk .{ .account_created = .{
                .account_id = r32(body, 0),
                .created_at = r32(body, 4),
                .credits_granted = r32(body, 8),
                .plan = try enumFrom(Plan, body[12]),
                .state = try enumFrom(AccountState, body[13]),
                .email = body[16..][0..email_len],
            } };
        },
        .credits_checkpoint => blk: {
            if (body.len != 8) return error.Malformed;
            break :blk .{ .credits_checkpoint = .{
                .account_id = r32(body, 0),
                .credits_remaining = r32(body, 4),
            } };
        },
        .key_created => blk: {
            if (body.len < 45) return error.Malformed;
            const label_len = body[44];
            if (label_len > max_label_bytes) return error.Malformed;
            if (body.len != 45 + @as(usize, label_len)) return error.Malformed;
            var e: KeyCreated = .{
                .key_id = r32(body, 0),
                .account_id = r32(body, 4),
                .created_at = r32(body, 8),
                .hash = undefined,
                .label = body[45..][0..label_len],
            };
            @memcpy(&e.hash, body[12..][0..32]);
            break :blk .{ .key_created = e };
        },
        .key_revoked => blk: {
            if (body.len != 4) return error.Malformed;
            break :blk .{ .key_revoked = .{ .key_id = r32(body, 0) } };
        },
        .password_set => blk: {
            if (body.len < 10) return error.Malformed;
            const phc_len = r16(body, 8);
            if (phc_len == 0 or phc_len > max_phc_bytes) return error.Malformed;
            if (body.len != 10 + @as(usize, phc_len)) return error.Malformed;
            break :blk .{ .password_set = .{
                .account_id = r32(body, 0),
                .set_at = r32(body, 4),
                .phc = body[10..][0..phc_len],
            } };
        },
        .session_created => blk: {
            if (body.len != 48) return error.Malformed;
            var e: SessionCreated = .{
                .session_id = r32(body, 0),
                .account_id = r32(body, 4),
                .token_hash = undefined,
                .created_at = r32(body, 40),
                .expires_at = r32(body, 44),
            };
            @memcpy(&e.token_hash, body[8..][0..32]);
            break :blk .{ .session_created = e };
        },
        .session_revoked => blk: {
            if (body.len != 4) return error.Malformed;
            break :blk .{ .session_revoked = .{ .session_id = r32(body, 0) } };
        },
        .sessions_checkpoint => blk: {
            if (body.len != 8) return error.Malformed;
            break :blk .{ .sessions_checkpoint = .{
                .session_id = r32(body, 0),
                .expires_at = r32(body, 4),
            } };
        },
        .anchor_claimed => blk: {
            if (body.len != 37) return error.Malformed;
            var e: AnchorClaimed = .{
                .kind = try enumFrom(AnchorKind, body[0]),
                .hash = undefined,
                .account_id = r32(body, 33),
            };
            @memcpy(&e.hash, body[1..][0..32]);
            break :blk .{ .anchor_claimed = e };
        },
        .github_linked => blk: {
            if (body.len != 12) return error.Malformed;
            break :blk .{ .github_linked = .{
                .account_id = r32(body, 0),
                .github_user_id = r64(body, 4),
            } };
        },
        .account_activated => blk: {
            if (body.len != 8) return error.Malformed;
            break :blk .{ .account_activated = .{
                .account_id = r32(body, 0),
                .credits_granted = r32(body, 4),
            } };
        },
        .account_deleted => blk: {
            if (body.len != 8) return error.Malformed;
            break :blk .{ .account_deleted = .{
                .account_id = r32(body, 0),
                .deleted_at = r32(body, 4),
            } };
        },
    };
}

fn enumFrom(comptime E: type, v: u8) Error!E {
    inline for (@typeInfo(E).@"enum".fields) |f| {
        if (f.value == v) return @enumFromInt(v);
    }
    return error.Malformed;
}

/// Everything except the four checksum bytes themselves.
fn checksum(ev: []const u8) u32 {
    var c = crc32c.Crc32c.init();
    c.update(ev[0..crc_offset]);
    c.update(ev[crc_offset + 4 ..]);
    return c.final();
}

fn w16(b: []u8, off: usize, v: u16) void {
    std.mem.writeInt(u16, b[off..][0..2], v, .little);
}
fn w32(b: []u8, off: usize, v: u32) void {
    std.mem.writeInt(u32, b[off..][0..4], v, .little);
}
fn w64(b: []u8, off: usize, v: u64) void {
    std.mem.writeInt(u64, b[off..][0..8], v, .little);
}
fn r16(b: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, b[off..][0..2], .little);
}
fn r32(b: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, b[off..][0..4], .little);
}
fn r64(b: []const u8, off: usize) u64 {
    return std.mem.readInt(u64, b[off..][0..8], .little);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// `buf` comes from the caller because a decoded payload **borrows** it. Returning a
/// `Payload` that pointed into this function's own frame is precisely the bug M1 hit
/// with `record.decode`, and it is worth the extra parameter to make it
/// unrepresentable.
fn roundTrip(p: Payload, buf: []u8) !Payload {
    const bytes = try encode(p, buf);
    try testing.expectEqual(p.encodedLen(), @as(u32, @intCast(bytes.len)));
    return decode(bytes);
}

test "an account round-trips" {
    const in: Payload = .{ .account_created = .{
        .account_id = 42,
        .created_at = 1_700_000_000,
        .credits_granted = 10_000,
        .plan = .trial,
        .state = .active,
        .email = "someone@example.com",
    } };
    var buf: [max_event_bytes]u8 = undefined;
    const out = (try roundTrip(in, &buf)).account_created;
    try testing.expectEqual(@as(u32, 42), out.account_id);
    try testing.expectEqual(@as(u32, 10_000), out.credits_granted);
    try testing.expectEqual(Plan.trial, out.plan);
    try testing.expectEqual(AccountState.active, out.state);
    try testing.expectEqualStrings("someone@example.com", out.email);
}

test "a credits checkpoint round-trips" {
    var buf: [max_event_bytes]u8 = undefined;
    const out = (try roundTrip(.{ .credits_checkpoint = .{
        .account_id = 7,
        .credits_remaining = 9_187,
    } }, &buf)).credits_checkpoint;
    try testing.expectEqual(@as(u32, 7), out.account_id);
    try testing.expectEqual(@as(u32, 9_187), out.credits_remaining);
}

test "a key round-trips, including an empty label" {
    var hash: [32]u8 = undefined;
    for (&hash, 0..) |*b, i| b.* = @intCast(i);

    var buf: [max_event_bytes]u8 = undefined;
    const out = (try roundTrip(.{ .key_created = .{
        .key_id = 3,
        .account_id = 42,
        .created_at = 99,
        .hash = hash,
        .label = "ci-runner",
    } }, &buf)).key_created;
    try testing.expectEqual(@as(u32, 3), out.key_id);
    try testing.expectEqualSlices(u8, &hash, &out.hash);
    try testing.expectEqualStrings("ci-runner", out.label);

    var bare_buf: [max_event_bytes]u8 = undefined;
    const bare = (try roundTrip(.{ .key_created = .{
        .key_id = 4,
        .account_id = 1,
        .created_at = 1,
        .hash = hash,
        .label = "",
    } }, &bare_buf)).key_created;
    try testing.expectEqualStrings("", bare.label);
}

test "a revocation round-trips" {
    var buf: [max_event_bytes]u8 = undefined;
    const out = (try roundTrip(.{ .key_revoked = .{ .key_id = 11 } }, &buf)).key_revoked;
    try testing.expectEqual(@as(u32, 11), out.key_id);
}

/// One representative of every event type.
///
/// A `switch` over `Type` with no `else`, so **adding a type is a compile error until it
/// has a sample** — which is what makes the exhaustive sweeps below stay exhaustive. A
/// list that has to be remembered is a list that goes stale exactly when it matters.
fn sample(t: Type) Payload {
    const digest: [32]u8 = @splat(0x5A);
    return switch (t) {
        .account_created => .{ .account_created = .{
            .account_id = 0x1122_3344,
            .created_at = 0x5566_7788,
            .credits_granted = 10_000,
            .plan = .trial,
            .state = .pending_verification,
            .email = "someone@example.com",
        } },
        .credits_checkpoint => .{ .credits_checkpoint = .{
            .account_id = 7,
            .credits_remaining = 9_187,
        } },
        .key_created => .{ .key_created = .{
            .key_id = 3,
            .account_id = 42,
            .created_at = 99,
            .hash = digest,
            .label = "ci-runner",
        } },
        .key_revoked => .{ .key_revoked = .{ .key_id = 11 } },
        .password_set => .{ .password_set = .{
            .account_id = 42,
            .set_at = 1_700_000_000,
            .phc = "$argon2id$v=19$m=19456,t=2,p=1$c29tZXNhbHRzb21lc2FsdA$" ++
                "aGFzaGhhc2hoYXNoaGFzaGhhc2hoYXNoaGFzaGhhc2g",
        } },
        .session_created => .{ .session_created = .{
            .session_id = 5,
            .account_id = 42,
            .token_hash = digest,
            .created_at = 1_700_000_000,
            .expires_at = 1_700_000_000 + 30 * 24 * 60 * 60,
        } },
        .session_revoked => .{ .session_revoked = .{ .session_id = 5 } },
        .sessions_checkpoint => .{ .sessions_checkpoint = .{
            .session_id = 5,
            .expires_at = 1_800_000_000,
        } },
        .anchor_claimed => .{ .anchor_claimed = .{
            .kind = .github,
            .hash = digest,
            .account_id = 42,
        } },
        .github_linked => .{ .github_linked = .{
            .account_id = 42,
            .github_user_id = 0x0102_0304_0506_0708,
        } },
        .account_activated => .{ .account_activated = .{
            .account_id = 42,
            .credits_granted = 10_000,
        } },
        .account_deleted => .{ .account_deleted = .{
            .account_id = 42,
            .deleted_at = 1_700_000_001,
        } },
    };
}

test "every event type round-trips, and decodes back as its own tag" {
    var buf: [max_event_bytes]u8 = undefined;
    inline for (@typeInfo(Type).@"enum".fields) |f| {
        const t: Type = @enumFromInt(f.value);
        const out = try roundTrip(sample(t), &buf);
        try testing.expectEqual(t, std.meta.activeTag(out));
    }
}

test "M3's event numbers are the ones D70 fixed, permanently" {
    // Numbering is append-only and never reused: a replayed log from an older build has
    // to keep meaning what it meant, so these values are a wire format and not an
    // implementation detail.
    try testing.expectEqual(@as(u8, 1), @intFromEnum(Type.account_created));
    try testing.expectEqual(@as(u8, 2), @intFromEnum(Type.credits_checkpoint));
    try testing.expectEqual(@as(u8, 3), @intFromEnum(Type.key_created));
    try testing.expectEqual(@as(u8, 4), @intFromEnum(Type.key_revoked));
    try testing.expectEqual(@as(u8, 5), @intFromEnum(Type.password_set));
    try testing.expectEqual(@as(u8, 6), @intFromEnum(Type.session_created));
    try testing.expectEqual(@as(u8, 7), @intFromEnum(Type.session_revoked));
    try testing.expectEqual(@as(u8, 8), @intFromEnum(Type.sessions_checkpoint));
    try testing.expectEqual(@as(u8, 9), @intFromEnum(Type.anchor_claimed));
    try testing.expectEqual(@as(u8, 10), @intFromEnum(Type.github_linked));
    try testing.expectEqual(@as(u8, 11), @intFromEnum(Type.account_activated));
    try testing.expectEqual(@as(u8, 12), @intFromEnum(Type.account_deleted));
}

test "an OTP challenge has no event type, deliberately" {
    // D70 put OTP and OAuth `state` in RAM: ten-minute lifetimes, single use, and losing
    // one costs a resend. This file used to promise an `otp_issued`; asserting its absence
    // is what stops it being added back without reopening the decision.
    inline for (@typeInfo(Type).@"enum".fields) |f| {
        try testing.expect(!std.mem.startsWith(u8, f.name, "otp"));
    }
}

test "max_event_bytes is exactly the largest event, not a loose sum" {
    // It used to be `header + 45 + max_label + max_email`, which added two fields no
    // single event carries together — 375 against a true 282. A loose bound is a wider
    // corrupt length accepted by `peekLength` before the checksum can reject it.
    var largest: u32 = 0;
    inline for (@typeInfo(Type).@"enum".fields) |f| {
        largest = @max(largest, sample(@enumFromInt(f.value)).encodedLen());
    }
    // The variable-length types at their published ceilings.
    const widest = [_]Payload{
        .{ .account_created = .{
            .account_id = 1,
            .created_at = 1,
            .credits_granted = 1,
            .plan = .paid,
            .state = .active,
            .email = "e" ** max_email_bytes,
        } },
        .{ .key_created = .{
            .key_id = 1,
            .account_id = 1,
            .created_at = 1,
            .hash = @splat(0xAB),
            .label = "l" ** max_label_bytes,
        } },
        .{ .password_set = .{
            .account_id = 1,
            .set_at = 1,
            .phc = "p" ** max_phc_bytes,
        } },
    };
    for (widest) |p| largest = @max(largest, p.encodedLen());

    try testing.expectEqual(max_event_bytes, largest);
    try testing.expectEqual(@as(u32, 282), max_event_bytes);
}

test "every single-bit flip is detected, in every event type" {
    // The existing sweep covered `account_created` only. Extending it across the enum is
    // what makes a new type's framing as well-checked as the original four.
    inline for (@typeInfo(Type).@"enum".fields) |f| {
        const p = sample(@enumFromInt(f.value));
        var original: [max_event_bytes]u8 = undefined;
        const bytes = try encode(p, &original);
        const len = bytes.len;

        var i: usize = 0;
        while (i < len) : (i += 1) {
            var bit: u3 = 0;
            while (true) {
                var flipped: [max_event_bytes]u8 = undefined;
                @memcpy(flipped[0..len], bytes);
                flipped[i] ^= (@as(u8, 1) << bit);

                _ = decode(flipped[0..len]) catch {
                    if (bit == 7) break;
                    bit += 1;
                    continue;
                };
                return error.UndetectedCorruption;
            }
        }
    }
}

test "a fixed-size payload of the wrong length is refused" {
    // Each fixed-size type asserts its exact body length, so a future type whose payload
    // grows cannot be silently misread by a build that predates the change.
    var buf: [max_event_bytes]u8 = undefined;
    const bytes = try encode(sample(.session_created), &buf);

    // Shorten the framed length by four and re-checksum, so only the body-length check
    // stands between this and a bad decode.
    const shortened = bytes.len - 4;
    w32(buf[0..], 0, @intCast(shortened));
    w32(buf[0..], crc_offset, checksum(buf[0..shortened]));
    try testing.expectError(error.Malformed, decode(buf[0..shortened]));
}

test "an anchor kind this build does not know is refused" {
    var buf: [max_event_bytes]u8 = undefined;
    const bytes = try encode(sample(.anchor_claimed), &buf);
    buf[header_bytes] = 9; // a kind from some future build
    w32(buf[0..], crc_offset, checksum(bytes));
    try testing.expectError(error.Malformed, decode(bytes));
}

test "a password hash above the ceiling is refused rather than truncated" {
    var buf: [max_event_bytes]u8 = undefined;
    const bytes = try encode(sample(.password_set), &buf);
    // Claim a phc length beyond the ceiling, keeping the framing self-consistent.
    w16(buf[header_bytes..], 8, max_phc_bytes + 1);
    w32(buf[0..], crc_offset, checksum(bytes));
    try testing.expectError(error.Malformed, decode(bytes));
}

test "maximum-size fields fit the stated ceiling" {
    const p: Payload = .{ .account_created = .{
        .account_id = 1,
        .created_at = 1,
        .credits_granted = 1,
        .plan = .paid,
        .state = .active,
        .email = "e" ** max_email_bytes,
    } };
    try testing.expect(p.encodedLen() <= max_event_bytes);
    var abuf: [max_event_bytes]u8 = undefined;
    _ = try roundTrip(p, &abuf);

    const hash: [32]u8 = @splat(0xAB);
    const k: Payload = .{ .key_created = .{
        .key_id = 1,
        .account_id = 1,
        .created_at = 1,
        .hash = hash,
        .label = "l" ** max_label_bytes,
    } };
    try testing.expect(k.encodedLen() <= max_event_bytes);
    var kbuf: [max_event_bytes]u8 = undefined;
    _ = try roundTrip(k, &kbuf);
}

test "every single-bit flip is detected" {
    // The framing is covered as well as the payload, which is the D32 lesson: a
    // corrupted length is what walks a replay scan into garbage.
    const p: Payload = .{ .account_created = .{
        .account_id = 0x11223344,
        .created_at = 0x55667788,
        .credits_granted = 10_000,
        .plan = .trial,
        .state = .active,
        .email = "a@b.co",
    } };
    var original: [max_event_bytes]u8 = undefined;
    const bytes = try encode(p, &original);
    const len = bytes.len;

    var i: usize = 0;
    while (i < len) : (i += 1) {
        var bit: u3 = 0;
        while (true) {
            var flipped: [max_event_bytes]u8 = undefined;
            @memcpy(flipped[0..len], bytes);
            flipped[i] ^= (@as(u8, 1) << bit);

            // Detected as damage, or refused as a length/type/version this build
            // will not act on. Never silently accepted.
            _ = decode(flipped[0..len]) catch {
                if (bit == 7) break;
                bit += 1;
                continue;
            };
            // The only tolerable survivor would be a flip in the reserved bytes,
            // which the checksum also covers — so nothing should reach here.
            return error.UndetectedCorruption;
        }
    }
}

test "a truncated event is reported as truncated, not decoded" {
    var buf: [max_event_bytes]u8 = undefined;
    const bytes = try encode(.{ .key_revoked = .{ .key_id = 5 } }, &buf);

    try testing.expectError(error.Truncated, decode(bytes[0 .. bytes.len - 1]));
    try testing.expectError(error.Truncated, decode(bytes[0..3]));
}

test "a corrupt length is rejected before it is used" {
    var buf: [max_event_bytes]u8 = undefined;
    const bytes = try encode(.{ .key_revoked = .{ .key_id = 5 } }, &buf);

    w32(buf[0..], 0, 0xFFFF_FFFF);
    try testing.expectError(error.BadLength, peekLength(bytes));

    w32(buf[0..], 0, header_bytes - 1);
    try testing.expectError(error.BadLength, peekLength(bytes));
}

test "an unknown type is refused rather than guessed at" {
    var buf: [max_event_bytes]u8 = undefined;
    const bytes = try encode(.{ .key_revoked = .{ .key_id = 5 } }, &buf);
    buf[4] = 200; // a type from some future build
    w32(buf[0..], crc_offset, checksum(bytes));
    try testing.expectError(error.UnknownEventType, decode(bytes));
}

test "an unsupported version is refused rather than guessed at" {
    var buf: [max_event_bytes]u8 = undefined;
    const bytes = try encode(.{ .key_revoked = .{ .key_id = 5 } }, &buf);
    buf[5] = 2;
    w32(buf[0..], crc_offset, checksum(bytes));
    try testing.expectError(error.UnsupportedEventVersion, decode(bytes));
}
