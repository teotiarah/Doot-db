//! CRC32C (Castagnoli), hardware-accelerated where available.
//!
//! Every record is checksummed on write and verified on read, so this sits
//! directly in the recovery path. Measured against Zig's `std.hash.crc.Crc32Iscsi`
//! — a byte-at-a-time table implementation — the checksum was **roughly half of
//! total replay time** at 1 KiB records, about 2.5 ns/byte.
//!
//! x86-64 has had a CRC32C instruction since SSE4.2 (2008), computing exactly this
//! polynomial. It is one instruction per 8 bytes instead of a dependent table load
//! per byte.
//!
//! ## Same values, not merely a similar algorithm
//!
//! The hardware instruction implements the reflected Castagnoli CRC with no final
//! inversion, so the standard idiom — start at all-ones, feed bytes, invert the
//! result — produces byte-identical output to `Crc32Iscsi`. That matters: it means
//! this is an optimisation and not a format change, so segments written by either
//! path verify under the other.
//!
//! The test at the bottom asserts exactly that, over random data at every length
//! from 0 to 300 plus a set of larger sizes, because "should be identical" is not
//! a claim to take on trust in the one code path that decides whether data is
//! considered intact.

const std = @import("std");
const builtin = @import("builtin");

/// Reference implementation. Also the fallback on targets without the instruction.
pub const Software = std.hash.crc.Crc32Iscsi;

/// True when the CRC32C instruction is available and will be used.
pub const hardware = builtin.cpu.arch == .x86_64 and
    std.Target.x86.featureSetHas(builtin.cpu.features, .sse4_2);

inline fn step64(crc: u64, v: u64) u64 {
    return asm ("crc32q %[in], %[out]"
        : [out] "=r" (-> u64),
        : [_] "0" (crc),
          [in] "r" (v),
    );
}

inline fn step32(crc: u32, v: u32) u32 {
    return asm ("crc32l %[in], %[out]"
        : [out] "=r" (-> u32),
        : [_] "0" (crc),
          [in] "r" (v),
    );
}

/// Reflected Castagnoli polynomial, for the byte-at-a-time tail.
const poly_reflected: u32 = 0x82F6_3B78;

/// One byte, computed directly rather than with `crc32b`.
///
/// Zig 0.16's self-hosted x86 backend cannot encode the 8-bit form of the
/// instruction ("no encoding found for: crc32 r8 cl"), so the 1–3 trailing bytes
/// are done in software. At most 24 iterations per record, against 8 bytes per
/// instruction for everything else.
inline fn step8(crc: u32, v: u8) u32 {
    var c = crc ^ v;
    var i: u8 = 0;
    while (i < 8) : (i += 1) {
        c = if (c & 1 != 0) (c >> 1) ^ poly_reflected else c >> 1;
    }
    return c;
}

/// Incremental CRC32C. Mirrors the shape of `Software` so either can be swapped
/// in, and so a running checksum can span several buffers.
pub const Crc32c = struct {
    /// Internal reflected state, pre-inversion.
    state: u32,

    pub fn init() Crc32c {
        return .{ .state = 0xFFFF_FFFF };
    }

    pub fn update(c: *Crc32c, bytes: []const u8) void {
        if (!hardware) {
            // Software path keeps the same internal representation, so mixing is
            // impossible and the fallback needs no special casing elsewhere.
            c.state = ~softwareUpdate(~c.state, bytes);
            return;
        }

        var data = bytes;
        var crc: u64 = c.state;

        // Eight bytes per instruction for the bulk.
        while (data.len >= 8) {
            crc = step64(crc, std.mem.readInt(u64, data[0..8], .little));
            data = data[8..];
        }
        var crc32: u32 = @truncate(crc);
        if (data.len >= 4) {
            crc32 = step32(crc32, std.mem.readInt(u32, data[0..4], .little));
            data = data[4..];
        }
        for (data) |b| crc32 = step8(crc32, b);
        c.state = crc32;
    }

    pub fn final(c: Crc32c) u32 {
        return ~c.state;
    }
};

/// One-shot convenience.
pub fn hash(bytes: []const u8) u32 {
    var c = Crc32c.init();
    c.update(bytes);
    return c.final();
}

/// Table-driven fallback, expressed over the inverted (external) representation
/// so it composes with the hardware state.
fn softwareUpdate(prev: u32, bytes: []const u8) u32 {
    var c = Software.init();
    // `Crc32Iscsi` starts inverted internally; feed it our running value by
    // reconstructing its state.
    c.crc = ~prev;
    c.update(bytes);
    return c.final();
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "hardware and software agree at every small length" {
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const rand = prng.random();

    var buf: [300]u8 = undefined;
    rand.bytes(&buf);

    var len: usize = 0;
    while (len <= buf.len) : (len += 1) {
        const ours = hash(buf[0..len]);
        var ref = Software.init();
        ref.update(buf[0..len]);
        if (ours != ref.final()) {
            std.debug.print("mismatch at len {d}: {x} vs {x}\n", .{ len, ours, ref.final() });
            return error.TestUnexpectedResult;
        }
    }
}

test "hardware and software agree on larger buffers" {
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xBEEF);
    const rand = prng.random();

    for ([_]usize{ 1024, 4096, 65_536, 262_144 + 7 }) |n| {
        const buf = try gpa.alloc(u8, n);
        defer gpa.free(buf);
        rand.bytes(buf);

        var ref = Software.init();
        ref.update(buf);
        try testing.expectEqual(ref.final(), hash(buf));
    }
}

test "incremental updates match a single pass, so records can span buffers" {
    var prng = std.Random.DefaultPrng.init(0xF00D);
    const rand = prng.random();
    var buf: [1000]u8 = undefined;
    rand.bytes(&buf);

    // Split at awkward offsets, including ones that leave partial 8-byte groups.
    for ([_]usize{ 1, 3, 7, 8, 9, 15, 64, 511 }) |split| {
        var c = Crc32c.init();
        c.update(buf[0..split]);
        c.update(buf[split..]);
        try testing.expectEqual(hash(&buf), c.final());
    }
}

test "known CRC32C values" {
    // From RFC 3720 appendix B / the Castagnoli test vectors.
    try testing.expectEqual(@as(u32, 0x0000_0000), hash(""));
    try testing.expectEqual(@as(u32, 0xE3069283), hash("123456789"));
    try testing.expectEqual(@as(u32, 0x8A9136AA), hash(&[_]u8{0} ** 32));
    try testing.expectEqual(@as(u32, 0x62A8AB43), hash(&[_]u8{0xFF} ** 32));
}

test "the hardware path is actually being taken on this target" {
    // If this ever fails the engine still works, but the recovery budget in
    // docs/04-storage.md was measured with the instruction available.
    try testing.expect(hardware);
}
