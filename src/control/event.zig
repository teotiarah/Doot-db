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
//! Every event carries its own `version`, which is the mechanism by which M3 adds
//! signup, sessions and OTP challenges without migrating anything: new types take
//! unused numbers, and a changed payload takes a new version of its own type.

const std = @import("std");
const crc32c = @import("storage").crc32c;

pub const header_bytes: u32 = 12;
const crc_offset: usize = 8;

/// 06-auth.md caps a key label at 64 characters.
pub const max_label_bytes: u8 = 64;

/// RFC 5321's practical ceiling on an address. Not a Doot limit — simply the
/// largest thing that can be a real email address.
pub const max_email_bytes: u16 = 254;

pub const Error = error{
    BadLength,
    BadChecksum,
    Malformed,
    Truncated,
    UnknownEventType,
    UnsupportedEventVersion,
};

/// Numbering is append-only and permanent. M3 adds `session_created`,
/// `otp_issued`, `anchor_claimed` and friends by taking the next free values;
/// nothing here is ever renumbered or reused, because a replayed log from an older
/// build must keep meaning what it meant.
pub const Type = enum(u8) {
    account_created = 1,
    credits_checkpoint = 2,
    key_created = 3,
    key_revoked = 4,
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

pub const Payload = union(Type) {
    account_created: AccountCreated,
    credits_checkpoint: CreditsCheckpoint,
    key_created: KeyCreated,
    key_revoked: KeyRevoked,

    pub fn encodedLen(p: Payload) u32 {
        return header_bytes + switch (p) {
            .account_created => |e| e.payloadLen(),
            .credits_checkpoint => |e| e.payloadLen(),
            .key_created => |e| e.payloadLen(),
            .key_revoked => |e| e.payloadLen(),
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
pub const max_event_bytes: u32 = header_bytes + 45 + max_label_bytes + max_email_bytes;

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
fn r16(b: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, b[off..][0..2], .little);
}
fn r32(b: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, b[off..][0..4], .little);
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
