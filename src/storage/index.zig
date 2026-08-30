//! The index (docs/04-storage.md, D11, D28, D32).
//!
//! An open-addressed hash table holding **no names**. Every read touches disk for
//! the body anyway, so the full name is verified against the record already being
//! fetched and storing it in RAM would buy nothing. A slot is 20 bytes:
//!
//! | bytes | field                                       |
//! |-------|---------------------------------------------|
//! | 8     | hash of (account_id, name), SipHash-1-3     |
//! | 8     | packed location                             |
//! | 4     | expires_at, unix seconds                     |
//!
//! ## Structure of arrays
//!
//! The three fields live in parallel arrays rather than a struct array. Two
//! reasons: it makes a slot *exactly* 20 bytes with no padding (a 20-byte struct
//! would be padded to 24, blowing the memory budget by 20%), and a probe walks
//! only the hash array, so a 64-byte cache line carries 8 probe steps instead of 3.
//!
//! ## Three slot states, not two
//!
//! The subtle part, and what D32 settled. Open addressing cannot simply blank a
//! removed slot — that severs the probe sequence and orphans everything stored
//! past it. So *empty* and *dead* must be distinguishable:
//!
//! | state | hash | expires_at   | probe        | insert          |
//! |-------|------|--------------|--------------|-----------------|
//! | empty | 0    | 0            | terminates   | may occupy      |
//! | live  | != 0 | in future    | continues    | must not touch  |
//! | dead  | != 0 | in past      | **continues**| may reuse       |
//!
//! Removal keeps the hash and forces `expires_at` to 0, so the probe still walks
//! through. Expired and deleted slots are therefore indistinguishable, which is
//! exactly what `03-data-model.md` promises callers.
//!
//! ## Concurrency contract
//!
//! Shard locks protect table *structure* and are held only for memory work,
//! never across disk I/O. They do not serialise same-key mutations: verifying a
//! name requires a disk read, and the index cannot check names. The store is
//! responsible for serialising mutations to one key (see `store.zig` key
//! stripes). Every mutating call here still re-validates against an expected
//! location, so a stale hint degrades to a re-probe rather than corruption.

const std = @import("std");
const config = @import("config.zig");
const loc_mod = @import("location.zig");
const os_mod = @import("os.zig");
const Location = loc_mod.Location;

const Hasher = std.hash.SipHash64(1, 3);

/// A hash of zero marks an empty slot, so a real zero is remapped. Collisions
/// with this value are resolved by disk verification like any other.
const empty_hash: u64 = 0;

pub const Candidate = struct {
    slot: u32,
    loc: Location,
    expires_at: u32,
};

/// How an upsert resolved. Distinguishes reuse from growth so tests can assert
/// the table is behaving, not just returning the right answers.
pub const Upsert = enum {
    /// Updated the slot the caller pointed at.
    updated_in_place,
    /// The hint was stale; re-probed and updated the correct slot.
    updated_after_reprobe,
    /// Occupied a fresh or dead slot.
    inserted,
};

pub const Stats = struct {
    live: u64,
    dead: u64,
    capacity: u64,
    bytes: u64,

    /// Occupancy is what governs probe length and admission control: a dead slot
    /// still consumes a probe position.
    pub fn occupancy(s: Stats) f64 {
        if (s.capacity == 0) return 0;
        return @as(f64, @floatFromInt(s.live + s.dead)) / @as(f64, @floatFromInt(s.capacity));
    }

    /// Bytes of index per *live* entry, which is what the memory budget claims.
    pub fn bytesPerLiveEntry(s: Stats) f64 {
        if (s.live == 0) return 0;
        return @as(f64, @floatFromInt(s.bytes)) / @as(f64, @floatFromInt(s.live));
    }
};

const Shard = struct {
    mutex: os_mod.Mutex = .{},
    hashes: []u64 = &.{},
    locs: []u64 = &.{},
    exps: []u32 = &.{},
    live: u32 = 0,
    dead: u32 = 0,
    /// Set when the index is sized from a fixed memory budget: the table never
    /// grows, and admission control rejects new entries instead.
    fixed: bool = false,

    fn capacity(s: *const Shard) u32 {
        return @intCast(s.hashes.len);
    }

    fn alloc(s: *Shard, gpa: std.mem.Allocator, n: u32) !void {
        s.hashes = try gpa.alloc(u64, n);
        s.locs = try gpa.alloc(u64, n);
        s.exps = try gpa.alloc(u32, n);
        @memset(s.hashes, empty_hash);
        @memset(s.locs, 0);
        @memset(s.exps, 0);
    }

    fn free(s: *Shard, gpa: std.mem.Allocator) void {
        gpa.free(s.hashes);
        gpa.free(s.locs);
        gpa.free(s.exps);
        s.hashes = &.{};
        s.locs = &.{};
        s.exps = &.{};
    }

    /// Multiply-shift bucketing, so capacity need not be a power of two. Uses
    /// the high bits; the low bits already chose the shard.
    fn bucket(s: *const Shard, hash: u64) u32 {
        const h: u128 = hash >> shard_bits;
        return @intCast((h * @as(u128, s.capacity())) >> bucket_shift);
    }

    fn isDead(s: *const Shard, i: u32, now: u32) bool {
        return s.exps[i] <= now;
    }
};

const shard_bits = 6; // 64 shards
const bucket_shift = 64 - shard_bits;
comptime {
    std.debug.assert(@as(u32, 1) << shard_bits == config.index_shards);
}

pub const Index = struct {
    gpa: std.mem.Allocator,
    shards: [config.index_shards]Shard,
    key: [16]u8,

    pub fn init(gpa: std.mem.Allocator, opts: config.Options) !Index {
        var self: Index = .{
            .gpa = gpa,
            .shards = @splat(.{}),
            .key = opts.index_hash_key,
        };

        // A configured memory ceiling is sized up front rather than grown into.
        // That makes index memory predictable instead of emergent, and it is the
        // only way the documented bytes-per-entry figure is ever exactly true:
        // a table that grows by doubling spends most of its life half-empty.
        const per_shard: u32 = if (opts.max_index_bytes > 0) blk: {
            const slots = opts.max_index_bytes / config.index_slot_bytes / config.index_shards;
            if (slots == 0) return error.IndexBudgetTooSmall;
            break :blk @intCast(@min(slots, std.math.maxInt(u32) / 2));
        } else config.index_initial_slots_per_shard;

        var made: usize = 0;
        errdefer for (self.shards[0..made]) |*s| s.free(gpa);
        for (&self.shards) |*s| {
            try s.alloc(gpa, per_shard);
            s.fixed = opts.max_index_bytes > 0;
            made += 1;
        }
        return self;
    }

    pub fn deinit(self: *Index) void {
        for (&self.shards) |*s| s.free(self.gpa);
    }

    /// Keyed so hash-flooding is not a remote denial-of-service vector.
    pub fn hash(self: *const Index, account_id: u32, name: []const u8) u64 {
        var h = Hasher.init(&self.key);
        h.update(std.mem.asBytes(&account_id));
        h.update(name);
        const v = h.finalInt();
        return if (v == empty_hash) 1 else v; // reserve 0 for "empty"
    }

    fn shardOf(hash_v: u64) u32 {
        return @intCast(hash_v & (config.index_shards - 1));
    }

    /// Live slots whose hash matches. Several may match: different names can
    /// collide, and only a disk read can tell them apart. The caller verifies.
    ///
    /// Dead slots are skipped but do not stop the walk.
    pub fn candidates(self: *Index, hash_v: u64, now: u32, out: []Candidate) []Candidate {
        const s = &self.shards[shardOf(hash_v)];
        s.mutex.lock();
        defer s.mutex.unlock();

        var n: usize = 0;
        var i = s.bucket(hash_v);
        var steps: u32 = 0;
        const cap = s.capacity();
        while (steps < cap) : (steps += 1) {
            const h = s.hashes[i];
            if (h == empty_hash) break;
            if (h == hash_v and !s.isDead(i, now)) {
                if (n == out.len) break;
                out[n] = .{ .slot = i, .loc = .{ .raw = s.locs[i] }, .expires_at = s.exps[i] };
                n += 1;
            }
            i += 1;
            if (i == cap) i = 0;
        }
        return out[0..n];
    }

    /// Inserts or updates. `hint` is the slot a previous `candidates` call
    /// returned, with `expect` the location it held; when both still agree the
    /// update lands directly, otherwise the shard is re-probed.
    ///
    /// A stale hint is always safe — it degrades to a re-probe.
    pub fn upsert(
        self: *Index,
        hash_v: u64,
        hint: ?u32,
        expect: Location,
        new_loc: Location,
        new_expires: u32,
        now: u32,
    ) !Upsert {
        const s = &self.shards[shardOf(hash_v)];
        s.mutex.lock();
        defer s.mutex.unlock();

        if (hint) |i| {
            if (i < s.capacity() and s.hashes[i] == hash_v and s.locs[i] == expect.raw) {
                const was_dead = s.isDead(i, now);
                s.locs[i] = new_loc.raw;
                s.exps[i] = new_expires;
                if (was_dead) {
                    s.dead -= 1;
                    s.live += 1;
                }
                return .updated_in_place;
            }
        }

        if (!expect.isNone()) {
            // The caller believed a specific record was current. Find it by
            // location, which is unique, so a moved slot is still matched.
            if (self.findByLocation(s, hash_v, expect)) |i| {
                const was_dead = s.isDead(i, now);
                s.locs[i] = new_loc.raw;
                s.exps[i] = new_expires;
                if (was_dead) {
                    s.dead -= 1;
                    s.live += 1;
                }
                return .updated_after_reprobe;
            }
        }

        try self.ensureRoom(s, now);
        const i = self.claimSlot(s, hash_v, now);
        s.hashes[i] = hash_v;
        s.locs[i] = new_loc.raw;
        s.exps[i] = new_expires;
        s.live += 1;
        return .inserted;
    }

    fn findByLocation(_: *Index, s: *Shard, hash_v: u64, want: Location) ?u32 {
        var i = s.bucket(hash_v);
        var steps: u32 = 0;
        const cap = s.capacity();
        while (steps < cap) : (steps += 1) {
            const h = s.hashes[i];
            if (h == empty_hash) return null;
            if (h == hash_v and s.locs[i] == want.raw) return i;
            i += 1;
            if (i == cap) i = 0;
        }
        return null;
    }

    /// First reusable position on the probe path: a dead slot if one appears
    /// before the first empty, otherwise the empty.
    fn claimSlot(_: *Index, s: *Shard, hash_v: u64, now: u32) u32 {
        var i = s.bucket(hash_v);
        const cap = s.capacity();
        var steps: u32 = 0;
        while (steps < cap) : (steps += 1) {
            if (s.hashes[i] == empty_hash) return i;
            if (s.isDead(i, now)) {
                s.dead -= 1; // reused in place
                return i;
            }
            i += 1;
            if (i == cap) i = 0;
        }
        unreachable; // ensureRoom guarantees a free position
    }

    /// Marks a slot dead: keeps the hash so probes still pass through, clears
    /// the location, and forces expiry into the past. Deletion and expiry
    /// converge on this single representation.
    ///
    /// Returns false if the slot no longer holds `expect`, meaning someone else
    /// changed it and the caller's view was stale.
    pub fn kill(self: *Index, hash_v: u64, hint: ?u32, expect: Location, now: u32) bool {
        const s = &self.shards[shardOf(hash_v)];
        s.mutex.lock();
        defer s.mutex.unlock();

        const i = blk: {
            if (hint) |h| {
                if (h < s.capacity() and s.hashes[h] == hash_v and s.locs[h] == expect.raw) break :blk h;
            }
            break :blk self.findByLocation(s, hash_v, expect) orelse return false;
        };

        if (s.isDead(i, now)) return false; // already gone
        s.locs[i] = loc_mod.none.raw;
        s.exps[i] = 0;
        s.live -= 1;
        s.dead += 1;
        return true;
    }

    /// Reconciles the counters with the clock. Slots whose lifetime has passed
    /// are still counted live until something notices, so expiry-driven rebuild
    /// needs a sweep. Cheap: touches only the exps array.
    pub fn sweepExpired(self: *Index, now: u32) u64 {
        var swept: u64 = 0;
        for (&self.shards) |*s| {
            s.mutex.lock();
            defer s.mutex.unlock();
            for (s.hashes, 0..) |h, i| {
                if (h == empty_hash) continue;
                if (s.exps[i] != 0 and s.exps[i] <= now) {
                    s.locs[i] = loc_mod.none.raw;
                    s.exps[i] = 0;
                    s.live -= 1;
                    s.dead += 1;
                    swept += 1;
                }
            }
        }
        return swept;
    }

    fn ensureRoom(self: *Index, s: *Shard, now: u32) !void {
        const cap = s.capacity();
        const occupied = @as(u64, s.live) + s.dead;

        // Rebuilding at the same capacity is enough whenever dead slots are what
        // filled the table. That is index-only work: no disk, no compaction.
        const dead_heavy = @as(u64, s.dead) * config.index_rebuild_dead_den >
            @as(u64, cap) * config.index_rebuild_dead_num;

        const at_limit = (occupied + 1) * config.index_max_load_den >
            @as(u64, cap) * config.index_max_load_num;

        if (!at_limit and !dead_heavy) return;

        if (at_limit and !dead_heavy) {
            if (s.fixed) return error.IndexFull; // admission control, not growth
            return self.resize(s, cap * 2, now);
        }
        // Dead-heavy: reclaim in place. If that still leaves no room, grow.
        try self.resize(s, cap, now);
        const still_full = (@as(u64, s.live) + s.dead + 1) * config.index_max_load_den >
            @as(u64, s.capacity()) * config.index_max_load_num;
        if (still_full) {
            if (s.fixed) return error.IndexFull;
            return self.resize(s, s.capacity() * 2, now);
        }
    }

    /// Reinserts live entries into a fresh table of `new_cap`, discarding dead
    /// slots. Used both to grow and to rebuild in place.
    fn resize(self: *Index, s: *Shard, new_cap: u32, now: u32) !void {
        const old_h = s.hashes;
        const old_l = s.locs;
        const old_e = s.exps;

        var fresh: Shard = .{ .fixed = s.fixed };
        try fresh.alloc(self.gpa, new_cap);

        for (old_h, 0..) |h, i| {
            if (h == empty_hash) continue;
            if (old_e[i] == 0 or old_e[i] <= now) continue; // dead: dropped
            var j = fresh.bucket(h);
            while (fresh.hashes[j] != empty_hash) {
                j += 1;
                if (j == new_cap) j = 0;
            }
            fresh.hashes[j] = h;
            fresh.locs[j] = old_l[i];
            fresh.exps[j] = old_e[i];
            fresh.live += 1;
        }

        self.gpa.free(old_h);
        self.gpa.free(old_l);
        self.gpa.free(old_e);

        s.hashes = fresh.hashes;
        s.locs = fresh.locs;
        s.exps = fresh.exps;
        s.live = fresh.live;
        s.dead = 0;
    }

    pub fn stats(self: *Index) Stats {
        var out: Stats = .{ .live = 0, .dead = 0, .capacity = 0, .bytes = 0 };
        for (&self.shards) |*s| {
            s.mutex.lock();
            defer s.mutex.unlock();
            out.live += s.live;
            out.dead += s.dead;
            out.capacity += s.capacity();
        }
        out.bytes = out.capacity * config.index_slot_bytes;
        return out;
    }

    /// True when new entries must be refused. Overwrites and deletes stay
    /// allowed: they consume no additional slot, and deleting is how an operator
    /// recovers from this state.
    pub fn admissionClosed(self: *Index) bool {
        for (&self.shards) |*s| {
            s.mutex.lock();
            defer s.mutex.unlock();
            if (!s.fixed) continue;
            const occupied = @as(u64, s.live) + s.dead;
            if ((occupied + 1) * config.index_max_load_den >
                @as(u64, s.capacity()) * config.index_max_load_num) return true;
        }
        return false;
    }

    // -- snapshot support (used by snapshot.zig) --

    pub fn shardCount(_: *const Index) u32 {
        return config.index_shards;
    }

    /// Borrows a shard's arrays under its lock. The callback runs with the lock
    /// held, which is what makes a shard-at-a-time snapshot consistent without
    /// stopping the world.
    pub fn withShard(
        self: *Index,
        idx: u32,
        ctx: anytype,
        comptime f: fn (@TypeOf(ctx), hashes: []const u64, locs: []const u64, exps: []const u32) anyerror!void,
    ) !void {
        const s = &self.shards[idx];
        s.mutex.lock();
        defer s.mutex.unlock();
        try f(ctx, s.hashes, s.locs, s.exps);
    }

    /// Restores one shard wholesale from a snapshot. Only valid on a fresh index.
    pub fn loadShard(
        self: *Index,
        idx: u32,
        hashes: []const u64,
        locs: []const u64,
        exps: []const u32,
        now: u32,
    ) !void {
        const s = &self.shards[idx];
        s.mutex.lock();
        defer s.mutex.unlock();

        if (hashes.len != s.capacity()) {
            s.free(self.gpa);
            try s.alloc(self.gpa, @intCast(hashes.len));
        }
        @memcpy(s.hashes, hashes);
        @memcpy(s.locs, locs);
        @memcpy(s.exps, exps);

        s.live = 0;
        s.dead = 0;
        for (s.hashes, 0..) |h, i| {
            if (h == empty_hash) continue;
            if (s.exps[i] == 0 or s.exps[i] <= now) s.dead += 1 else s.live += 1;
        }
    }
};

// ---------------------------------------------------------------------------

const testing = std.testing;
const now0: u32 = 1_000_000;

fn testIndex(gpa: std.mem.Allocator) !Index {
    return Index.init(gpa, .{ .index_hash_key = @splat(7) });
}

fn put(idx: *Index, account: u32, name: []const u8, l: Location, exp: u32) !Upsert {
    const h = idx.hash(account, name);
    return idx.upsert(h, null, loc_mod.none, l, exp, now0);
}

fn get(idx: *Index, account: u32, name: []const u8, now: u32) ?Candidate {
    var buf: [8]Candidate = undefined;
    const c = idx.candidates(idx.hash(account, name), now, &buf);
    return if (c.len == 0) null else c[0];
}

test "a slot is exactly 20 bytes, which a struct array would not have been" {
    // 8 + 8 + 4 with no padding. A struct{u64,u64,u32} pads to 24, which would
    // be 20% over the memory budget.
    try testing.expectEqual(@as(u32, 20), config.index_slot_bytes);
    try testing.expectEqual(@as(usize, 20), @sizeOf(u64) + @sizeOf(u64) + @sizeOf(u32));
}

test "insert then find" {
    var idx = try testIndex(testing.allocator);
    defer idx.deinit();

    const l = Location.init(1, 5, 64);
    try testing.expectEqual(Upsert.inserted, try put(&idx, 1, "alpha", l, now0 + 100));

    const c = get(&idx, 1, "alpha", now0) orelse return error.NotFound;
    try testing.expect(c.loc.eql(l));
    try testing.expectEqual(now0 + 100, c.expires_at);
}

test "accounts are isolated: the same name in two accounts does not collide" {
    var idx = try testIndex(testing.allocator);
    defer idx.deinit();

    const a = Location.init(0, 1, 100);
    const b = Location.init(0, 1, 200);
    _ = try put(&idx, 1, "shared", a, now0 + 100);
    _ = try put(&idx, 2, "shared", b, now0 + 100);

    try testing.expect((get(&idx, 1, "shared", now0).?).loc.eql(a));
    try testing.expect((get(&idx, 2, "shared", now0).?).loc.eql(b));
    try testing.expectEqual(@as(u64, 2), idx.stats().live);
}

test "expiry makes an entry absent without anyone doing anything" {
    var idx = try testIndex(testing.allocator);
    defer idx.deinit();

    _ = try put(&idx, 1, "ttl", Location.init(0, 1, 64), now0 + 50);
    try testing.expect(get(&idx, 1, "ttl", now0) != null);
    try testing.expect(get(&idx, 1, "ttl", now0 + 49) != null);
    try testing.expect(get(&idx, 1, "ttl", now0 + 50) == null); // boundary is exclusive
    try testing.expect(get(&idx, 1, "ttl", now0 + 51) == null);
}

test "kill makes an entry absent and is not repeatable" {
    var idx = try testIndex(testing.allocator);
    defer idx.deinit();

    const l = Location.init(0, 1, 64);
    _ = try put(&idx, 1, "gone", l, now0 + 100);
    const h = idx.hash(1, "gone");

    try testing.expect(idx.kill(h, null, l, now0));
    try testing.expect(get(&idx, 1, "gone", now0) == null);
    try testing.expect(!idx.kill(h, null, l, now0)); // already dead

    const st = idx.stats();
    try testing.expectEqual(@as(u64, 0), st.live);
    try testing.expectEqual(@as(u64, 1), st.dead);
}

test "kill refuses when the caller's view is stale" {
    var idx = try testIndex(testing.allocator);
    defer idx.deinit();

    const old = Location.init(0, 1, 64);
    const new = Location.init(0, 1, 128);
    _ = try put(&idx, 1, "moved", old, now0 + 100);
    const h = idx.hash(1, "moved");

    // Someone overwrote it; a delete holding the old location must not succeed.
    _ = try idx.upsert(h, null, old, new, now0 + 200, now0);
    try testing.expect(!idx.kill(h, null, old, now0));
    try testing.expect(idx.kill(h, null, new, now0));
}

test "overwrite reuses the same slot rather than adding one" {
    var idx = try testIndex(testing.allocator);
    defer idx.deinit();

    const h = idx.hash(1, "over");
    const a = Location.init(0, 1, 64);
    const b = Location.init(2, 9, 4096);

    _ = try idx.upsert(h, null, loc_mod.none, a, now0 + 100, now0);
    const c1 = get(&idx, 1, "over", now0).?;

    const r = try idx.upsert(h, c1.slot, a, b, now0 + 999, now0);
    try testing.expectEqual(Upsert.updated_in_place, r);

    const c2 = get(&idx, 1, "over", now0).?;
    try testing.expect(c2.loc.eql(b));
    try testing.expectEqual(now0 + 999, c2.expires_at);
    try testing.expectEqual(@as(u64, 1), idx.stats().live);
}

test "a stale hint degrades to a re-probe instead of corrupting" {
    var idx = try testIndex(testing.allocator);
    defer idx.deinit();

    const h = idx.hash(1, "hint");
    const a = Location.init(0, 1, 64);
    const b = Location.init(0, 1, 128);
    _ = try idx.upsert(h, null, loc_mod.none, a, now0 + 100, now0);

    // Hint points at a slot that does not hold this key.
    const r = try idx.upsert(h, 12345, a, b, now0 + 200, now0);
    try testing.expectEqual(Upsert.updated_after_reprobe, r);
    try testing.expect((get(&idx, 1, "hint", now0).?).loc.eql(b));
    try testing.expectEqual(@as(u64, 1), idx.stats().live);
}

test "dead slots stay probe-transparent: entries behind them remain reachable" {
    // The bug D32 exists to prevent. Force many keys into one shard, delete the
    // earlier ones, and confirm the later ones are still found.
    var idx = try Index.init(testing.allocator, .{ .index_hash_key = @splat(3) });
    defer idx.deinit();

    var names: [200][16]u8 = undefined;
    var lens: [200]usize = undefined;
    var count: usize = 0;
    var n: u32 = 0;
    // Collect names that all land in shard 0 so they share probe paths.
    while (count < 200 and n < 1_000_000) : (n += 1) {
        const name = try std.fmt.bufPrint(&names[count], "k{d}", .{n});
        if (idx.hash(1, name) & (config.index_shards - 1) == 0) {
            _ = try put(&idx, 1, name, Location.init(0, 1, @intCast(64 + count * 64)), now0 + 100);
            lens[count] = name.len;
            count += 1;
        }
    }
    try testing.expect(count == 200);

    // Delete the first half.
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const name = names[i][0..lens[i]];
        const h = idx.hash(1, name);
        try testing.expect(idx.kill(h, null, Location.init(0, 1, @intCast(64 + i * 64)), now0));
    }

    // Every survivor must still be reachable through the resulting dead slots.
    i = 100;
    while (i < 200) : (i += 1) {
        const name = names[i][0..lens[i]];
        const c = get(&idx, 1, name, now0) orelse {
            std.debug.print("lost entry {d} behind dead slots\n", .{i});
            return error.TestUnexpectedResult;
        };
        try testing.expect(c.loc.eql(Location.init(0, 1, @intCast(64 + i * 64))));
    }
}

test "growth preserves every live entry" {
    var idx = try testIndex(testing.allocator);
    defer idx.deinit();

    const total = 20_000;
    var buf: [32]u8 = undefined;
    var i: u32 = 0;
    while (i < total) : (i += 1) {
        const name = try std.fmt.bufPrint(&buf, "grow/{d}", .{i});
        _ = try put(&idx, 1, name, Location.init(0, 1 + i / 1000, (i % 1000) * 64 + 64), now0 + 1000);
    }

    try testing.expectEqual(@as(u64, total), idx.stats().live);
    try testing.expect(idx.stats().occupancy() <= 0.70);

    i = 0;
    while (i < total) : (i += 1) {
        const name = try std.fmt.bufPrint(&buf, "grow/{d}", .{i});
        const c = get(&idx, 1, name, now0) orelse return error.NotFound;
        try testing.expect(c.loc.eql(Location.init(0, 1 + i / 1000, (i % 1000) * 64 + 64)));
    }
}

test "a dead-heavy shard is rebuilt, reclaiming slots without growing" {
    var idx = try testIndex(testing.allocator);
    defer idx.deinit();

    var buf: [32]u8 = undefined;
    // Churn: insert then delete repeatedly, which manufactures dead slots.
    var round: u32 = 0;
    while (round < 40) : (round += 1) {
        var i: u32 = 0;
        while (i < 500) : (i += 1) {
            const name = try std.fmt.bufPrint(&buf, "churn/{d}/{d}", .{ round, i });
            const l = Location.init(0, 1, (i % 1000) * 64 + 64);
            _ = try put(&idx, 1, name, l, now0 + 100);
            const h = idx.hash(1, name);
            _ = idx.kill(h, null, l, now0);
        }
    }

    const st = idx.stats();
    try testing.expectEqual(@as(u64, 0), st.live);
    // Rebuild must have kept the table from ballooning on pure churn.
    try testing.expect(st.capacity < 200_000);
}

test "a fixed budget refuses new entries instead of growing past it" {
    // 64 shards * 128 slots * 20 bytes.
    var idx = try Index.init(testing.allocator, .{
        .index_hash_key = @splat(1),
        .max_index_bytes = config.index_shards * 128 * config.index_slot_bytes,
    });
    defer idx.deinit();

    const cap_before = idx.stats().capacity;
    try testing.expectEqual(@as(u64, config.index_shards * 128), cap_before);

    var buf: [32]u8 = undefined;
    var inserted: u32 = 0;
    var refused = false;
    var i: u32 = 0;
    while (i < 20_000) : (i += 1) {
        const name = try std.fmt.bufPrint(&buf, "cap/{d}", .{i});
        if (put(&idx, 1, name, Location.init(0, 1, 64), now0 + 100)) |_| {
            inserted += 1;
        } else |err| {
            try testing.expectEqual(error.IndexFull, err);
            refused = true;
            break;
        }
    }

    try testing.expect(refused);
    try testing.expectEqual(cap_before, idx.stats().capacity); // never grew
    try testing.expect(inserted > 0);
}

test "at the admission limit the index costs the documented ~29 bytes per entry" {
    // The claim in docs/04-storage.md is 20 bytes at 0.70 load. It holds exactly
    // at the point admission closes, which is the point the budget describes.
    var idx = try Index.init(testing.allocator, .{
        .index_hash_key = @splat(9),
        .max_index_bytes = config.index_shards * 4096 * config.index_slot_bytes,
    });
    defer idx.deinit();

    var buf: [32]u8 = undefined;
    var i: u32 = 0;
    while (i < 1_000_000) : (i += 1) {
        const name = try std.fmt.bufPrint(&buf, "dense/{d}", .{i});
        _ = put(&idx, 1, name, Location.init(0, 1, 64), now0 + 10_000) catch break;
    }

    const st = idx.stats();
    const per = st.bytesPerLiveEntry();
    // 20 / 0.70 = 28.57. Allow the 10% band the exit condition uses.
    try testing.expect(per >= 26.0);
    try testing.expect(per <= 31.9);
}

test "sweepExpired moves lapsed entries to dead" {
    var idx = try testIndex(testing.allocator);
    defer idx.deinit();

    var buf: [32]u8 = undefined;
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        const name = try std.fmt.bufPrint(&buf, "s/{d}", .{i});
        // Half expire early, half late.
        const exp = if (i % 2 == 0) now0 + 10 else now0 + 10_000;
        _ = try put(&idx, 1, name, Location.init(0, 1, 64 + i * 64), exp);
    }

    try testing.expectEqual(@as(u64, 100), idx.stats().live);
    const swept = idx.sweepExpired(now0 + 100);
    try testing.expectEqual(@as(u64, 50), swept);

    const st = idx.stats();
    try testing.expectEqual(@as(u64, 50), st.live);
    try testing.expectEqual(@as(u64, 50), st.dead);
}

test "hash of zero is remapped so it cannot be mistaken for an empty slot" {
    var idx = try testIndex(testing.allocator);
    defer idx.deinit();
    // Cannot force a zero hash directly, so assert the invariant holds broadly.
    var buf: [32]u8 = undefined;
    var i: u32 = 0;
    while (i < 5000) : (i += 1) {
        const name = try std.fmt.bufPrint(&buf, "z/{d}", .{i});
        try testing.expect(idx.hash(i, name) != empty_hash);
    }
}
