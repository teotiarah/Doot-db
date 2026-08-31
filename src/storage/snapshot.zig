//! Index snapshots (docs/04-storage.md, D17).
//!
//! A snapshot is what makes recovery bounded: without one, restart would have to
//! scan every segment. With one, recovery loads the packed slot arrays and replays
//! only the records written since — the tails.
//!
//! ## Tag heads are part of the snapshot, not derivable
//!
//! Not in the original specification, and its absence would have been a silent
//! data-loss bug rather than a crash.
//!
//! Chain heads live only in RAM (D12). Recovery scans *tails*, not whole segments,
//! so a head pointing at a record older than the snapshot could never be
//! reconstructed. Listing would return nothing for older tags after any restart,
//! and every individual entry would still read back correctly — so the store would
//! look healthy while quietly having lost its only means of enumeration.
//!
//! They are therefore written alongside the slots and restored with them.
//!
//! ## Atomic replacement
//!
//! Written to a temporary file, fsynced, then renamed over the live one and the
//! directory fsynced. A reader sees the whole previous snapshot or the whole new
//! one. A crash mid-write leaves the previous snapshot intact, which is why an
//! older snapshot plus a longer tail replay is always a safe outcome.

const std = @import("std");
const config = @import("config.zig");
const os = @import("os.zig");
const index_mod = @import("index.zig");
const tagchain = @import("tagchain.zig");

const Crc32c = @import("crc32c.zig").Crc32c;

pub const file_name = "SNAPSHOT";
const temp_name = "SNAPSHOT.tmp";

const magic: u32 = 0x504E_5344; // "DSNP"
const version: u16 = 1;
pub const header_bytes: u32 = 128;

pub const Error = error{
    BadSnapshot,
    SnapshotVersionMismatch,
} || os.Error || std.mem.Allocator.Error;

/// Per-class append position at the moment the snapshot was taken. Recovery
/// resumes its tail scan from exactly here.
pub const OpenState = struct {
    id: u32 = 0,
    offset: u32 = 0,
};

pub const Header = struct {
    /// Highest sequence number reflected in the snapshot. Everything above it
    /// must come from tail replay.
    seq_watermark: u64,
    open: [config.class_count]OpenState,
    shard_count: u32,
    total_slots: u64,
    tag_pairs: u64,
};

fn w16(b: []u8, o: usize, v: u16) void {
    std.mem.writeInt(u16, b[o..][0..2], v, .little);
}
fn w32(b: []u8, o: usize, v: u32) void {
    std.mem.writeInt(u32, b[o..][0..4], v, .little);
}
fn w64(b: []u8, o: usize, v: u64) void {
    std.mem.writeInt(u64, b[o..][0..8], v, .little);
}
fn r16(b: []const u8, o: usize) u16 {
    return std.mem.readInt(u16, b[o..][0..2], .little);
}
fn r32(b: []const u8, o: usize) u32 {
    return std.mem.readInt(u32, b[o..][0..4], .little);
}
fn r64(b: []const u8, o: usize) u64 {
    return std.mem.readInt(u64, b[o..][0..8], .little);
}

const crc_offset: usize = 120;

fn encodeHeader(buf: *[header_bytes]u8, h: Header) void {
    @memset(buf, 0);
    w32(buf, 0, magic);
    w16(buf, 4, version);
    w16(buf, 6, @intCast(h.shard_count));
    w64(buf, 8, h.seq_watermark);
    for (h.open, 0..) |o, i| {
        w32(buf, 16 + i * 8, o.id);
        w32(buf, 16 + i * 8 + 4, o.offset);
    }
    w64(buf, 48, h.total_slots);
    w64(buf, 56, h.tag_pairs);

    var c = Crc32c.init();
    c.update(buf[0..crc_offset]);
    w32(buf, crc_offset, c.final());
}

fn decodeHeader(buf: *const [header_bytes]u8) Error!Header {
    if (r32(buf, 0) != magic) return error.BadSnapshot;
    if (r16(buf, 4) != version) return error.SnapshotVersionMismatch;

    var c = Crc32c.init();
    c.update(buf[0..crc_offset]);
    if (c.final() != r32(buf, crc_offset)) return error.BadSnapshot;

    var h: Header = .{
        .seq_watermark = r64(buf, 8),
        .open = @splat(.{}),
        .shard_count = r16(buf, 6),
        .total_slots = r64(buf, 48),
        .tag_pairs = r64(buf, 56),
    };
    for (0..config.class_count) |i| {
        h.open[i] = .{
            .id = r32(buf, 16 + i * 8),
            .offset = r32(buf, 16 + i * 8 + 4),
        };
    }
    if (h.shard_count != config.index_shards) return error.BadSnapshot;
    return h;
}

/// Streams a snapshot to disk and swaps it into place.
pub fn write(
    gpa: std.mem.Allocator,
    dir_fd: os.Fd,
    idx: *index_mod.Index,
    heads: *tagchain.TagHeads,
    seq_watermark: u64,
    open: [config.class_count]OpenState,
) Error!void {
    const fd = try os.open(dir_fd, temp_name, .{ .write = true, .create = true, .truncate = true });
    defer os.close(fd);

    // Body first, so the header can carry totals the body determines.
    var offset: u64 = header_bytes;
    var total_slots: u64 = 0;
    var body_crc = Crc32c.init();

    const Ctx = struct {
        fd: os.Fd,
        offset: *u64,
        total: *u64,
        crc: *Crc32c,

        fn emit(self: @This(), hashes: []const u64, locs: []const u64, exps: []const u32) Error!void {
            var count_buf: [4]u8 = undefined;
            w32(&count_buf, 0, @intCast(hashes.len));
            try writeChunk(self.fd, self.offset, self.crc, &count_buf);
            try writeChunk(self.fd, self.offset, self.crc, std.mem.sliceAsBytes(hashes));
            try writeChunk(self.fd, self.offset, self.crc, std.mem.sliceAsBytes(locs));
            try writeChunk(self.fd, self.offset, self.crc, std.mem.sliceAsBytes(exps));
            self.total.* += hashes.len;
        }
    };

    var shard: u32 = 0;
    while (shard < config.index_shards) : (shard += 1) {
        // Under the shard's own lock, so no slot is copied mid-update. This is
        // what makes the snapshot consistent without stopping the world.
        try idx.withShard(shard, Ctx{
            .fd = fd,
            .offset = &offset,
            .total = &total_slots,
            .crc = &body_crc,
        }, Ctx.emit);
    }

    // Tag heads.
    const tag_pairs = try writeTagHeads(gpa, fd, &offset, &body_crc, heads);

    // Body checksum, then the header that vouches for it.
    var crc_buf: [4]u8 = undefined;
    w32(&crc_buf, 0, body_crc.final());
    try os.pwriteAll(fd, &crc_buf, offset);

    var hdr: [header_bytes]u8 = undefined;
    encodeHeader(&hdr, .{
        .seq_watermark = seq_watermark,
        .open = open,
        .shard_count = config.index_shards,
        .total_slots = total_slots,
        .tag_pairs = tag_pairs,
    });
    try os.pwriteAll(fd, &hdr, 0);

    // Durable before it is visible; visible atomically; then the directory entry
    // itself made durable.
    try os.fsyncCounted(fd);
    try os.rename(dir_fd, temp_name, file_name);
    try os.syncDir(dir_fd);
}

fn writeChunk(fd: os.Fd, offset: *u64, crc: *Crc32c, bytes: []const u8) Error!void {
    if (bytes.len == 0) return;
    try os.pwriteAll(fd, bytes, offset.*);
    crc.update(bytes);
    offset.* += bytes.len;
}

fn writeTagHeads(
    gpa: std.mem.Allocator,
    fd: os.Fd,
    offset: *u64,
    crc: *Crc32c,
    heads: *tagchain.TagHeads,
) Error!u64 {
    heads.mutex.lock();
    defer heads.mutex.unlock();

    var count_buf: [8]u8 = undefined;
    w64(&count_buf, 0, heads.map.count());
    try writeChunk(fd, offset, crc, &count_buf);

    // Entry: account_id (4), tag_len (2), tag bytes, 4 head pointers (32).
    var rec = try gpa.alloc(u8, 6 + config.max_tag_bytes + @sizeOf(tagchain.Heads));
    defer gpa.free(rec);

    var it = heads.map.iterator();
    var written: u64 = 0;
    while (it.next()) |e| {
        const tag = e.key_ptr.tag;
        w32(rec, 0, e.key_ptr.account_id);
        w16(rec, 4, @intCast(tag.len));
        @memcpy(rec[6..][0..tag.len], tag);
        var p: usize = 6 + tag.len;
        for (e.value_ptr.*) |h| {
            w64(rec, p, h);
            p += 8;
        }
        try writeChunk(fd, offset, crc, rec[0..p]);
        written += 1;
    }
    return written;
}

pub const Loaded = struct {
    header: Header,
};

/// Loads a snapshot into `idx` and `heads`. Returns null when there is none, or
/// when the one present fails verification — in which case recovery falls back to
/// replaying from the beginning, which is slower but correct.
pub fn read(
    gpa: std.mem.Allocator,
    dir_fd: os.Fd,
    idx: *index_mod.Index,
    heads: *tagchain.TagHeads,
    now: u32,
) Error!?Loaded {
    const fd = os.open(dir_fd, file_name, .{}) catch |e| switch (e) {
        error.FileNotFound => return null,
        else => return e,
    };
    defer os.close(fd);

    const size = try os.fileSize(fd);
    if (size < header_bytes + 4) return null;

    var hdr: [header_bytes]u8 = undefined;
    if (try os.preadAll(fd, &hdr, 0) != header_bytes) return null;
    const header = decodeHeader(&hdr) catch return null;

    // Read the body in one go: it is a few hundred MB at most and this is a
    // once-per-start cost.
    const body_len: usize = @intCast(size - header_bytes - 4);
    const body = try gpa.alloc(u8, body_len);
    defer gpa.free(body);
    if (try os.preadAll(fd, body, header_bytes) != body_len) return null;

    var crc_buf: [4]u8 = undefined;
    if (try os.preadAll(fd, &crc_buf, header_bytes + body_len) != 4) return null;

    var c = Crc32c.init();
    c.update(body);
    if (c.final() != r32(&crc_buf, 0)) return null; // torn or corrupt: ignore it

    var p: usize = 0;
    var shard: u32 = 0;
    while (shard < header.shard_count) : (shard += 1) {
        if (p + 4 > body.len) return null;
        const n = r32(body, p);
        p += 4;

        const need = @as(usize, n) * (8 + 8 + 4);
        if (p + need > body.len) return null;

        const hashes = std.mem.bytesAsSlice(u64, body[p..][0 .. n * 8]);
        p += n * 8;
        const locs = std.mem.bytesAsSlice(u64, body[p..][0 .. n * 8]);
        p += n * 8;
        const exps = std.mem.bytesAsSlice(u32, body[p..][0 .. n * 4]);
        p += n * 4;

        try idx.loadShard(shard, hashes, locs, exps, now);
    }

    if (p + 8 > body.len) return null;
    const pairs = r64(body, p);
    p += 8;

    var i: u64 = 0;
    while (i < pairs) : (i += 1) {
        if (p + 6 > body.len) return null;
        const account_id = r32(body, p);
        const tag_len = r16(body, p + 4);
        p += 6;
        if (tag_len == 0 or tag_len > config.max_tag_bytes) return null;
        if (p + tag_len + @sizeOf(tagchain.Heads) > body.len) return null;
        const tag = body[p..][0..tag_len];
        p += tag_len;

        for (0..config.class_count) |cls| {
            const raw = r64(body, p);
            p += 8;
            if (raw == 0) continue;
            try heads.set(account_id, tag, @intCast(cls), .{ .raw = raw });
        }
    }

    return .{ .header = header };
}

// ---------------------------------------------------------------------------

const testing = std.testing;
const Location = @import("location.zig").Location;

const Harness = struct {
    tmp: [64]u8 = undefined,
    path: [:0]u8 = undefined,
    dir_fd: os.Fd,

    fn init(seed: u64) !Harness {
        var h: Harness = .{ .dir_fd = -1 };
        h.path = try std.fmt.bufPrintZ(&h.tmp, "/tmp/doot_snap_{d}", .{seed});
        removeTree(h.path);
        try os.mkdir(os.cwd, h.path);
        h.dir_fd = try os.openDir(os.cwd, h.path);
        return h;
    }
    fn deinit(h: *Harness) void {
        os.close(h.dir_fd);
        removeTree(h.path);
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

const now0: u32 = 1_000_000;

test "an index survives a snapshot round-trip" {
    var h = try Harness.init(1);
    defer h.deinit();

    const opts: config.Options = .{ .index_hash_key = @splat(4) };
    var names: [500][24]u8 = undefined;
    var lens: [500]usize = undefined;

    {
        var idx = try index_mod.Index.init(testing.allocator, opts);
        defer idx.deinit();
        var heads = tagchain.TagHeads.init(testing.allocator);
        defer heads.deinit();

        for (0..500) |i| {
            const name = try std.fmt.bufPrint(&names[i], "snap/{d}", .{i});
            lens[i] = name.len;
            _ = try idx.upsert(
                idx.hash(1, name),
                null,
                .{ .raw = 0 },
                Location.init(@intCast(i % 4), 1 + @as(u32, @intCast(i)) / 100, 64 + @as(u32, @intCast(i)) * 64),
                now0 + 5000,
                now0,
            );
        }
        _ = try heads.push(1, "alpha", 0, Location.init(0, 1, 128));
        _ = try heads.push(1, "alpha", 2, Location.init(2, 3, 256));
        _ = try heads.push(7, "beta", 1, Location.init(1, 9, 512));

        try write(testing.allocator, h.dir_fd, &idx, &heads, 12_345, .{
            .{ .id = 1, .offset = 4096 },
            .{ .id = 2, .offset = 8192 },
            .{ .id = 3, .offset = 128 },
            .{},
        });
    }
    {
        var idx = try index_mod.Index.init(testing.allocator, opts);
        defer idx.deinit();
        var heads = tagchain.TagHeads.init(testing.allocator);
        defer heads.deinit();

        const loaded = (try read(testing.allocator, h.dir_fd, &idx, &heads, now0)).?;
        try testing.expectEqual(@as(u64, 12_345), loaded.header.seq_watermark);
        try testing.expectEqual(@as(u32, 1), loaded.header.open[0].id);
        try testing.expectEqual(@as(u32, 4096), loaded.header.open[0].offset);
        try testing.expectEqual(@as(u32, 8192), loaded.header.open[1].offset);
        try testing.expect(loaded.header.total_slots > 0);
        try testing.expectEqual(@as(u64, 500), idx.stats().live);

        // Every entry is where it was.
        for (0..500) |i| {
            const name = names[i][0..lens[i]];
            var buf: [8]index_mod.Candidate = undefined;
            const c = idx.candidates(idx.hash(1, name), now0, &buf);
            try testing.expectEqual(@as(usize, 1), c.len);
            try testing.expect(c[0].loc.eql(Location.init(
                @intCast(i % 4),
                1 + @as(u32, @intCast(i)) / 100,
                64 + @as(u32, @intCast(i)) * 64,
            )));
        }

        // And so are the tag heads, which would otherwise be unrecoverable.
        try testing.expect(heads.head(1, "alpha", 0).eql(Location.init(0, 1, 128)));
        try testing.expect(heads.head(1, "alpha", 2).eql(Location.init(2, 3, 256)));
        try testing.expect(heads.head(1, "alpha", 1).isNone());
        try testing.expect(heads.head(7, "beta", 1).eql(Location.init(1, 9, 512)));
    }
}

test "a truncated snapshot is ignored rather than half-applied" {
    var h = try Harness.init(2);
    defer h.deinit();
    const opts: config.Options = .{ .index_hash_key = @splat(5) };

    {
        var idx = try index_mod.Index.init(testing.allocator, opts);
        defer idx.deinit();
        var heads = tagchain.TagHeads.init(testing.allocator);
        defer heads.deinit();
        _ = try idx.upsert(idx.hash(1, "x"), null, .{ .raw = 0 }, Location.init(0, 1, 64), now0 + 100, now0);
        try write(testing.allocator, h.dir_fd, &idx, &heads, 5, @splat(.{}));
    }

    // Lop off the tail, as an interrupted write would.
    const fd = try os.open(h.dir_fd, file_name, .{ .write = true });
    const size = try os.fileSize(fd);
    try os.ftruncate(fd, size - 8);
    os.close(fd);

    var idx = try index_mod.Index.init(testing.allocator, opts);
    defer idx.deinit();
    var heads = tagchain.TagHeads.init(testing.allocator);
    defer heads.deinit();

    try testing.expect(try read(testing.allocator, h.dir_fd, &idx, &heads, now0) == null);
    try testing.expectEqual(@as(u64, 0), idx.stats().live);
}

test "a corrupted snapshot body is ignored" {
    var h = try Harness.init(3);
    defer h.deinit();
    const opts: config.Options = .{ .index_hash_key = @splat(6) };

    {
        var idx = try index_mod.Index.init(testing.allocator, opts);
        defer idx.deinit();
        var heads = tagchain.TagHeads.init(testing.allocator);
        defer heads.deinit();
        _ = try idx.upsert(idx.hash(1, "y"), null, .{ .raw = 0 }, Location.init(0, 1, 64), now0 + 100, now0);
        try write(testing.allocator, h.dir_fd, &idx, &heads, 5, @splat(.{}));
    }

    const fd = try os.open(h.dir_fd, file_name, .{ .write = true });
    var byte: [1]u8 = .{0xFF};
    try os.pwriteAll(fd, &byte, header_bytes + 16);
    os.close(fd);

    var idx = try index_mod.Index.init(testing.allocator, opts);
    defer idx.deinit();
    var heads = tagchain.TagHeads.init(testing.allocator);
    defer heads.deinit();
    try testing.expect(try read(testing.allocator, h.dir_fd, &idx, &heads, now0) == null);
}

test "no snapshot is not an error" {
    var h = try Harness.init(4);
    defer h.deinit();

    var idx = try index_mod.Index.init(testing.allocator, .{});
    defer idx.deinit();
    var heads = tagchain.TagHeads.init(testing.allocator);
    defer heads.deinit();

    try testing.expect(try read(testing.allocator, h.dir_fd, &idx, &heads, now0) == null);
}

test "the previous snapshot survives a crash during the next one" {
    var h = try Harness.init(5);
    defer h.deinit();
    const opts: config.Options = .{ .index_hash_key = @splat(8) };

    var idx = try index_mod.Index.init(testing.allocator, opts);
    defer idx.deinit();
    var heads = tagchain.TagHeads.init(testing.allocator);
    defer heads.deinit();
    _ = try idx.upsert(idx.hash(1, "first"), null, .{ .raw = 0 }, Location.init(0, 1, 64), now0 + 100, now0);
    try write(testing.allocator, h.dir_fd, &idx, &heads, 100, @splat(.{}));

    // A half-finished temp file, which is what a crash mid-snapshot leaves.
    const tfd = try os.open(h.dir_fd, temp_name, .{ .write = true, .create = true, .truncate = true });
    try os.pwriteAll(tfd, "garbage", 0);
    os.close(tfd);

    var idx2 = try index_mod.Index.init(testing.allocator, opts);
    defer idx2.deinit();
    var heads2 = tagchain.TagHeads.init(testing.allocator);
    defer heads2.deinit();

    const loaded = (try read(testing.allocator, h.dir_fd, &idx2, &heads2, now0)).?;
    try testing.expectEqual(@as(u64, 100), loaded.header.seq_watermark);
    try testing.expectEqual(@as(u64, 1), idx2.stats().live);
}

test "expired slots come back as dead, not live" {
    var h = try Harness.init(6);
    defer h.deinit();
    const opts: config.Options = .{ .index_hash_key = @splat(11) };

    {
        var idx = try index_mod.Index.init(testing.allocator, opts);
        defer idx.deinit();
        var heads = tagchain.TagHeads.init(testing.allocator);
        defer heads.deinit();
        _ = try idx.upsert(idx.hash(1, "soon"), null, .{ .raw = 0 }, Location.init(0, 1, 64), now0 + 10, now0);
        _ = try idx.upsert(idx.hash(1, "later"), null, .{ .raw = 0 }, Location.init(0, 1, 128), now0 + 10_000, now0);
        try write(testing.allocator, h.dir_fd, &idx, &heads, 7, @splat(.{}));
    }

    var idx = try index_mod.Index.init(testing.allocator, opts);
    defer idx.deinit();
    var heads = tagchain.TagHeads.init(testing.allocator);
    defer heads.deinit();

    // Loaded well after the first entry lapsed.
    _ = try read(testing.allocator, h.dir_fd, &idx, &heads, now0 + 1000);
    const st = idx.stats();
    try testing.expectEqual(@as(u64, 1), st.live);
    try testing.expectEqual(@as(u64, 1), st.dead);
}
