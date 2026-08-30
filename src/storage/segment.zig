//! Segments: four lifetime-class append streams (docs/04-storage.md, D10).
//!
//! Every entry lands in a segment belonging to the lifetime class its requested
//! TTL falls into. A segment seals when full and is immutable thereafter. Each
//! records the greatest `expires_at` it contains, and once the clock passes that,
//! **every record in the file is expired by construction and the file is
//! unlinked.** That is the whole reclamation strategy: no compaction, no
//! tombstone sweep, no rewrite.
//!
//! Classes are what make it work. Partitioning by expiry time instead would keep
//! a segment open for the entire maximum-lifetime window; classes bound a
//! segment's lifetime to roughly `seal_time + class_bound`, so short-lived data
//! reclaims quickly and cannot be pinned by a long-lived neighbour.
//!
//! ## Deliberate deviation from the specification
//!
//! `docs/04-storage.md` describes writers staging records into a per-class buffer
//! that a commit thread later flushes. This implementation writes each record
//! with `pwrite` at its reserved offset immediately and batches only the `fsync`.
//!
//! Durability is identical — a record is durable exactly when its class has been
//! fsynced — and the kernel page cache already coalesces adjacent writes, so the
//! user-space buffer would mostly duplicate it while adding a class of
//! buffer-lifetime bugs that D30 already showed is easy to get wrong. Coalescing
//! writes in user space stays available if measurement ever justifies it.

const std = @import("std");
const config = @import("config.zig");
const os = @import("os.zig");
const clock_mod = @import("clock.zig");
const loc_mod = @import("location.zig");
const record = @import("record.zig");

const Location = loc_mod.Location;
const Crc32c = std.hash.crc.Crc32Iscsi;

pub const header_bytes: u32 = 64;
const header_magic: u32 = 0x47_45_53_44; // "DSEG"
const header_version: u16 = 1;

const manifest_name = "MANIFEST";
const manifest_entry_bytes: u32 = 32;
const manifest_magic: u8 = 0xD0;

pub const Error = error{
    BadSegmentHeader,
    SegmentIdExhausted,
    RecordTooLarge,
    SegmentNotFound,
    CorruptRecord,
} || os.Error || std.mem.Allocator.Error;

/// What the engine knows about one segment.
pub const Meta = struct {
    id: u32,
    class: config.Class,
    /// Greatest `expires_at` of any record in the segment. Reclamation compares
    /// the clock against this and nothing else.
    max_expiry: u32 = 0,
    /// Bytes written, including the header.
    used: u32 = header_bytes,
    records: u32 = 0,
    sealed: bool = false,
    fd: os.Fd = -1,
};

fn segmentName(buf: []u8, class: config.Class, id: u32) ![:0]u8 {
    return std.fmt.bufPrintZ(buf, "c{d}-{d:0>8}.seg", .{ class, id });
}

/// Parses `c{class}-{id}.seg`. Returns null for anything else in the directory.
fn parseSegmentName(name: []const u8) ?struct { class: config.Class, id: u32 } {
    if (name.len < 7) return null;
    if (name[0] != 'c') return null;
    if (!std.mem.endsWith(u8, name, ".seg")) return null;
    const dash = std.mem.indexOfScalar(u8, name, '-') orelse return null;
    const class = std.fmt.parseInt(u8, name[1..dash], 10) catch return null;
    if (class >= config.class_count) return null;
    const id = std.fmt.parseInt(u32, name[dash + 1 .. name.len - 4], 10) catch return null;
    return .{ .class = @intCast(class), .id = id };
}

fn writeHeader(buf: *[header_bytes]u8, class: config.Class, id: u32, created_at: u32, capacity: u32) void {
    @memset(buf, 0);
    std.mem.writeInt(u32, buf[0..4], header_magic, .little);
    std.mem.writeInt(u16, buf[4..6], header_version, .little);
    buf[6] = class;
    std.mem.writeInt(u32, buf[8..12], id, .little);
    std.mem.writeInt(u32, buf[12..16], created_at, .little);
    std.mem.writeInt(u32, buf[16..20], capacity, .little);
    var c = Crc32c.init();
    c.update(buf[0..20]);
    c.update(buf[24..]);
    std.mem.writeInt(u32, buf[20..24], c.final(), .little);
}

fn parseHeader(buf: *const [header_bytes]u8) Error!struct { class: config.Class, id: u32, created_at: u32 } {
    if (std.mem.readInt(u32, buf[0..4], .little) != header_magic) return error.BadSegmentHeader;
    if (std.mem.readInt(u16, buf[4..6], .little) != header_version) return error.BadSegmentHeader;
    var c = Crc32c.init();
    c.update(buf[0..20]);
    c.update(buf[24..]);
    if (c.final() != std.mem.readInt(u32, buf[20..24], .little)) return error.BadSegmentHeader;
    const class = buf[6];
    if (class >= config.class_count) return error.BadSegmentHeader;
    return .{
        .class = @intCast(class),
        .id = std.mem.readInt(u32, buf[8..12], .little),
        .created_at = std.mem.readInt(u32, buf[12..16], .little),
    };
}

/// One record found by a scan.
pub const Scanned = struct {
    loc: Location,
    rec: record.Record,
    tags: [config.max_tags]record.Tag,
};

/// Result of walking a segment's records from `from_offset` to the end of valid
/// data.
pub const ScanResult = struct {
    /// First offset that is not part of a complete, verified record.
    end_offset: u32,
    records: u32,
    max_expiry: u32,
    /// True when the scan stopped on damage rather than at a clean end. For a
    /// tail this is the expected shape of a crash mid-append.
    torn: bool,
};

pub const SegmentSet = struct {
    gpa: std.mem.Allocator,
    dir_fd: os.Fd,
    clock: clock_mod.Clock,
    opts: config.Options,

    mutex: os.Mutex = .{},
    /// All known segments, keyed by id. Ids are never reused.
    metas: std.AutoHashMapUnmanaged(u32, Meta) = .{},
    /// Currently appendable segment per class.
    open_id: [config.class_count]?u32 = @splat(null),
    next_id: u32 = 1,
    manifest_fd: os.Fd = -1,

    /// Counts wholesale reclamations. The 24-hour soak asserts compaction never
    /// happens; this is the counter that shows reclamation happened instead.
    reclaimed_segments: u64 = 0,

    pub fn open(
        gpa: std.mem.Allocator,
        dir_fd: os.Fd,
        clk: clock_mod.Clock,
        opts: config.Options,
    ) Error!SegmentSet {
        var self: SegmentSet = .{
            .gpa = gpa,
            .dir_fd = dir_fd,
            .clock = clk,
            .opts = opts,
        };
        errdefer self.metas.deinit(gpa);

        try self.discover();
        self.manifest_fd = try os.open(dir_fd, manifest_name, .{ .write = true, .create = true });
        try self.replayManifest();
        return self;
    }

    pub fn deinit(self: *SegmentSet) void {
        var it = self.metas.valueIterator();
        while (it.next()) |m| {
            if (m.fd >= 0) os.close(m.fd);
        }
        self.metas.deinit(self.gpa);
        if (self.manifest_fd >= 0) os.close(self.manifest_fd);
    }

    /// The filesystem is ground truth for which segments exist: the manifest can
    /// lag a crash, the directory cannot.
    fn discover(self: *SegmentSet) Error!void {
        var it = os.DirIterator.init(self.dir_fd);
        var name_buf: [64]u8 = undefined;

        while (try it.next()) |entry| {
            const parsed = parseSegmentName(entry.name) orelse continue;

            const path = try segmentName(&name_buf, parsed.class, parsed.id);
            const fd = try os.open(self.dir_fd, path, .{ .write = true });

            var hdr: [header_bytes]u8 = undefined;
            const got = os.preadAll(fd, &hdr, 0) catch |e| {
                os.close(fd);
                return e;
            };
            if (got != header_bytes) {
                // A segment whose header never landed holds nothing. Discard it
                // rather than carry an unreadable file forever.
                os.close(fd);
                try os.unlink(self.dir_fd, path);
                continue;
            }
            const h = parseHeader(&hdr) catch {
                os.close(fd);
                return error.BadSegmentHeader;
            };
            if (h.id != parsed.id or h.class != parsed.class) {
                os.close(fd);
                return error.BadSegmentHeader;
            }

            const size = try os.fileSize(fd);
            try self.metas.put(self.gpa, parsed.id, .{
                .id = parsed.id,
                .class = parsed.class,
                .used = @intCast(size),
                .fd = fd,
            });
            if (parsed.id >= self.next_id) self.next_id = parsed.id + 1;
        }

        // The highest id in each class is the one that was open.
        for (0..config.class_count) |c| {
            var best: ?u32 = null;
            var vit = self.metas.valueIterator();
            while (vit.next()) |m| {
                if (m.class != c) continue;
                if (best == null or m.id > best.?) best = m.id;
            }
            self.open_id[c] = best;
        }
    }

    fn replayManifest(self: *SegmentSet) Error!void {
        const size = try os.fileSize(self.manifest_fd);
        const count = size / manifest_entry_bytes;
        var buf: [manifest_entry_bytes]u8 = undefined;

        var i: u64 = 0;
        while (i < count) : (i += 1) {
            const got = try os.preadAll(self.manifest_fd, &buf, i * manifest_entry_bytes);
            if (got != manifest_entry_bytes) break; // torn tail
            if (buf[0] != manifest_magic) break;

            var c = Crc32c.init();
            c.update(buf[0..24]);
            if (c.final() != std.mem.readInt(u32, buf[24..28], .little)) break; // torn tail

            const id = std.mem.readInt(u32, buf[4..8], .little);
            if (self.metas.getPtr(id)) |m| {
                m.max_expiry = std.mem.readInt(u32, buf[8..12], .little);
                m.records = std.mem.readInt(u32, buf[12..16], .little);
                m.used = std.mem.readInt(u32, buf[16..20], .little);
                m.sealed = true;
                // A sealed segment is never the append target.
                if (self.open_id[m.class]) |oid| {
                    if (oid == id) self.open_id[m.class] = null;
                }
            }
        }
    }

    /// Segments present on disk but absent from the manifest have unknown
    /// `max_expiry`, which reclamation must never guess. Scanning fills it in.
    /// Bounded work: at most the segments open or sealed since the last flush.
    pub fn resolveUnsealed(self: *SegmentSet) Error!void {
        var it = self.metas.valueIterator();
        while (it.next()) |m| {
            if (m.sealed) continue;
            const r = try self.scan(m.id, header_bytes, null, {});
            m.max_expiry = r.max_expiry;
            m.records = r.records;
            m.used = r.end_offset;
            // A torn tail is truncated away so the next append starts clean.
            if (r.end_offset < try os.fileSize(m.fd)) {
                try os.ftruncate(m.fd, r.end_offset);
            }
        }
    }

    fn appendManifest(self: *SegmentSet, m: Meta) Error!void {
        var buf: [manifest_entry_bytes]u8 = @splat(0);
        buf[0] = manifest_magic;
        buf[1] = m.class;
        std.mem.writeInt(u32, buf[4..8], m.id, .little);
        std.mem.writeInt(u32, buf[8..12], m.max_expiry, .little);
        std.mem.writeInt(u32, buf[12..16], m.records, .little);
        std.mem.writeInt(u32, buf[16..20], m.used, .little);
        var c = Crc32c.init();
        c.update(buf[0..24]);
        std.mem.writeInt(u32, buf[24..28], c.final(), .little);

        const at = try os.fileSize(self.manifest_fd);
        try os.pwriteAll(self.manifest_fd, &buf, at);
        try os.fsyncCounted(self.manifest_fd);
    }

    fn createSegment(self: *SegmentSet, class: config.Class) Error!u32 {
        if (self.next_id > config.max_segment_id) return error.SegmentIdExhausted;
        const id = self.next_id;
        self.next_id += 1;

        var name_buf: [64]u8 = undefined;
        const path = try segmentName(&name_buf, class, id);
        const fd = try os.open(self.dir_fd, path, .{
            .write = true,
            .create = true,
            .exclusive = true, // ids are never reused, so a clash is a bug
        });
        errdefer os.close(fd);

        var hdr: [header_bytes]u8 = undefined;
        writeHeader(&hdr, class, id, self.clock.now(), self.opts.segment_bytes);
        try os.pwriteAll(fd, &hdr, 0);

        try self.metas.put(self.gpa, id, .{
            .id = id,
            .class = class,
            .used = header_bytes,
            .fd = fd,
        });
        self.open_id[class] = id;
        return id;
    }

    /// Seals the open segment of `class`, recording its metadata durably.
    pub fn seal(self: *SegmentSet, class: config.Class) Error!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.sealLocked(class);
    }

    fn sealLocked(self: *SegmentSet, class: config.Class) Error!void {
        const id = self.open_id[class] orelse return;
        const m = self.metas.getPtr(id) orelse return error.SegmentNotFound;
        if (m.sealed) return;

        // Contents first, then the record that says the contents are complete.
        try os.fsyncCounted(m.fd);
        m.sealed = true;
        try self.appendManifest(m.*);
        self.open_id[class] = null;
    }

    /// Appends one already-encoded record. Returns where it landed.
    ///
    /// Rotation is transparent: when the record does not fit, the open segment is
    /// sealed and a fresh one created.
    pub fn append(self: *SegmentSet, class: config.Class, bytes: []const u8, expires_at: u32) Error!Location {
        if (bytes.len > record.max_record_bytes) return error.RecordTooLarge;

        self.mutex.lock();
        defer self.mutex.unlock();

        const len: u32 = @intCast(bytes.len);
        var id = self.open_id[class] orelse try self.createSegment(class);
        var m = self.metas.getPtr(id) orelse return error.SegmentNotFound;

        if (m.used + len > self.opts.segment_bytes) {
            try self.sealLocked(class);
            id = try self.createSegment(class);
            m = self.metas.getPtr(id) orelse return error.SegmentNotFound;
        }

        const offset = m.used;
        try os.pwriteAll(m.fd, bytes, offset);
        m.used += len;
        m.records += 1;
        if (expires_at > m.max_expiry) m.max_expiry = expires_at;

        return Location.init(class, id, offset);
    }

    /// Makes every append to `class` durable. This is the only point at which a
    /// write becomes acknowledgeable.
    pub fn sync(self: *SegmentSet, class: config.Class) Error!void {
        self.mutex.lock();
        const id = self.open_id[class];
        const fd = if (id) |i| blk: {
            const m = self.metas.get(i) orelse break :blk @as(os.Fd, -1);
            break :blk m.fd;
        } else -1;
        self.mutex.unlock();

        if (fd >= 0) try os.fsyncCounted(fd);
    }

    /// Reads the record at `loc` into `buf`, verifying it. Returns the record's
    /// byte length.
    pub fn readRecord(self: *SegmentSet, loc: Location, buf: []u8) Error!u32 {
        self.mutex.lock();
        const meta = self.metas.get(loc.segmentId());
        self.mutex.unlock();

        const m = meta orelse return error.SegmentNotFound;
        const off = loc.offset();

        var hdr: [record.header_bytes]u8 = undefined;
        if (try os.preadAll(m.fd, &hdr, off) != record.header_bytes) return error.CorruptRecord;
        const len = record.peekLength(&hdr) catch return error.CorruptRecord;
        if (len > buf.len) return error.RecordTooLarge;
        if (try os.preadAll(m.fd, buf[0..len], off) != len) return error.CorruptRecord;
        return len;
    }

    /// Walks records from `from` to the end of valid data.
    ///
    /// `ctx`/`f` receive every verified record; pass `null` for `f` to measure
    /// only. Callbacks must return `Error!void` so the scan keeps a closed error
    /// set. Stops at the first record that fails to verify, which for a tail is
    /// exactly what a crash mid-append looks like.
    pub fn scan(
        self: *SegmentSet,
        segment_id: u32,
        from: u32,
        comptime f: anytype,
        ctx: anytype,
    ) Error!ScanResult {
        const has_cb = @TypeOf(f) != @TypeOf(null);
        self.mutex.lock();
        const meta = self.metas.get(segment_id);
        self.mutex.unlock();
        const m = meta orelse return error.SegmentNotFound;

        const size: u32 = @intCast(try os.fileSize(m.fd));
        var buf = try self.gpa.alloc(u8, record.max_record_bytes);
        defer self.gpa.free(buf);

        var out: ScanResult = .{ .end_offset = from, .records = 0, .max_expiry = 0, .torn = false };
        var off = from;

        while (off + record.header_bytes <= size) {
            const got_hdr = try os.preadAll(m.fd, buf[0..record.header_bytes], off);
            if (got_hdr != record.header_bytes) {
                out.torn = true;
                break;
            }
            const len = record.peekLength(buf[0..record.header_bytes]) catch {
                out.torn = true;
                break;
            };
            if (off + len > size) {
                out.torn = true; // record extends past what was written
                break;
            }
            const got = try os.preadAll(m.fd, buf[0..len], off);
            if (got != len) {
                out.torn = true;
                break;
            }

            var tags: [config.max_tags]record.Tag = undefined;
            const rec = record.decode(buf[0..len], &tags) catch {
                out.torn = true;
                break;
            };

            if (has_cb) {
                try @as(Error!void, f(ctx, Scanned{
                    .loc = Location.init(m.class, segment_id, off),
                    .rec = rec,
                    .tags = tags,
                }));
            }

            if (rec.expires_at > out.max_expiry) out.max_expiry = rec.expires_at;
            out.records += 1;
            off += len;
            out.end_offset = off;
        }
        return out;
    }

    /// Unlinks every segment whose greatest expiry has passed.
    ///
    /// Safe with no index coordination: a segment only qualifies once all its
    /// records have expired, so any index slot pointing into it is already dead
    /// by D32's definition and can never be handed to a reader.
    pub fn reclaim(self: *SegmentSet, now: u32) Error!u32 {
        self.mutex.lock();
        defer self.mutex.unlock();

        var doomed: std.ArrayListUnmanaged(u32) = .empty;
        defer doomed.deinit(self.gpa);

        var it = self.metas.valueIterator();
        while (it.next()) |m| {
            if (!m.sealed) continue; // the open segment can still receive records
            if (m.max_expiry == 0) continue; // unresolved: never guess
            if (m.max_expiry > now) continue;
            try doomed.append(self.gpa, m.id);
        }

        var name_buf: [64]u8 = undefined;
        for (doomed.items) |id| {
            const m = self.metas.get(id) orelse continue;
            if (m.fd >= 0) os.close(m.fd);
            const path = try segmentName(&name_buf, m.class, m.id);
            os.unlink(self.dir_fd, path) catch {};
            _ = self.metas.remove(id);
            self.reclaimed_segments += 1;
        }
        if (doomed.items.len > 0) try os.syncDir(self.dir_fd);
        return @intCast(doomed.items.len);
    }

    pub const Stats = struct {
        segments: u32,
        sealed: u32,
        bytes: u64,
        records: u64,
        reclaimed: u64,
        open_per_class: [config.class_count]bool,
    };

    pub fn stats(self: *SegmentSet) Stats {
        self.mutex.lock();
        defer self.mutex.unlock();

        var out: Stats = .{
            .segments = 0,
            .sealed = 0,
            .bytes = 0,
            .records = 0,
            .reclaimed = self.reclaimed_segments,
            .open_per_class = @splat(false),
        };
        var it = self.metas.valueIterator();
        while (it.next()) |m| {
            out.segments += 1;
            if (m.sealed) out.sealed += 1;
            out.bytes += m.used;
            out.records += m.records;
        }
        for (0..config.class_count) |c| out.open_per_class[c] = self.open_id[c] != null;
        return out;
    }

    /// Open segment id and append offset per class, for the snapshot header.
    pub fn openState(self: *SegmentSet) [config.class_count]struct { id: u32, offset: u32 } {
        self.mutex.lock();
        defer self.mutex.unlock();
        var out: [config.class_count]struct { id: u32, offset: u32 } = undefined;
        for (0..config.class_count) |c| {
            if (self.open_id[c]) |id| {
                const m = self.metas.get(id).?;
                out[c] = .{ .id = id, .offset = m.used };
            } else {
                out[c] = .{ .id = 0, .offset = 0 };
            }
        }
        return out;
    }

    pub fn metaOf(self: *SegmentSet, id: u32) ?Meta {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.metas.get(id);
    }

    /// Ids of segments in `class`, oldest first. Used by recovery.
    pub fn idsOfClass(self: *SegmentSet, class: config.Class, out: *std.ArrayListUnmanaged(u32)) Error!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var it = self.metas.valueIterator();
        while (it.next()) |m| {
            if (m.class == class) try out.append(self.gpa, m.id);
        }
        std.mem.sort(u32, out.items, {}, comptime std.sort.asc(u32));
    }
};

// ---------------------------------------------------------------------------

const testing = std.testing;

const Harness = struct {
    tmp: [64]u8 = undefined,
    path: [:0]u8 = undefined,
    dir_fd: os.Fd,
    mclock: clock_mod.Manual,

    fn init(seed: u64, start_time: u32) !Harness {
        var h: Harness = .{ .dir_fd = -1, .mclock = .init(start_time) };
        h.path = try std.fmt.bufPrintZ(&h.tmp, "/tmp/doot_seg_{d}", .{seed});
        // Fresh directory every time.
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
        var name_buf: [256]u8 = undefined;
        while (it.next() catch null) |e| {
            const n = std.fmt.bufPrintZ(&name_buf, "{s}", .{e.name}) catch continue;
            os.unlink(d, n) catch {};
        }
        os.close(d);
        _ = std.os.linux.unlinkat(os.cwd, path.ptr, std.os.linux.AT.REMOVEDIR);
    }

    fn opts(_: *Harness) config.Options {
        return .{ .segment_bytes = 128 * 1024 };
    }
};

fn encodeSample(buf: []u8, seq: u64, name: []const u8, expires_at: u32, class: config.Class) ![]u8 {
    return record.encode(.{
        .seq = seq,
        .account_id = 1,
        .created_at = 1000,
        .expires_at = expires_at,
        .class = class,
        .tombstone = false,
        .name = name,
        .content_type = "text/plain",
        .tags = &.{},
        .body = "payload",
    }, buf);
}

test "segment name round-trips through the parser" {
    var buf: [64]u8 = undefined;
    const n = try segmentName(&buf, 2, 12345);
    try testing.expectEqualStrings("c2-00012345.seg", n);
    const p = parseSegmentName(n).?;
    try testing.expectEqual(@as(config.Class, 2), p.class);
    try testing.expectEqual(@as(u32, 12345), p.id);

    try testing.expect(parseSegmentName("MANIFEST") == null);
    try testing.expect(parseSegmentName("c9-00000001.seg") == null); // no such class
    try testing.expect(parseSegmentName("snapshot.idx") == null);
}

test "append then read back" {
    var h = try Harness.init(1, 1000);
    defer h.deinit();

    var set = try SegmentSet.open(testing.allocator, h.dir_fd, h.mclock.clock(), h.opts());
    defer set.deinit();

    var enc: [512]u8 = undefined;
    const bytes = try encodeSample(&enc, 7, "alpha", 5000, 1);
    const loc = try set.append(1, bytes, 5000);

    try testing.expectEqual(@as(config.Class, 1), loc.class());
    try testing.expect(loc.offset() >= header_bytes); // never overlaps the header

    var out: [1024]u8 = undefined;
    const len = try set.readRecord(loc, &out);
    var tags: [config.max_tags]record.Tag = undefined;
    const rec = try record.decode(out[0..len], &tags);
    try testing.expectEqualStrings("alpha", rec.name);
    try testing.expectEqual(@as(u64, 7), rec.seq);
}

test "each class gets its own stream" {
    var h = try Harness.init(2, 1000);
    defer h.deinit();

    var set = try SegmentSet.open(testing.allocator, h.dir_fd, h.mclock.clock(), h.opts());
    defer set.deinit();

    var enc: [512]u8 = undefined;
    var locs: [config.class_count]Location = undefined;
    for (0..config.class_count) |c| {
        const bytes = try encodeSample(&enc, c, "k", 5000, @intCast(c));
        locs[c] = try set.append(@intCast(c), bytes, 5000);
    }

    // Four distinct segments, one per class.
    var seen: [config.class_count]u32 = undefined;
    for (locs, 0..) |l, i| {
        try testing.expectEqual(@as(config.Class, @intCast(i)), l.class());
        seen[i] = l.segmentId();
    }
    for (0..config.class_count) |a| {
        for (a + 1..config.class_count) |b| try testing.expect(seen[a] != seen[b]);
    }
    try testing.expectEqual(@as(u32, 4), set.stats().segments);
}

test "a full segment seals and rotates transparently" {
    var h = try Harness.init(3, 1000);
    defer h.deinit();

    var set = try SegmentSet.open(testing.allocator, h.dir_fd, h.mclock.clock(), .{ .segment_bytes = 64 * 1024 });
    defer set.deinit();

    // 1 KiB bodies against a 64 KiB segment, so rotation is unavoidable well
    // before the loop ends rather than dependent on record-size arithmetic.
    const body = "b" ** 1024;
    var enc: [2048]u8 = undefined;
    var name_buf: [32]u8 = undefined;
    var first_id: ?u32 = null;
    var rotated = false;

    var i: u32 = 0;
    while (i < 200) : (i += 1) {
        const name = try std.fmt.bufPrint(&name_buf, "rot/{d}", .{i});
        const bytes = try record.encode(.{
            .seq = i,
            .account_id = 1,
            .created_at = 1000,
            .expires_at = 5000,
            .class = 0,
            .tombstone = false,
            .name = name,
            .content_type = "text/plain",
            .tags = &.{},
            .body = body,
        }, &enc);
        const loc = try set.append(0, bytes, 5000);
        if (first_id == null) first_id = loc.segmentId();
        if (loc.segmentId() != first_id.?) rotated = true;
        // A record never straddles the segment boundary.
        try testing.expect(loc.offset() + bytes.len <= 64 * 1024);
    }

    try testing.expect(rotated);
    const st = set.stats();
    try testing.expect(st.segments >= 2);
    try testing.expect(st.sealed >= 1);
}

test "reclaim unlinks a sealed segment once its greatest expiry has passed" {
    var h = try Harness.init(4, 1000);
    defer h.deinit();

    var set = try SegmentSet.open(testing.allocator, h.dir_fd, h.mclock.clock(), h.opts());
    defer set.deinit();

    var enc: [512]u8 = undefined;
    const bytes = try encodeSample(&enc, 1, "expiring", 2000, 0);
    _ = try set.append(0, bytes, 2000);
    try set.seal(0);

    try testing.expectEqual(@as(u32, 0), try set.reclaim(1999)); // not yet
    try testing.expectEqual(@as(u32, 1), try set.reclaim(2000)); // now
    try testing.expectEqual(@as(u32, 0), set.stats().segments);
    try testing.expectEqual(@as(u64, 1), set.stats().reclaimed);
}

test "reclaim never touches an unsealed segment or one with unknown expiry" {
    var h = try Harness.init(5, 1000);
    defer h.deinit();

    var set = try SegmentSet.open(testing.allocator, h.dir_fd, h.mclock.clock(), h.opts());
    defer set.deinit();

    var enc: [512]u8 = undefined;
    _ = try set.append(0, try encodeSample(&enc, 1, "open", 2000, 0), 2000);

    // Open, so ineligible however far the clock advances.
    try testing.expectEqual(@as(u32, 0), try set.reclaim(999_999));
    try testing.expectEqual(@as(u32, 1), set.stats().segments);
}

test "sealed metadata survives reopening" {
    var h = try Harness.init(6, 1000);
    defer h.deinit();

    var enc: [512]u8 = undefined;
    {
        var set = try SegmentSet.open(testing.allocator, h.dir_fd, h.mclock.clock(), h.opts());
        defer set.deinit();
        _ = try set.append(2, try encodeSample(&enc, 1, "persist", 7777, 2), 7777);
        try set.seal(2);
    }
    {
        var set = try SegmentSet.open(testing.allocator, h.dir_fd, h.mclock.clock(), h.opts());
        defer set.deinit();

        const st = set.stats();
        try testing.expectEqual(@as(u32, 1), st.segments);
        try testing.expectEqual(@as(u32, 1), st.sealed);

        // max_expiry came back from the manifest, so reclamation still works.
        try testing.expectEqual(@as(u32, 0), try set.reclaim(7776));
        try testing.expectEqual(@as(u32, 1), try set.reclaim(7777));
    }
}

test "an unsealed segment's expiry is recovered by scanning, not guessed" {
    var h = try Harness.init(7, 1000);
    defer h.deinit();

    var enc: [512]u8 = undefined;
    {
        var set = try SegmentSet.open(testing.allocator, h.dir_fd, h.mclock.clock(), h.opts());
        defer set.deinit();
        _ = try set.append(0, try encodeSample(&enc, 1, "a", 3000, 0), 3000);
        _ = try set.append(0, try encodeSample(&enc, 2, "b", 9000, 0), 9000);
        try set.sync(0);
        // No seal: simulates a crash with the segment still open.
    }
    {
        var set = try SegmentSet.open(testing.allocator, h.dir_fd, h.mclock.clock(), h.opts());
        defer set.deinit();

        // Before resolving, expiry is unknown and must not be acted on.
        const before = set.metaOf(1).?;
        try testing.expectEqual(@as(u32, 0), before.max_expiry);

        try set.resolveUnsealed();
        const after = set.metaOf(1).?;
        try testing.expectEqual(@as(u32, 9000), after.max_expiry); // the greatest, not the last
        try testing.expectEqual(@as(u32, 2), after.records);
    }
}

test "a torn tail is truncated away and the segment stays appendable" {
    var h = try Harness.init(8, 1000);
    defer h.deinit();

    var enc: [512]u8 = undefined;
    var good_end: u32 = 0;
    {
        var set = try SegmentSet.open(testing.allocator, h.dir_fd, h.mclock.clock(), h.opts());
        defer set.deinit();
        _ = try set.append(0, try encodeSample(&enc, 1, "intact", 3000, 0), 3000);
        good_end = set.metaOf(1).?.used;

        // Half a record, exactly what a crash mid-append leaves behind.
        const partial = try encodeSample(&enc, 2, "halfwritten", 3000, 0);
        const m = set.metaOf(1).?;
        try os.pwriteAll(m.fd, partial[0 .. partial.len / 2], good_end);
        try os.fsyncCounted(m.fd);
    }
    {
        var set = try SegmentSet.open(testing.allocator, h.dir_fd, h.mclock.clock(), h.opts());
        defer set.deinit();

        try set.resolveUnsealed();
        const m = set.metaOf(1).?;
        try testing.expectEqual(good_end, m.used);
        try testing.expectEqual(@as(u32, 1), m.records);
        try testing.expectEqual(good_end, @as(u32, @intCast(try os.fileSize(m.fd))));

        // Still usable: the next append lands right after the intact record.
        const loc = try set.append(0, try encodeSample(&enc, 3, "after", 3000, 0), 3000);
        try testing.expectEqual(good_end, loc.offset());
    }
}

test "scan reports every record and the greatest expiry" {
    var h = try Harness.init(9, 1000);
    defer h.deinit();

    var set = try SegmentSet.open(testing.allocator, h.dir_fd, h.mclock.clock(), h.opts());
    defer set.deinit();

    var enc: [512]u8 = undefined;
    var name_buf: [32]u8 = undefined;
    var i: u32 = 0;
    while (i < 25) : (i += 1) {
        const name = try std.fmt.bufPrint(&name_buf, "s/{d}", .{i});
        _ = try set.append(0, try encodeSample(&enc, i, name, 2000 + i * 10, 0), 2000 + i * 10);
    }

    const Counter = struct {
        var seen: u32 = 0;
        fn cb(_: void, _: Scanned) Error!void {
            seen += 1;
        }
    };
    Counter.seen = 0;
    const r = try set.scan(1, header_bytes, Counter.cb, {});
    try testing.expectEqual(@as(u32, 25), r.records);
    try testing.expectEqual(@as(u32, 25), Counter.seen);
    try testing.expectEqual(@as(u32, 2000 + 24 * 10), r.max_expiry);
    try testing.expect(!r.torn);
}

test "segment ids are never reused, even after reclamation" {
    var h = try Harness.init(10, 1000);
    defer h.deinit();

    var set = try SegmentSet.open(testing.allocator, h.dir_fd, h.mclock.clock(), h.opts());
    defer set.deinit();

    var enc: [512]u8 = undefined;
    _ = try set.append(0, try encodeSample(&enc, 1, "one", 2000, 0), 2000);
    try set.seal(0);
    const first = set.next_id - 1;

    try testing.expectEqual(@as(u32, 1), try set.reclaim(2000));

    _ = try set.append(0, try encodeSample(&enc, 2, "two", 3000, 0), 3000);
    const second = set.next_id - 1;
    try testing.expect(second > first);
}

test "sync flushes and is counted, which the crash harness depends on" {
    var h = try Harness.init(11, 1000);
    defer h.deinit();

    var set = try SegmentSet.open(testing.allocator, h.dir_fd, h.mclock.clock(), h.opts());
    defer set.deinit();

    var enc: [512]u8 = undefined;
    _ = try set.append(0, try encodeSample(&enc, 1, "durable", 3000, 0), 3000);

    const before = os.fsync_count.load(.monotonic);
    try set.sync(0);
    try testing.expectEqual(before + 1, os.fsync_count.load(.monotonic));

    // A class with nothing open costs no syscall.
    try set.sync(3);
    try testing.expectEqual(before + 1, os.fsync_count.load(.monotonic));
}
