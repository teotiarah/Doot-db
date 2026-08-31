//! Store identity — the `STORE` file.
//!
//! Holds the key that the index hashes `(account_id, name)` with. That key is
//! **store-local state, not configuration** (D43), and the distinction is
//! load-bearing rather than tidy.
//!
//! The index keeps a 64-bit keyed hash and nothing else (D11), so the key is part
//! of the identity of every slot and of every hash written to `SNAPSHOT`. Open the
//! same data with a different key and every lookup misses: `get` probes, finds no
//! matching hash, and returns "absent". Nothing errors. A full tail replay cannot
//! repair it either, because replay only re-hashes records after the snapshot
//! watermark and sealed segments are never re-read. The store would come up
//! reporting its full entry count and be unable to find a single entry written
//! before the change.
//!
//! A secret that must be byte-identical on every boot for the lifetime of the data
//! is not a secret the environment should hold. So it is generated once, here, and
//! persisted beside the data it addresses.
//!
//! ```
//! offset  size  field
//!   0       4   magic "DSTR"
//!   4       2   format version
//!   6       2   reserved
//!   8       4   created_at        unix seconds
//!  12      16   index_hash_key    CSPRNG at initialisation
//!  28       4   crc32c            over bytes 0..27
//! ```
//!
//! Deliberately its own file rather than the reserved bytes in the snapshot
//! header: `snapshot.read` is fail-soft and returns null on any damage, degrading
//! to a full replay. A key living only there would let a damaged snapshot produce a
//! *different* key and an unreadable store that reports success — the worst
//! available failure shape.

const std = @import("std");
const os = @import("os.zig");
const crc32c = @import("crc32c.zig");

pub const file_name = "STORE";

const magic: u32 = 0x52545344; // "DSTR"
const version: u16 = 1;

pub const header_bytes: u32 = 32;
const crc_offset: usize = 28;

/// 128 bits, which is what SipHash-1-3 takes.
pub const key_bytes: usize = 16;

pub const Error = error{
    /// Present but not something this build can trust: bad magic or bad checksum.
    BadStoreIdentity,
    /// Absent or unreadable, beside segments that already exist. Refusing is the
    /// whole point — see `openOrCreate`.
    StoreIdentityMissing,
    StoreVersionMismatch,
} || os.Error;

pub const Identity = struct {
    created_at: u32,
    index_hash_key: [key_bytes]u8,
};

/// Resolves the store's identity, creating it only for a genuinely new store.
///
/// `has_data` must say whether the directory already holds segments
/// (`segment.anySegments`). It is the entire difference between the two cases that
/// look identical on disk:
///
/// | directory | `STORE` | behaviour |
/// |---|---|---|
/// | empty | absent | generate a key and persist it |
/// | has segments | valid | adopt the persisted key |
/// | has segments | absent or damaged | **refuse** |
///
/// The third row is why this function takes the flag at all. A missing `STORE`
/// beside live segments means an incomplete restore or a deleted file, and
/// inventing a fresh key there silently orphans every entry that exists. Failing
/// loudly at open is the same posture D24 takes for configuration.
pub fn openOrCreate(dir_fd: os.Fd, has_data: bool, now: u32) Error!Identity {
    if (try read(dir_fd)) |id| return id;
    if (has_data) return error.StoreIdentityMissing;
    return create(dir_fd, now);
}

/// Returns null when the file is absent or cannot be trusted. Distinguishing
/// those two is the caller's job, because only the caller knows whether data
/// exists — and the response differs completely.
pub fn read(dir_fd: os.Fd) Error!?Identity {
    const fd = os.open(dir_fd, file_name, .{}) catch |e| switch (e) {
        error.FileNotFound => return null,
        else => return e,
    };
    defer os.close(fd);

    var buf: [header_bytes]u8 = undefined;
    const got = try os.preadAll(fd, &buf, 0);
    if (got != header_bytes) return null;

    if (readInt(u32, buf[0..4]) != magic) return null;

    // Checksum before the version, so a corrupt file is reported as corrupt
    // rather than as an unsupported format.
    if (crc32c.hash(buf[0..crc_offset]) != readInt(u32, buf[crc_offset..][0..4])) return null;

    const v = readInt(u16, buf[4..6]);
    if (v != version) return error.StoreVersionMismatch;

    var id: Identity = .{
        .created_at = readInt(u32, buf[8..12]),
        .index_hash_key = undefined,
    };
    @memcpy(&id.index_hash_key, buf[12..][0..key_bytes]);
    return id;
}

/// Writes a fresh identity. Only ever called for a directory holding no segments.
///
/// No write-to-temp-then-rename here, and that is a considered omission rather
/// than an oversight: the only moment `STORE` can be torn is during this call, and
/// at that moment there is no data for a wrong key to orphan. A torn file fails
/// `read`'s checksum, `has_data` is still false on the next open, and it is simply
/// regenerated. The atomic-replace dance exists to protect a file that is being
/// *replaced*, and this one never is.
fn create(dir_fd: os.Fd, now: u32) Error!Identity {
    var id: Identity = .{ .created_at = now, .index_hash_key = undefined };
    try os.getRandom(&id.index_hash_key);

    var buf: [header_bytes]u8 = @splat(0);
    writeInt(u32, buf[0..4], magic);
    writeInt(u16, buf[4..6], version);
    writeInt(u32, buf[8..12], now);
    @memcpy(buf[12..][0..key_bytes], &id.index_hash_key);
    writeInt(u32, buf[crc_offset..][0..4], crc32c.hash(buf[0..crc_offset]));

    const fd = try os.open(dir_fd, file_name, .{ .write = true, .create = true, .truncate = true });
    defer os.close(fd);
    try os.pwriteAll(fd, &buf, 0);
    try os.fsyncCounted(fd);
    // The directory entry has to be durable too, or the file can vanish while its
    // contents survive.
    try os.syncDir(dir_fd);

    return id;
}

fn readInt(comptime T: type, bytes: *const [@divExact(@typeInfo(T).int.bits, 8)]u8) T {
    return std.mem.readInt(T, bytes, .little);
}

fn writeInt(comptime T: type, bytes: *[@divExact(@typeInfo(T).int.bits, 8)]u8, v: T) void {
    std.mem.writeInt(T, bytes, v, .little);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const H = struct {
    dir: [:0]const u8,
    fd: os.Fd,

    fn init(name: [:0]const u8) !H {
        removeTree(name);
        try os.mkdir(os.cwd, name);
        return .{ .dir = name, .fd = try os.openDir(os.cwd, name) };
    }

    fn deinit(h: *H) void {
        os.close(h.fd);
        removeTree(h.dir);
    }

    fn removeTree(path: [:0]const u8) void {
        const d = os.openDir(os.cwd, path) catch return;
        var it = os.DirIterator.init(d);
        var nb: [256]u8 = undefined;
        while (it.next() catch null) |e| {
            const n = std.fmt.bufPrintZ(&nb, "{s}", .{e.name}) catch continue;
            os.unlink(d, n) catch {};
        }
        os.close(d);
        _ = std.os.linux.unlinkat(os.cwd, path.ptr, std.os.linux.AT.REMOVEDIR);
    }
};

test "a fresh store generates and persists a key" {
    var h = try H.init("/tmp/doot_ident_fresh");
    defer h.deinit();

    const a = try openOrCreate(h.fd, false, 1000);
    const b = try openOrCreate(h.fd, true, 2000);

    try testing.expectEqualSlices(u8, &a.index_hash_key, &b.index_hash_key);
    try testing.expectEqual(@as(u32, 1000), b.created_at);
}

test "two fresh stores get different keys" {
    var h1 = try H.init("/tmp/doot_ident_k1");
    defer h1.deinit();
    var h2 = try H.init("/tmp/doot_ident_k2");
    defer h2.deinit();

    const a = try openOrCreate(h1.fd, false, 1);
    const b = try openOrCreate(h2.fd, false, 1);

    // A per-store key is what keeps hash flooding from being a remote DoS (D11).
    try testing.expect(!std.mem.eql(u8, &a.index_hash_key, &b.index_hash_key));
}

test "a key is never invented beside data that already exists" {
    var h = try H.init("/tmp/doot_ident_refuse");
    defer h.deinit();

    // No STORE, but the caller reports segments present. This is the incomplete
    // restore, and guessing here would orphan every entry.
    try testing.expectError(error.StoreIdentityMissing, openOrCreate(h.fd, true, 1));
}

test "a damaged identity is refused rather than replaced" {
    var h = try H.init("/tmp/doot_ident_damaged");
    defer h.deinit();
    _ = try openOrCreate(h.fd, false, 1);

    // Corrupt one byte of the key.
    const fd = try os.open(h.fd, file_name, .{ .write = true });
    var one: [1]u8 = .{0xFF};
    try os.pwriteAll(fd, &one, 20);
    os.close(fd);

    try testing.expectEqual(@as(?Identity, null), try read(h.fd));
    try testing.expectError(error.StoreIdentityMissing, openOrCreate(h.fd, true, 1));
}

test "every byte of the identity is covered by its checksum" {
    var h = try H.init("/tmp/doot_ident_flip");
    defer h.deinit();
    _ = try openOrCreate(h.fd, false, 7);

    var original: [header_bytes]u8 = undefined;
    {
        const fd = try os.open(h.fd, file_name, .{});
        defer os.close(fd);
        _ = try os.preadAll(fd, &original, 0);
    }

    var i: usize = 0;
    while (i < header_bytes) : (i += 1) {
        var bit: u3 = 0;
        while (true) {
            var flipped = original;
            flipped[i] ^= (@as(u8, 1) << bit);

            const fd = try os.open(h.fd, file_name, .{ .write = true });
            try os.pwriteAll(fd, &flipped, 0);
            os.close(fd);

            // Detected as damage, or rejected as a version we do not know. Never
            // silently accepted, because accepting a wrong key loses the store.
            const r = read(h.fd) catch |e| {
                try testing.expectEqual(error.StoreVersionMismatch, e);
                if (bit == 7) break;
                bit += 1;
                continue;
            };
            try testing.expectEqual(@as(?Identity, null), r);

            if (bit == 7) break;
            bit += 1;
        }
    }
}

test "a torn identity on a fresh store is simply regenerated" {
    var h = try H.init("/tmp/doot_ident_torn");
    defer h.deinit();

    // Half a header, as a crash during `create` would leave.
    {
        const fd = try os.open(h.fd, file_name, .{ .write = true, .create = true });
        defer os.close(fd);
        var half: [12]u8 = @splat(0);
        writeInt(u32, half[0..4], magic);
        try os.pwriteAll(fd, &half, 0);
    }

    // No data exists yet, so there is nothing a new key could orphan.
    const id = try openOrCreate(h.fd, false, 42);
    try testing.expectEqual(@as(u32, 42), id.created_at);
    try testing.expectEqualSlices(u8, &id.index_hash_key, &(try read(h.fd)).?.index_hash_key);
}
