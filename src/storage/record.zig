//! Record encoding and verification (docs/04-storage.md).
//!
//! ```
//! offset  size  field
//!   0       4   record_length      total bytes including this header
//!   4       8   seq                global monotonic sequence number
//!  12       4   account_id
//!  16       4   created_at         unix seconds
//!  20       4   expires_at         unix seconds
//!  24       1   flags              bit0 tombstone, bits1-2 class
//!  25       1   name_len_m1        name length minus one: 0..255 encodes 1..256
//!  26       1   tag_count          0..5
//!  27       1   content_type_len   0..128
//!  28       4   body_len           0..262144
//!  32       4   crc32c             over bytes 0..31 and 36..record_length
//!  36       …   name
//!         …     content_type
//!         …     tags: per tag -> 1 byte length, tag bytes, 8 byte prev_chain_ptr
//!         …     body
//! ```
//!
//! Two deliberate properties, both from D32:
//!
//! * The name length is **biased by one**, because names are 1..256 and never
//!   empty. An unbiased byte would cap them at 255 and contradict the data model.
//! * The checksum covers the **header as well as the payload**. `record_length`
//!   and `body_len` are what a recovery scan uses to find the next record, so
//!   leaving them unverified would let one corrupt byte walk the scanner into
//!   garbage undetected.

const std = @import("std");
const config = @import("config.zig");
const Location = @import("location.zig").Location;

const Crc32c = std.hash.crc.Crc32Iscsi;

pub const header_bytes: u32 = 36;
const crc_offset: u32 = 32;

/// Smallest possible record: header plus a one-byte name.
pub const min_record_bytes: u32 = header_bytes + 1;

/// Largest possible record. Bounds-checked before `record_length` is trusted.
pub const max_record_bytes: u32 = header_bytes +
    @as(u32, config.max_name_bytes) +
    @as(u32, config.max_content_type_bytes) +
    @as(u32, config.max_tags) * (1 + @as(u32, config.max_tag_bytes) + 8) +
    config.max_body_bytes;

pub const flag_tombstone: u8 = 1 << 0;

pub const Error = error{
    /// `record_length` outside the possible range. Never used as a length.
    BadLength,
    /// Checksum mismatch: a torn tail during recovery, corruption otherwise.
    BadChecksum,
    /// Field values inconsistent with each other or with the limits.
    Malformed,
    /// Buffer ended before the record did.
    Truncated,
};

pub const Tag = struct {
    text: []const u8,
    /// Previous record carrying this tag in this lifetime class, or `none`.
    prev: Location,
};

/// A record as understood by the engine. Slices borrow from the encode input or
/// the decode buffer; nothing here owns memory.
pub const Record = struct {
    seq: u64,
    account_id: u32,
    created_at: u32,
    expires_at: u32,
    class: config.Class,
    tombstone: bool,
    name: []const u8,
    content_type: []const u8,
    tags: []const Tag,
    body: []const u8,

    pub fn encodedLen(r: Record) u32 {
        var n: u32 = header_bytes;
        n += @intCast(r.name.len);
        n += @intCast(r.content_type.len);
        for (r.tags) |t| n += @intCast(1 + t.text.len + 8);
        n += @intCast(r.body.len);
        return n;
    }
};

fn w32(buf: []u8, off: u32, v: u32) void {
    std.mem.writeInt(u32, buf[off..][0..4], v, .little);
}
fn w64(buf: []u8, off: u32, v: u64) void {
    std.mem.writeInt(u64, buf[off..][0..8], v, .little);
}
fn r32(buf: []const u8, off: u32) u32 {
    return std.mem.readInt(u32, buf[off..][0..4], .little);
}
fn r64(buf: []const u8, off: u32) u64 {
    return std.mem.readInt(u64, buf[off..][0..8], .little);
}

/// Checksum over everything except the four checksum bytes themselves.
fn checksum(buf: []const u8) u32 {
    var c = Crc32c.init();
    c.update(buf[0..crc_offset]);
    c.update(buf[header_bytes..]);
    return c.final();
}

/// Serialises `r` into `out`, which must be at least `r.encodedLen()` bytes.
/// Returns the encoded slice.
pub fn encode(r: Record, out: []u8) Error![]u8 {
    const len = r.encodedLen();
    if (out.len < len) return error.Truncated;
    if (r.name.len < config.min_name_bytes or r.name.len > config.max_name_bytes) return error.Malformed;
    if (r.content_type.len > config.max_content_type_bytes) return error.Malformed;
    if (r.tags.len > config.max_tags) return error.Malformed;
    if (r.body.len > config.max_body_bytes) return error.Malformed;
    for (r.tags) |t| {
        if (t.text.len == 0 or t.text.len > config.max_tag_bytes) return error.Malformed;
    }

    const buf = out[0..len];
    @memset(buf[0..header_bytes], 0);

    w32(buf, 0, len);
    w64(buf, 4, r.seq);
    w32(buf, 12, r.account_id);
    w32(buf, 16, r.created_at);
    w32(buf, 20, r.expires_at);
    buf[24] = (if (r.tombstone) flag_tombstone else 0) | (@as(u8, r.class) << 1);
    buf[25] = @intCast(r.name.len - 1); // biased by one
    buf[26] = @intCast(r.tags.len);
    buf[27] = @intCast(r.content_type.len);
    w32(buf, 28, @intCast(r.body.len));

    var p: u32 = header_bytes;
    @memcpy(buf[p..][0..r.name.len], r.name);
    p += @intCast(r.name.len);
    @memcpy(buf[p..][0..r.content_type.len], r.content_type);
    p += @intCast(r.content_type.len);
    for (r.tags) |t| {
        buf[p] = @intCast(t.text.len);
        p += 1;
        @memcpy(buf[p..][0..t.text.len], t.text);
        p += @intCast(t.text.len);
        w64(buf, p, t.prev.raw);
        p += 8;
    }
    @memcpy(buf[p..][0..r.body.len], r.body);
    p += @intCast(r.body.len);
    std.debug.assert(p == len);

    w32(buf, crc_offset, checksum(buf));
    return buf;
}

/// Reads `record_length` from a header without trusting it, returning it only if
/// it is within the possible range. This is step 2 of the verification order in
/// D32: a length is bounds-checked before it is ever used as a length.
pub fn peekLength(header: []const u8) Error!u32 {
    if (header.len < header_bytes) return error.Truncated;
    const len = r32(header, 0);
    if (len < min_record_bytes or len > max_record_bytes) return error.BadLength;
    return len;
}

/// Verifies and decodes a complete record. `buf` must be exactly the record.
/// Returned slices borrow from `buf`; `tags_out` receives the tag array.
pub fn decode(buf: []const u8, tags_out: *[config.max_tags]Tag) Error!Record {
    if (buf.len < header_bytes) return error.Truncated;
    const len = try peekLength(buf);
    if (buf.len < len) return error.Truncated;
    const rec = buf[0..len];

    if (checksum(rec) != r32(rec, crc_offset)) return error.BadChecksum;

    const flags = rec[24];
    const name_len: u32 = @as(u32, rec[25]) + 1; // undo the bias
    const tag_count: u32 = rec[26];
    const ct_len: u32 = rec[27];
    const body_len = r32(rec, 28);

    if (tag_count > config.max_tags) return error.Malformed;
    if (ct_len > config.max_content_type_bytes) return error.Malformed;
    if (body_len > config.max_body_bytes) return error.Malformed;

    var p: u32 = header_bytes;
    if (p + name_len > len) return error.Malformed;
    const name = rec[p..][0..name_len];
    p += name_len;

    if (p + ct_len > len) return error.Malformed;
    const content_type = rec[p..][0..ct_len];
    p += ct_len;

    var i: u32 = 0;
    while (i < tag_count) : (i += 1) {
        if (p + 1 > len) return error.Malformed;
        const tl: u32 = rec[p];
        p += 1;
        if (tl == 0 or tl > config.max_tag_bytes) return error.Malformed;
        if (p + tl + 8 > len) return error.Malformed;
        tags_out[i] = .{
            .text = rec[p..][0..tl],
            .prev = .{ .raw = r64(rec, p + tl) },
        };
        p += tl + 8;
    }

    if (p + body_len != len) return error.Malformed; // no slack permitted
    const body = rec[p..][0..body_len];

    return .{
        .seq = r64(rec, 4),
        .account_id = r32(rec, 12),
        .created_at = r32(rec, 16),
        .expires_at = r32(rec, 20),
        .class = @intCast((flags >> 1) & 0b11),
        .tombstone = (flags & flag_tombstone) != 0,
        .name = name,
        .content_type = content_type,
        .tags = tags_out[0..tag_count],
        .body = body,
    };
}

// ---------------------------------------------------------------------------

const testing = std.testing;

fn sampleRecord() Record {
    return .{
        .seq = 0xDEAD_BEEF_1234,
        .account_id = 42,
        .created_at = 1_700_000_000,
        .expires_at = 1_700_604_800,
        .class = 2,
        .tombstone = false,
        .name = "ci/last-green-sha",
        .content_type = "application/json",
        .tags = &.{
            .{ .text = "ci", .prev = .{ .raw = 12345 } },
            .{ .text = "main", .prev = @import("location.zig").none },
        },
        .body = "{\"sha\":\"abc123\"}",
    };
}

test "round-trips every field" {
    var buf: [1024]u8 = undefined;
    const orig = sampleRecord();
    const enc = try encode(orig, &buf);

    var tags: [config.max_tags]Tag = undefined;
    const dec = try decode(enc, &tags);

    try testing.expectEqual(orig.seq, dec.seq);
    try testing.expectEqual(orig.account_id, dec.account_id);
    try testing.expectEqual(orig.created_at, dec.created_at);
    try testing.expectEqual(orig.expires_at, dec.expires_at);
    try testing.expectEqual(orig.class, dec.class);
    try testing.expectEqual(orig.tombstone, dec.tombstone);
    try testing.expectEqualStrings(orig.name, dec.name);
    try testing.expectEqualStrings(orig.content_type, dec.content_type);
    try testing.expectEqualStrings(orig.body, dec.body);
    try testing.expectEqual(orig.tags.len, dec.tags.len);
    for (orig.tags, dec.tags) |a, b| {
        try testing.expectEqualStrings(a.text, b.text);
        try testing.expectEqual(a.prev.raw, b.prev.raw);
    }
}

test "a 256-byte name survives, which the unbiased encoding could not have" {
    var buf: [1024]u8 = undefined;
    const name = "x" ** 256;
    var r = sampleRecord();
    r.name = name;
    r.tags = &.{};

    var tags: [config.max_tags]Tag = undefined;
    const dec = try decode(try encode(r, &buf), &tags);
    try testing.expectEqual(@as(usize, 256), dec.name.len);
    try testing.expectEqualStrings(name, dec.name);
}

test "a one-byte name survives too, so the bias is not off by one" {
    var buf: [1024]u8 = undefined;
    var r = sampleRecord();
    r.name = "a";
    r.tags = &.{};

    var tags: [config.max_tags]Tag = undefined;
    const dec = try decode(try encode(r, &buf), &tags);
    try testing.expectEqualStrings("a", dec.name);
}

test "empty body and no tags are valid" {
    var buf: [1024]u8 = undefined;
    var r = sampleRecord();
    r.body = "";
    r.tags = &.{};
    r.content_type = "";

    var tags: [config.max_tags]Tag = undefined;
    const dec = try decode(try encode(r, &buf), &tags);
    try testing.expectEqual(@as(usize, 0), dec.body.len);
    try testing.expectEqual(@as(usize, 0), dec.tags.len);
}

test "corrupting any single byte is detected" {
    var buf: [1024]u8 = undefined;
    const enc = try encode(sampleRecord(), &buf);
    const len = enc.len;

    var i: usize = 0;
    var detected: usize = 0;
    while (i < len) : (i += 1) {
        var copy: [1024]u8 = undefined;
        @memcpy(copy[0..len], enc);
        copy[i] ^= 0xFF;

        var tags: [config.max_tags]Tag = undefined;
        if (decode(copy[0..len], &tags)) |_| {
            // The four checksum bytes are not themselves covered, but flipping
            // one still mismatches, so nothing should decode cleanly.
            std.debug.print("undetected corruption at byte {d}\n", .{i});
            return error.TestUnexpectedResult;
        } else |_| detected += 1;
    }
    try testing.expectEqual(len, detected);
}

test "header corruption is caught, which payload-only coverage would have missed" {
    var buf: [1024]u8 = undefined;
    const enc = try encode(sampleRecord(), &buf);

    // body_len lives at offset 28, inside the header. Under the original spec
    // this field was outside the checksum.
    var copy: [1024]u8 = undefined;
    @memcpy(copy[0..enc.len], enc);
    w32(&copy, 28, 999);

    var tags: [config.max_tags]Tag = undefined;
    try testing.expectError(error.BadChecksum, decode(copy[0..enc.len], &tags));
}

test "an out-of-range length is rejected before being used as a length" {
    var buf: [1024]u8 = undefined;
    const enc = try encode(sampleRecord(), &buf);

    var copy: [1024]u8 = undefined;
    @memcpy(copy[0..enc.len], enc);

    w32(&copy, 0, 0xFFFF_FFFF);
    try testing.expectError(error.BadLength, peekLength(copy[0..enc.len]));

    w32(&copy, 0, 3);
    try testing.expectError(error.BadLength, peekLength(copy[0..enc.len]));

    w32(&copy, 0, max_record_bytes + 1);
    try testing.expectError(error.BadLength, peekLength(copy[0..enc.len]));
}

test "a truncated record does not decode" {
    var buf: [1024]u8 = undefined;
    const enc = try encode(sampleRecord(), &buf);
    var tags: [config.max_tags]Tag = undefined;

    try testing.expectError(error.Truncated, decode(enc[0 .. enc.len - 1], &tags));
    try testing.expectError(error.Truncated, decode(enc[0..10], &tags));
}

test "tombstone flag and class survive independently" {
    var buf: [1024]u8 = undefined;
    for (0..4) |c| {
        var r = sampleRecord();
        r.class = @intCast(c);
        r.tombstone = true;
        r.tags = &.{};
        r.body = "";

        var tags: [config.max_tags]Tag = undefined;
        const dec = try decode(try encode(r, &buf), &tags);
        try testing.expectEqual(@as(config.Class, @intCast(c)), dec.class);
        try testing.expect(dec.tombstone);
    }
}

test "encode rejects oversized fields rather than truncating them" {
    var buf: [max_record_bytes]u8 = undefined;
    var r = sampleRecord();

    r.name = "";
    try testing.expectError(error.Malformed, encode(r, &buf));

    r = sampleRecord();
    r.name = "x" ** 257;
    try testing.expectError(error.Malformed, encode(r, &buf));

    r = sampleRecord();
    r.tags = &.{
        .{ .text = "a", .prev = .{ .raw = 0 } }, .{ .text = "b", .prev = .{ .raw = 0 } },
        .{ .text = "c", .prev = .{ .raw = 0 } }, .{ .text = "d", .prev = .{ .raw = 0 } },
        .{ .text = "e", .prev = .{ .raw = 0 } }, .{ .text = "f", .prev = .{ .raw = 0 } },
    };
    try testing.expectError(error.Malformed, encode(r, &buf));
}

test "a maximum-size record fits the declared bound exactly" {
    const gpa = testing.allocator;
    const body = try gpa.alloc(u8, config.max_body_bytes);
    defer gpa.free(body);
    @memset(body, 'b');

    const out = try gpa.alloc(u8, max_record_bytes);
    defer gpa.free(out);

    const r: Record = .{
        .seq = 1,
        .account_id = 1,
        .created_at = 0,
        .expires_at = 0,
        .class = 3,
        .tombstone = false,
        .name = "n" ** 256,
        .content_type = "c" ** 128,
        .tags = &.{
            .{ .text = "t" ** 64, .prev = .{ .raw = 1 } },
            .{ .text = "u" ** 64, .prev = .{ .raw = 2 } },
            .{ .text = "v" ** 64, .prev = .{ .raw = 3 } },
            .{ .text = "w" ** 64, .prev = .{ .raw = 4 } },
            .{ .text = "x" ** 64, .prev = .{ .raw = 5 } },
        },
        .body = body,
    };

    try testing.expectEqual(max_record_bytes, r.encodedLen());
    const enc = try encode(r, out);
    var tags: [config.max_tags]Tag = undefined;
    const dec = try decode(enc, &tags);
    try testing.expectEqual(@as(usize, config.max_body_bytes), dec.body.len);
}
