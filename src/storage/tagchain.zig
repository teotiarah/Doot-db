//! Tag traversal (docs/04-storage.md, D12).
//!
//! A posting list per tag would cost `O(entries)` of RAM and dwarf the index,
//! undoing the memory work in D11. So the lists live on disk: every record
//! carries, per tag, a back-pointer to the previous record with that tag in that
//! lifetime class. RAM holds only the chain heads.
//!
//! **In-memory cost is `O(distinct tags per account)`, not `O(entries)`** — and
//! independent of how much data is stored.
//!
//! ## Why chains are per class
//!
//! Chains are ordered by write time, but entries expire in a different order. A
//! chain crossing classes could contain a dead link whose segment has already been
//! unlinked, orphaning live entries behind it. Within one class, expiry order and
//! write order agree, so once traversal reaches a vanished segment everything
//! beyond it is expired too and stopping is correct.
//!
//! Cost: four head pointers per tag instead of one, held in a single map entry.
//!
//! ## Every hop is validated
//!
//! A chain is append-only and never repaired, so it accumulates records that have
//! since been overwritten or deleted. Traversal therefore checks each record
//! against the index — hash its name, and confirm the live location for that name
//! is this record. Anything else is a superseded version and is skipped.
//!
//! That is also why a page can come back short while more results remain, and why
//! callers must paginate until the cursor is absent rather than until a page is
//! short.

const std = @import("std");
const config = @import("config.zig");
const os = @import("os.zig");
const loc_mod = @import("location.zig");
const record = @import("record.zig");
const index_mod = @import("index.zig");
const segment = @import("segment.zig");

const Location = loc_mod.Location;

pub const Error = segment.Error;

/// Extracts a callback's error set so `walk` can return the union of its own
/// failures and the caller's, instead of forcing either to widen.
fn ErrSetOf(comptime F: type) type {
    return @typeInfo(@typeInfo(F).@"fn".return_type.?).error_union.error_set;
}

/// Head of each class chain for one (account, tag) pair. Four pointers in one
/// map entry rather than four entries.
pub const Heads = [config.class_count]u64;

const Key = struct {
    account_id: u32,
    tag: []const u8,
};

const KeyContext = struct {
    pub fn hash(_: KeyContext, k: Key) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&k.account_id));
        h.update(k.tag);
        return h.final();
    }
    pub fn eql(_: KeyContext, a: Key, b: Key) bool {
        return a.account_id == b.account_id and std.mem.eql(u8, a.tag, b.tag);
    }
};

/// The in-RAM half of tag traversal.
pub const TagHeads = struct {
    gpa: std.mem.Allocator,
    mutex: os.Mutex = .{},
    map: std.HashMapUnmanaged(Key, Heads, KeyContext, 80) = .empty,

    pub fn init(gpa: std.mem.Allocator) TagHeads {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *TagHeads) void {
        var it = self.map.keyIterator();
        while (it.next()) |k| self.gpa.free(k.tag);
        self.map.deinit(self.gpa);
    }

    /// Current head for one class, or `none`.
    pub fn head(self: *TagHeads, account_id: u32, tag: []const u8, class: config.Class) Location {
        self.mutex.lock();
        defer self.mutex.unlock();
        const h = self.map.get(.{ .account_id = account_id, .tag = tag }) orelse return loc_mod.none;
        return .{ .raw = h[class] };
    }

    pub fn heads(self: *TagHeads, account_id: u32, tag: []const u8) Heads {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.map.get(.{ .account_id = account_id, .tag = tag }) orelse @splat(0);
    }

    /// Points the class chain at `loc`, returning what it pointed at before —
    /// which is exactly the `prev_chain_ptr` the new record must carry.
    ///
    /// Advancing the head and learning the previous value must be one atomic
    /// step, or two concurrent writers could both link to the same predecessor
    /// and silently drop one of themselves from the chain.
    pub fn push(
        self: *TagHeads,
        account_id: u32,
        tag: []const u8,
        class: config.Class,
        loc: Location,
    ) !Location {
        self.mutex.lock();
        defer self.mutex.unlock();

        const gop = try self.map.getOrPut(self.gpa, .{ .account_id = account_id, .tag = tag });
        if (!gop.found_existing) {
            // The map owns its tag bytes; the caller's slice is borrowed.
            const owned = self.gpa.dupe(u8, tag) catch |e| {
                _ = self.map.remove(.{ .account_id = account_id, .tag = tag });
                return e;
            };
            gop.key_ptr.* = .{ .account_id = account_id, .tag = owned };
            gop.value_ptr.* = @splat(0);
        }
        const prev = gop.value_ptr.*[class];
        gop.value_ptr.*[class] = loc.raw;
        return .{ .raw = prev };
    }

    /// Restores one head directly. Used by recovery, which replays records in
    /// sequence order and so naturally ends with the newest as head.
    pub fn set(
        self: *TagHeads,
        account_id: u32,
        tag: []const u8,
        class: config.Class,
        loc: Location,
    ) !void {
        _ = try self.push(account_id, tag, class, loc);
    }

    pub const Stats = struct {
        pairs: u64,
        bytes: u64,
    };

    /// Approximate resident cost. The claim being checked is that this stays
    /// proportional to distinct tags, not to entry count.
    pub fn stats(self: *TagHeads) Stats {
        self.mutex.lock();
        defer self.mutex.unlock();

        var tag_bytes: u64 = 0;
        var it = self.map.keyIterator();
        while (it.next()) |k| tag_bytes += k.tag.len;

        const entry_overhead = @sizeOf(Key) + @sizeOf(Heads) + 1; // + metadata byte
        return .{
            .pairs = self.map.count(),
            .bytes = self.map.capacity() * entry_overhead + tag_bytes,
        };
    }
};

/// Where a paginated walk resumes. Opaque to callers; the store signs it before
/// handing it out so it cannot be forged or replayed against another account.
pub const Cursor = struct {
    /// Next location to visit per class. Zero means that chain is finished.
    next: [config.class_count]u64 = @splat(0),
    /// Sequence number of the last emitted record, so a resumed walk cannot
    /// re-emit it.
    last_seq: u64 = std.math.maxInt(u64),

    pub fn isStart(c: Cursor) bool {
        return c.last_seq == std.math.maxInt(u64);
    }

    pub fn exhausted(c: Cursor) bool {
        for (c.next) |n| if (n != 0) return false;
        return true;
    }
};

/// One position in a chain walk.
const Hop = struct { loc: Location, seq: u64, len: u32 };

pub const WalkResult = struct {
    emitted: u32,
    /// Records read, including those skipped as superseded. Bounded by the hop
    /// budget, which is what stops a free operation becoming a disk scan.
    hops: u32,
    cursor: Cursor,
    /// True when the result set ran out rather than the budget.
    complete: bool,
};

/// Walks the chains for one tag, newest first, emitting live records.
///
/// `emit` receives each surviving record and must not retain the slices, which
/// borrow a scratch buffer reused per hop.
pub fn walk(
    heads_map: *TagHeads,
    idx: *index_mod.Index,
    segs: *segment.SegmentSet,
    gpa: std.mem.Allocator,
    account_id: u32,
    tag: []const u8,
    now: u32,
    start: Cursor,
    limit: u32,
    ctx: anytype,
    comptime emit: anytype,
) (Error || ErrSetOf(@TypeOf(emit)))!WalkResult {
    var cur: Cursor = if (start.isStart())
        .{ .next = heads_map.heads(account_id, tag), .last_seq = std.math.maxInt(u64) }
    else
        start;

    var buf = try gpa.alloc(u8, record.max_record_bytes);
    defer gpa.free(buf);

    var out: WalkResult = .{ .emitted = 0, .hops = 0, .cursor = cur, .complete = false };

    // One decoded record per class, the merge frontier.
    var front: [config.class_count]?Hop = @splat(null);

    // Load the first candidate of each live chain.
    for (0..config.class_count) |c| {
        if (cur.next[c] == 0) continue;
        front[c] = loadHop(segs, buf, .{ .raw = cur.next[c] }) catch |e| switch (e) {
            // The segment is gone, so every record from here back in this class
            // has expired. Correct to stop, per the per-class chain argument.
            error.SegmentNotFound, error.CorruptRecord => blk: {
                cur.next[c] = 0;
                break :blk null;
            },
            else => return e,
        };
        out.hops += 1;
    }

    var candidate_tags: [config.max_tags]record.Tag = undefined;

    while (out.emitted < limit and out.hops <= config.tag_hop_budget) {
        // Pick the newest frontier entry.
        var pick: ?config.Class = null;
        var best_seq: u64 = 0;
        for (0..config.class_count) |c| {
            const f = front[c] orelse continue;
            if (pick == null or f.seq > best_seq) {
                pick = @intCast(c);
                best_seq = f.seq;
            }
        }
        const class = pick orelse {
            out.complete = true;
            break;
        };
        const f = front[class].?;

        // Re-read: the shared buffer now holds whichever class was loaded last.
        const len = segs.readRecord(f.loc, buf) catch |e| switch (e) {
            error.SegmentNotFound, error.CorruptRecord => {
                front[class] = null;
                cur.next[class] = 0;
                continue;
            },
            else => return e,
        };
        const rec = record.decode(buf[0..len], &candidate_tags) catch {
            front[class] = null;
            cur.next[class] = 0;
            continue;
        };

        // Advance this chain before doing anything that can fail, so the cursor
        // is always consistent with what has been consumed.
        const prev = prevFor(rec, tag) orelse loc_mod.none;
        cur.next[class] = prev.raw;

        const survives = rec.seq < cur.last_seq and
            !rec.tombstone and
            rec.expires_at > now and
            isCurrent(idx, rec, f.loc, now);

        if (survives) {
            try emit(ctx, f.loc, rec);
            out.emitted += 1;
            cur.last_seq = rec.seq;
        }

        // Refill this class's frontier slot.
        if (prev.isNone()) {
            front[class] = null;
        } else {
            front[class] = loadHop(segs, buf, prev) catch |e| switch (e) {
                error.SegmentNotFound, error.CorruptRecord => blk: {
                    cur.next[class] = 0;
                    break :blk null;
                },
                else => return e,
            };
            out.hops += 1;
        }
    }

    if (cur.exhausted()) out.complete = true;
    out.cursor = cur;
    return out;
}

fn loadHop(segs: *segment.SegmentSet, buf: []u8, loc: Location) Error!?Hop {
    const len = try segs.readRecord(loc, buf);
    var tags: [config.max_tags]record.Tag = undefined;
    const rec = record.decode(buf[0..len], &tags) catch return error.CorruptRecord;
    return .{ .loc = loc, .seq = rec.seq, .len = len };
}

/// The back-pointer this record carries for `tag`.
fn prevFor(rec: record.Record, tag: []const u8) ?Location {
    for (rec.tags) |t| {
        if (std.mem.eql(u8, t.text, tag)) return t.prev;
    }
    return null;
}

/// True when the index still considers this exact record the live version of its
/// name. False for anything superseded by a later write or removed.
fn isCurrent(idx: *index_mod.Index, rec: record.Record, loc: Location, now: u32) bool {
    const h = idx.hash(rec.account_id, rec.name);
    var cands: [8]index_mod.Candidate = undefined;
    for (idx.candidates(h, now, &cands)) |c| {
        if (c.loc.eql(loc)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "push returns the previous head, which is what the record must store" {
    var th = TagHeads.init(testing.allocator);
    defer th.deinit();

    const a = Location.init(0, 1, 100);
    const b = Location.init(0, 1, 200);

    try testing.expect((try th.push(1, "ci", 0, a)).isNone());
    const prev = try th.push(1, "ci", 0, b);
    try testing.expect(prev.eql(a));
    try testing.expect(th.head(1, "ci", 0).eql(b));
}

test "each class keeps its own head for the same tag" {
    var th = TagHeads.init(testing.allocator);
    defer th.deinit();

    const l0 = Location.init(0, 1, 100);
    const l2 = Location.init(2, 5, 300);
    _ = try th.push(1, "shared", 0, l0);
    _ = try th.push(1, "shared", 2, l2);

    try testing.expect(th.head(1, "shared", 0).eql(l0));
    try testing.expect(th.head(1, "shared", 2).eql(l2));
    try testing.expect(th.head(1, "shared", 1).isNone());
    try testing.expect(th.head(1, "shared", 3).isNone());

    // Four pointers, one map entry.
    try testing.expectEqual(@as(u64, 1), th.stats().pairs);
}

test "accounts do not share chains" {
    var th = TagHeads.init(testing.allocator);
    defer th.deinit();

    const a = Location.init(0, 1, 100);
    const b = Location.init(0, 1, 200);
    _ = try th.push(1, "tag", 0, a);
    _ = try th.push(2, "tag", 0, b);

    try testing.expect(th.head(1, "tag", 0).eql(a));
    try testing.expect(th.head(2, "tag", 0).eql(b));
    try testing.expectEqual(@as(u64, 2), th.stats().pairs);
}

test "memory tracks distinct tags, not entry count" {
    var th = TagHeads.init(testing.allocator);
    defer th.deinit();

    // 50 tags, then a million pushes across them. Cost must not follow pushes.
    var tag_buf: [16]u8 = undefined;
    var i: u32 = 0;
    while (i < 50) : (i += 1) {
        const tag = try std.fmt.bufPrint(&tag_buf, "tag{d}", .{i});
        _ = try th.push(1, tag, 0, Location.init(0, 1, 64));
    }
    const after_50 = th.stats();

    var n: u32 = 0;
    while (n < 20_000) : (n += 1) {
        const tag = try std.fmt.bufPrint(&tag_buf, "tag{d}", .{n % 50});
        _ = try th.push(1, tag, 0, Location.init(0, 1, 64 + (n % 1000) * 64));
    }
    const after_many = th.stats();

    try testing.expectEqual(after_50.pairs, after_many.pairs);
    try testing.expectEqual(after_50.bytes, after_many.bytes);
    try testing.expectEqual(@as(u64, 50), after_many.pairs);
}

test "the tag map owns its keys, so borrowed slices are safe to reuse" {
    var th = TagHeads.init(testing.allocator);
    defer th.deinit();

    var scratch: [16]u8 = undefined;
    const tag = try std.fmt.bufPrint(&scratch, "ephemeral", .{});
    _ = try th.push(1, tag, 0, Location.init(0, 1, 100));

    // Scribble over the caller's buffer; the map must be unaffected.
    @memset(&scratch, 'X');
    try testing.expect(th.head(1, "ephemeral", 0).eql(Location.init(0, 1, 100)));
}

test "cursor start and exhaustion states are distinguishable" {
    var c: Cursor = .{};
    try testing.expect(c.isStart());
    try testing.expect(c.exhausted());

    c.next[1] = 42;
    try testing.expect(!c.exhausted());

    c.next[1] = 0;
    c.last_seq = 10;
    try testing.expect(!c.isStart());
    try testing.expect(c.exhausted());
}
