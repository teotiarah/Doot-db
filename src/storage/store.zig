//! The store: the engine's public surface, and recovery.
//!
//! Ties together the index (D11), lifetime-class segments (D10), on-disk tag
//! chains (D12), group commit, and snapshot-plus-tail recovery (D17).
//!
//! ## Writes are serialised; reads are not
//!
//! One mutex covers the whole write path. Reads take none.
//!
//! This is a deliberate simplification over finer-grained locking, and it costs
//! almost nothing: appends to a class already serialise on the segment set, group
//! commit already shares one `fsync` across waiting writers, and the per-write CPU
//! work is an encode plus a hash. D14 measured storage at 0.03% of what a request
//! costs end to end, so parallelising the write path optimises the wrong 0.03%
//! while introducing the hardest concurrency in the system.
//!
//! It also dissolves two problems outright. Same-key mutations serialise without
//! the key-stripe locks the index's contract asks for, and a record's tag
//! back-pointers can be published to the chain heads before the record is encoded
//! without racing another writer on the same tag.
//!
//! Durability waiting happens *outside* the lock, which is what lets writers pile
//! up behind one `fsync`.
//!
//! ## Visibility versus durability
//!
//! The index is updated when a write is *ordered*, before it is durable. A reader
//! can therefore observe an entry that a crash would erase. That is deliberate and
//! standard for group commit: the guarantee is that no *acknowledged* write is
//! lost, and an entry in this window has not been acknowledged to anyone. Making
//! visibility wait for `fsync` would serialise readers behind disk latency to
//! remove an anomaly nobody can act on.

const std = @import("std");
const config = @import("config.zig");
const clock_mod = @import("clock.zig");
const os = @import("os.zig");
const loc_mod = @import("location.zig");
const record = @import("record.zig");
const index_mod = @import("index.zig");
const segment = @import("segment.zig");
const commit = @import("commit.zig");
const tagchain = @import("tagchain.zig");
const snapshot_mod = @import("snapshot.zig");

const Location = loc_mod.Location;

pub const Error = error{
    NameInvalid,
    TagInvalid,
    TooManyTags,
    TtlTooShort,
    TtlTooLong,
    BodyTooLarge,
    ContentTypeTooLong,
    /// Index is full and this would be a new entry. Overwrites and deletes are
    /// still accepted, since deleting is how an operator recovers.
    CapacityExhausted,
} || segment.Error || snapshot_mod.Error || tagchain.Error ||
    record.Error || ConfigError || IndexError;

/// Surfaced by `Options.validate`, which runs before anything is opened.
const ConfigError = error{ SegmentTooLarge, SegmentTooSmall, MaxTtlTooSmall };

/// Surfaced by the index: a budget too small to hold one slot per shard, and the
/// admission-control refusal when a fixed-size table is full.
const IndexError = error{ IndexBudgetTooSmall, IndexFull };

pub const Put = struct {
    seq: u64,
    loc: Location,
    expires_at: u32,
    created: bool,
};

pub const Got = struct {
    seq: u64,
    body: []const u8,
    content_type: []const u8,
    created_at: u32,
    expires_at: u32,
    tag_count: u8,
};

pub const Stats = struct {
    index: index_mod.Stats,
    segments: segment.SegmentSet.Stats,
    commit: commit.Committer.Stats,
    tags: tagchain.TagHeads.Stats,
    /// Records whose checksum failed while the index still pointed at them.
    /// Distinct from a torn tail, which is expected after a crash.
    corruptions: u64,
    recovery_ms: u64,
    recovery_records: u64,
};

pub const Store = struct {
    gpa: std.mem.Allocator,
    dir_fd: os.Fd,
    clock: clock_mod.Clock,
    opts: config.Options,

    idx: index_mod.Index,
    segs: segment.SegmentSet,
    com: commit.Committer,
    heads: tagchain.TagHeads,

    write_mutex: os.Mutex = .{},

    corruptions: std.atomic.Value(u64) = .init(0),
    recovery_ms: u64 = 0,
    recovery_records: u64 = 0,
    last_snapshot_at: u32 = 0,

    pub fn open(
        gpa: std.mem.Allocator,
        dir_fd: os.Fd,
        clk: clock_mod.Clock,
        opts: config.Options,
    ) Error!*Store {
        try opts.validate();

        const self = try gpa.create(Store);
        errdefer gpa.destroy(self);

        self.* = .{
            .gpa = gpa,
            .dir_fd = dir_fd,
            .clock = clk,
            .opts = opts,
            .idx = try index_mod.Index.init(gpa, opts),
            .segs = undefined,
            .com = undefined,
            .heads = tagchain.TagHeads.init(gpa),
        };
        errdefer self.idx.deinit();
        errdefer self.heads.deinit();

        self.segs = try segment.SegmentSet.open(gpa, dir_fd, clk, opts);
        errdefer self.segs.deinit();
        self.com = commit.Committer.init(&self.segs);

        try self.recover();
        self.last_snapshot_at = clk.now();
        return self;
    }

    pub fn close(self: *Store) void {
        // Best effort: a failed final snapshot only means a longer replay next
        // time, never lost data.
        self.snapshot() catch {};
        self.segs.deinit();
        self.heads.deinit();
        self.idx.deinit();
        self.gpa.destroy(self);
    }

    // -----------------------------------------------------------------------
    // Recovery
    // -----------------------------------------------------------------------

    /// Loads the snapshot, then replays everything written after it.
    ///
    /// Idempotent: replaying the same tail twice lands the same state, so a crash
    /// *during* recovery is survivable.
    fn recover(self: *Store) Error!void {
        const started = os.monotonicMillis();
        const now = self.clock.now();

        // Unsealed segments have no durable max_expiry, and a torn tail must be
        // cut before anything appends after it.
        try self.segs.resolveUnsealed();

        const loaded = try snapshot_mod.read(self.gpa, self.dir_fd, &self.idx, &self.heads, now);
        const from: [config.class_count]snapshot_mod.OpenState = if (loaded) |l| l.header.open else @splat(.{});
        if (loaded) |l| self.com.resumeFrom(l.header.seq_watermark);

        const replayed = try self.replayTails(from, now);
        self.recovery_records = replayed;
        self.recovery_ms = @intCast(os.monotonicMillis() - started);
    }

    /// Applies every record after the snapshot, in global sequence order.
    ///
    /// The four classes are merged rather than replayed one at a time: within a
    /// class sequence numbers ascend, so a four-way merge on the lowest pending
    /// sequence reproduces the exact global order with constant memory. Replaying
    /// class by class would let an older write from one class overwrite a newer
    /// one from another, and the index has no sequence number to arbitrate with.
    fn replayTails(self: *Store, from: [config.class_count]snapshot_mod.OpenState, now: u32) Error!u64 {
        // Heap-allocated: a `Stream` holds a self-pointer into its own tag array,
        // so copying one by value would leave that pointer aimed at the copy's
        // source.
        var streams: [config.class_count]?*Stream = @splat(null);
        defer for (&streams) |s| if (s) |st| st.destroy();

        for (0..config.class_count) |c| {
            var ids: std.ArrayListUnmanaged(u32) = .empty;
            defer ids.deinit(self.gpa);
            try self.segs.idsOfClass(@intCast(c), &ids);
            if (ids.items.len == 0) continue;

            // Segments below the snapshot's open one are already reflected in it.
            var start_index: usize = 0;
            var start_offset: u32 = segment.header_bytes;
            if (from[c].id != 0) {
                for (ids.items, 0..) |id, i| {
                    if (id == from[c].id) {
                        start_index = i;
                        start_offset = from[c].offset;
                        break;
                    }
                    if (id > from[c].id) {
                        start_index = i;
                        break;
                    }
                }
            }

            // `Stream` copies the id list: `ids` is freed when this iteration
            // ends, and the stream outlives it.
            const st = try Stream.create(self.gpa, &self.segs, ids.items[start_index..], start_offset);
            try st.advance();
            streams[c] = st;
        }

        var applied: u64 = 0;
        var highest_seq: u64 = 0;

        while (true) {
            var pick: ?usize = null;
            var best: u64 = std.math.maxInt(u64);
            for (0..config.class_count) |c| {
                const st = streams[c] orelse continue;
                const cur = st.current orelse continue;
                if (cur.rec.seq < best) {
                    best = cur.rec.seq;
                    pick = c;
                }
            }
            const c = pick orelse break;
            const st = streams[c].?;
            const cur = st.current.?;

            try self.applyRecovered(cur.loc, cur.rec, now);
            if (cur.rec.seq > highest_seq) highest_seq = cur.rec.seq;
            applied += 1;

            try st.advance();
        }

        self.com.resumeFrom(highest_seq);
        // Everything replayed is already on disk, so it is durable by definition.
        for (0..config.class_count) |c| {
            self.com.noteWritten(@intCast(c), highest_seq);
        }
        try self.com.flush();
        return applied;
    }

    /// Applies one replayed record. Later sequence numbers win, which the merge
    /// order guarantees by construction.
    fn applyRecovered(self: *Store, loc: Location, rec: record.Record, now: u32) Error!void {
        const h = self.idx.hash(rec.account_id, rec.name);

        if (rec.tombstone) {
            // Remove whatever the name currently points at. The record it deleted
            // may or may not have been replayed; either way the name must end up
            // absent.
            var buf: [8]index_mod.Candidate = undefined;
            for (self.idx.candidates(h, now, &buf)) |cand| {
                if (try self.nameAt(cand.loc, rec.account_id, rec.name)) {
                    _ = self.idx.kill(h, cand.slot, cand.loc, now);
                    break;
                }
            }
            return;
        }

        const existing = try self.findLive(h, rec.account_id, rec.name, now);
        _ = try self.idx.upsert(
            h,
            if (existing) |e| e.slot else null,
            if (existing) |e| e.loc else loc_mod.none,
            loc,
            rec.expires_at,
            now,
        );

        // Chain heads must end up on the newest record per (tag, class). Replay is
        // in ascending sequence order, so the last write wins naturally.
        for (rec.tags) |t| {
            try self.heads.set(rec.account_id, t.text, rec.class, loc);
        }
    }

    // -----------------------------------------------------------------------
    // Write path
    // -----------------------------------------------------------------------

    pub fn put(
        self: *Store,
        account_id: u32,
        name: []const u8,
        body: []const u8,
        content_type: []const u8,
        tags: []const []const u8,
        ttl_s: u32,
    ) Error!Put {
        try validateName(name);
        if (tags.len > config.max_tags) return error.TooManyTags;
        for (tags) |t| try validateTag(t);
        if (body.len > config.max_body_bytes) return error.BodyTooLarge;
        if (content_type.len > config.max_content_type_bytes) return error.ContentTypeTooLong;
        if (ttl_s < config.min_ttl_s) return error.TtlTooShort;
        if (ttl_s > self.opts.max_ttl_s) return error.TtlTooLong;

        const now = self.clock.now();
        const expires_at = now + ttl_s;
        const class = config.classFor(ttl_s);
        const h = self.idx.hash(account_id, name);

        var rec_tags: [config.max_tags]record.Tag = undefined;

        self.write_mutex.lock();
        var unlocked = false;
        defer if (!unlocked) self.write_mutex.unlock();

        const existing = try self.findLive(h, account_id, name, now);
        if (existing == null and self.idx.admissionClosed()) return error.CapacityExhausted;

        const seq = self.com.nextSeq();

        // Length does not depend on the back-pointer *values*, so space can be
        // claimed before the chain heads are consulted.
        var probe: record.Record = .{
            .seq = seq,
            .account_id = account_id,
            .created_at = now,
            .expires_at = expires_at,
            .class = class,
            .tombstone = false,
            .name = name,
            .content_type = content_type,
            .tags = blk: {
                for (tags, 0..) |t, i| rec_tags[i] = .{ .text = t, .prev = loc_mod.none };
                break :blk rec_tags[0..tags.len];
            },
            .body = body,
        };
        const len = probe.encodedLen();

        const loc = try self.segs.reserve(class, len);

        // Publish to the chains, capturing what each pointed at. Safe to do before
        // the write because the write lock makes reserve-then-write atomic.
        var pushed: usize = 0;
        errdefer {
            // Put the heads back if the write does not happen.
            for (rec_tags[0..pushed]) |t| {
                self.heads.set(account_id, t.text, class, t.prev) catch {};
            }
            self.segs.unreserve(loc, len);
        }
        while (pushed < tags.len) : (pushed += 1) {
            rec_tags[pushed].prev = try self.heads.push(account_id, tags[pushed], class, loc);
        }
        probe.tags = rec_tags[0..tags.len];

        const buf = try self.gpa.alloc(u8, len);
        defer self.gpa.free(buf);
        const bytes = try record.encode(probe, buf);

        try self.segs.writeReserved(loc, bytes, expires_at);
        self.com.noteWritten(class, seq);

        _ = try self.idx.upsert(
            h,
            if (existing) |e| e.slot else null,
            if (existing) |e| e.loc else loc_mod.none,
            loc,
            expires_at,
            now,
        );

        // Durability outside the lock, so other writers can join this flush.
        self.write_mutex.unlock();
        unlocked = true;
        try self.com.awaitDurable(class, seq);

        return .{ .seq = seq, .loc = loc, .expires_at = expires_at, .created = existing == null };
    }

    pub fn delete(self: *Store, account_id: u32, name: []const u8) Error!bool {
        try validateName(name);

        const now = self.clock.now();
        const h = self.idx.hash(account_id, name);

        self.write_mutex.lock();
        var unlocked = false;
        defer if (!unlocked) self.write_mutex.unlock();

        const existing = try self.findLive(h, account_id, name, now) orelse return false;

        const seq = self.com.nextSeq();
        // Class 0 with twice the snapshot interval: a tombstone only has to
        // outlive one snapshot, after which the deletion is in the slot array and
        // the record is never replayed again (D32).
        const expires_at = now + config.tombstone_ttl_s;

        var buf: [record.max_record_bytes]u8 = undefined;
        const bytes = try record.encode(.{
            .seq = seq,
            .account_id = account_id,
            .created_at = now,
            .expires_at = expires_at,
            .class = 0,
            .tombstone = true,
            .name = name,
            .content_type = "",
            .tags = &.{}, // a tombstone joins no chain
            .body = "",
        }, &buf);

        _ = try self.segs.append(0, bytes, expires_at);
        self.com.noteWritten(0, seq);
        _ = self.idx.kill(h, existing.slot, existing.loc, now);

        self.write_mutex.unlock();
        unlocked = true;
        try self.com.awaitDurable(0, seq);
        return true;
    }

    // -----------------------------------------------------------------------
    // Read path
    // -----------------------------------------------------------------------

    /// Reads one entry into `buf`. Returns null when absent, expired or deleted —
    /// which callers cannot tell apart, by design.
    pub fn get(self: *Store, account_id: u32, name: []const u8, buf: []u8) Error!?Got {
        const now = self.clock.now();
        const h = self.idx.hash(account_id, name);

        var cands: [8]index_mod.Candidate = undefined;
        for (self.idx.candidates(h, now, &cands)) |c| {
            const len = self.segs.readRecord(c.loc, buf) catch |e| switch (e) {
                error.CorruptRecord => {
                    _ = self.corruptions.fetchAdd(1, .monotonic);
                    continue;
                },
                error.SegmentNotFound => continue,
                else => return e,
            };
            var tags: [config.max_tags]record.Tag = undefined;
            const rec = record.decode(buf[0..len], &tags) catch {
                _ = self.corruptions.fetchAdd(1, .monotonic);
                continue;
            };
            // The verifying read is the same read that fetches the body, which is
            // what makes storing names in RAM pointless (D11).
            if (rec.account_id != account_id or !std.mem.eql(u8, rec.name, name)) continue;
            if (rec.tombstone or rec.expires_at <= now) return null;

            return .{
                .seq = rec.seq,
                .body = rec.body,
                .content_type = rec.content_type,
                .created_at = rec.created_at,
                .expires_at = rec.expires_at,
                .tag_count = @intCast(rec.tags.len),
            };
        }
        return null;
    }

    pub fn list(
        self: *Store,
        account_id: u32,
        tag: []const u8,
        limit: u32,
        cursor: tagchain.Cursor,
        ctx: anytype,
        comptime emit: anytype,
    ) Error!tagchain.WalkResult {
        try validateTag(tag);
        const capped = @min(if (limit == 0) config.list_default_limit else limit, config.list_max_limit);
        return tagchain.walk(
            &self.heads,
            &self.idx,
            &self.segs,
            self.gpa,
            account_id,
            tag,
            self.clock.now(),
            cursor,
            capped,
            ctx,
            emit,
        );
    }

    // -----------------------------------------------------------------------
    // Maintenance
    // -----------------------------------------------------------------------

    pub const Maintenance = struct {
        swept: u64,
        segments_reclaimed: u32,
        snapshotted: bool,
    };

    /// Time-driven housekeeping. Called from the event loop's tick in production;
    /// called explicitly with an advanced clock in tests.
    pub fn maintain(self: *Store) Error!Maintenance {
        const now = self.clock.now();

        const swept = self.idx.sweepExpired(now);
        const reclaimed = try self.segs.reclaim(now);

        var snapped = false;
        if (now - self.last_snapshot_at >= self.opts.snapshot_interval_s) {
            try self.snapshot();
            snapped = true;
        }
        return .{ .swept = swept, .segments_reclaimed = reclaimed, .snapshotted = snapped };
    }

    pub fn snapshot(self: *Store) Error!void {
        // Flush first: a snapshot claims its watermark is durable.
        try self.com.flush();
        const watermark = self.com.lastSeq();
        const open_state = self.segs.openState();

        var states: [config.class_count]snapshot_mod.OpenState = undefined;
        for (open_state, 0..) |o, i| states[i] = .{ .id = o.id, .offset = o.offset };

        try snapshot_mod.write(self.gpa, self.dir_fd, &self.idx, &self.heads, watermark, states);
        self.last_snapshot_at = self.clock.now();
    }

    pub fn stats(self: *Store) Stats {
        return .{
            .index = self.idx.stats(),
            .segments = self.segs.stats(),
            .commit = self.com.stats(),
            .tags = self.heads.stats(),
            .corruptions = self.corruptions.load(.monotonic),
            .recovery_ms = self.recovery_ms,
            .recovery_records = self.recovery_records,
        };
    }

    // -----------------------------------------------------------------------
    // Internals
    // -----------------------------------------------------------------------

    const Live = struct { slot: u32, loc: Location };

    /// Finds the live record for a name, verifying candidates against disk.
    fn findLive(self: *Store, h: u64, account_id: u32, name: []const u8, now: u32) Error!?Live {
        var cands: [8]index_mod.Candidate = undefined;
        const list_ = self.idx.candidates(h, now, &cands);
        if (list_.len == 0) return null;

        var buf = try self.gpa.alloc(u8, record.max_record_bytes);
        defer self.gpa.free(buf);

        for (list_) |c| {
            const len = self.segs.readRecord(c.loc, buf) catch |e| switch (e) {
                error.CorruptRecord, error.SegmentNotFound => continue,
                else => return e,
            };
            var tags: [config.max_tags]record.Tag = undefined;
            const rec = record.decode(buf[0..len], &tags) catch continue;
            if (rec.account_id == account_id and std.mem.eql(u8, rec.name, name)) {
                if (rec.tombstone) return null;
                return .{ .slot = c.slot, .loc = c.loc };
            }
        }
        return null;
    }

    /// True when the record at `loc` carries this exact account and name.
    fn nameAt(self: *Store, loc: Location, account_id: u32, name: []const u8) Error!bool {
        var buf = try self.gpa.alloc(u8, record.max_record_bytes);
        defer self.gpa.free(buf);
        const len = self.segs.readRecord(loc, buf) catch return false;
        var tags: [config.max_tags]record.Tag = undefined;
        const rec = record.decode(buf[0..len], &tags) catch return false;
        return rec.account_id == account_id and std.mem.eql(u8, rec.name, name);
    }
};

// ---------------------------------------------------------------------------
// Buffered sequential record reader, used only by recovery
// ---------------------------------------------------------------------------

/// Streams records from a class's segments in sequence order.
///
/// Buffered deliberately: one `pread` per record would make recovery a syscall
/// per record, which at millions of records misses the ten-second target by
/// orders of magnitude. Reads land in 1 MiB chunks instead.
const Stream = struct {
    const chunk = 1024 * 1024;

    gpa: std.mem.Allocator,
    segs: *segment.SegmentSet,
    ids: []u32,
    i: usize = 0,
    offset: u32,
    seg_size: u32 = 0,

    buf: []u8,
    /// Valid bytes in `buf`, starting at file offset `buf_at`.
    buf_len: usize = 0,
    buf_pos: usize = 0,
    buf_at: u32 = 0,

    current: ?struct {
        loc: Location,
        rec: record.Record,
        tags: [config.max_tags]record.Tag,
    } = null,

    fn create(gpa: std.mem.Allocator, segs: *segment.SegmentSet, ids: []const u32, first_offset: u32) segment.Error!*Stream {
        const self = try gpa.create(Stream);
        errdefer gpa.destroy(self);
        // Must hold any single record plus room to refill around it.
        const buf = try gpa.alloc(u8, @max(chunk, record.max_record_bytes * 2));
        errdefer gpa.free(buf);
        self.* = .{
            .gpa = gpa,
            .segs = segs,
            .ids = try gpa.dupe(u32, ids),
            .offset = first_offset,
            .buf = buf,
        };
        return self;
    }

    fn destroy(s: *Stream) void {
        s.gpa.free(s.ids);
        s.gpa.free(s.buf);
        s.gpa.destroy(s);
    }

    fn openCurrent(s: *Stream) segment.Error!?segment.Meta {
        while (s.i < s.ids.len) {
            if (s.segs.metaOf(s.ids[s.i])) |m| return m;
            s.i += 1; // reclaimed underneath us
            s.offset = segment.header_bytes;
        }
        return null;
    }

    /// Loads the next record into `current`, or sets it to null at the end.
    fn advance(s: *Stream) segment.Error!void {
        while (true) {
            const m = try s.openCurrent() orelse {
                s.current = null;
                return;
            };
            s.seg_size = @intCast(try os.fileSize(m.fd));

            if (s.offset >= s.seg_size) {
                s.i += 1;
                s.offset = segment.header_bytes;
                s.buf_len = 0;
                s.buf_pos = 0;
                continue;
            }

            // Ensure a header is buffered.
            if (!try s.ensure(m, record.header_bytes)) {
                s.i += 1;
                s.offset = segment.header_bytes;
                s.buf_len = 0;
                s.buf_pos = 0;
                continue;
            }

            const len = record.peekLength(s.buf[s.buf_pos..][0..record.header_bytes]) catch {
                // Torn tail: this segment ends here, and so does the class.
                s.current = null;
                return;
            };
            if (!try s.ensure(m, len)) {
                s.current = null;
                return;
            }

            var tags: [config.max_tags]record.Tag = undefined;
            const rec = record.decode(s.buf[s.buf_pos..][0..len], &tags) catch {
                s.current = null;
                return;
            };

            s.current = .{
                .loc = Location.init(m.class, m.id, s.offset),
                .rec = rec,
                .tags = tags,
            };
            // `record.decode` filled the stack-local `tags`, so `rec.tags` still
            // points at a frame that is about to disappear. Re-aim it at the copy
            // that lives as long as `current` does.
            s.current.?.rec.tags = s.current.?.tags[0..rec.tags.len];
            s.buf_pos += len;
            s.offset += len;
            return;
        }
    }

    /// Guarantees `need` contiguous bytes at `buf_pos`, refilling if necessary.
    /// False when the segment cannot supply them.
    fn ensure(s: *Stream, m: segment.Meta, need: usize) segment.Error!bool {
        if (s.buf_len - s.buf_pos >= need) return true;
        if (s.offset + need > s.seg_size) return false;

        // Move the remainder down and refill behind it.
        const keep = s.buf_len - s.buf_pos;
        if (keep > 0) std.mem.copyForwards(u8, s.buf[0..keep], s.buf[s.buf_pos..s.buf_len]);
        s.buf_pos = 0;
        s.buf_len = keep;
        s.buf_at = s.offset;

        const want = @min(s.buf.len - keep, s.seg_size - (s.offset + @as(u32, @intCast(keep))));
        if (want == 0) return s.buf_len >= need;

        const got = try os.preadAll(m.fd, s.buf[keep .. keep + want], s.offset + keep);
        s.buf_len = keep + got;
        return s.buf_len - s.buf_pos >= need;
    }
};

// ---------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------

/// Names are byte strings of printable ASCII, `/` allowed for namespacing.
/// Rules mirror `docs/03-data-model.md`.
pub fn validateName(name: []const u8) Error!void {
    if (name.len < config.min_name_bytes or name.len > config.max_name_bytes) return error.NameInvalid;
    if (name[0] == '/' or name[name.len - 1] == '/') return error.NameInvalid;

    var prev_slash = false;
    var seg_start: usize = 0;
    for (name, 0..) |ch, i| {
        if (ch < 0x21 or ch > 0x7E) return error.NameInvalid; // control, space, non-ASCII
        if (ch == '/') {
            if (prev_slash) return error.NameInvalid; // no empty segment
            const seg = name[seg_start..i];
            if (std.mem.eql(u8, seg, ".") or std.mem.eql(u8, seg, "..")) return error.NameInvalid;
            prev_slash = true;
            seg_start = i + 1;
        } else prev_slash = false;
    }
    const last = name[seg_start..];
    if (std.mem.eql(u8, last, ".") or std.mem.eql(u8, last, "..")) return error.NameInvalid;
}

/// Tags are lowercase already by the time they reach the engine; normalisation is
/// the API layer's job, so anything uppercase here is a caller bug.
pub fn validateTag(tag: []const u8) Error!void {
    if (tag.len == 0 or tag.len > config.max_tag_bytes) return error.TagInvalid;
    for (tag) |ch| {
        const ok = (ch >= 'a' and ch <= 'z') or (ch >= '0' and ch <= '9') or
            ch == '.' or ch == '_' or ch == '-' or ch == ':';
        if (!ok) return error.TagInvalid;
    }
}


// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const H = struct {
    tmp: [64]u8 = undefined,
    path: [:0]u8 = undefined,
    dir_fd: os.Fd = -1,
    mclock: clock_mod.Manual = undefined,

    const start_time: u32 = 1_700_000_000;

    fn init(seed: u64) !H {
        var h: H = .{};
        h.mclock = .init(start_time);
        h.path = try std.fmt.bufPrintZ(&h.tmp, "/tmp/doot_store_{d}", .{seed});
        removeTree(h.path);
        try os.mkdir(os.cwd, h.path);
        h.dir_fd = try os.openDir(os.cwd, h.path);
        return h;
    }
    fn deinit(h: *H) void {
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
    fn opts(_: *H) config.Options {
        return .{
            .segment_bytes = 256 * 1024,
            .index_hash_key = @splat(0x5A),
            .max_ttl_s = 30 * 24 * 60 * 60,
        };
    }
    /// Reopens the store, which is the recovery path.
    fn reopen(h: *H) !*Store {
        return Store.open(testing.allocator, h.dir_fd, h.mclock.clock(), h.opts());
    }
};

const day: u32 = 24 * 60 * 60;

test "put then get round-trips a body" {
    var h = try H.init(1);
    defer h.deinit();
    const s = try h.reopen();
    defer s.close();

    const r = try s.put(1, "ci/sha", "abc123", "text/plain", &.{ "ci", "main" }, day);
    try testing.expect(r.created);

    var buf: [4096]u8 = undefined;
    const got = (try s.get(1, "ci/sha", &buf)).?;
    try testing.expectEqualStrings("abc123", got.body);
    try testing.expectEqualStrings("text/plain", got.content_type);
    try testing.expectEqual(@as(u8, 2), got.tag_count);
    try testing.expectEqual(H.start_time + day, got.expires_at);
}

test "an absent name reads as null" {
    var h = try H.init(2);
    defer h.deinit();
    const s = try h.reopen();
    defer s.close();

    var buf: [64]u8 = undefined;
    try testing.expect(try s.get(1, "never/written", &buf) == null);
}

test "accounts are isolated end to end" {
    var h = try H.init(3);
    defer h.deinit();
    const s = try h.reopen();
    defer s.close();

    _ = try s.put(1, "shared", "one", "", &.{}, day);
    _ = try s.put(2, "shared", "two", "", &.{}, day);

    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("one", (try s.get(1, "shared", &buf)).?.body);
    try testing.expectEqualStrings("two", (try s.get(2, "shared", &buf)).?.body);
}

test "overwrite replaces body, content type, tags and lifetime together" {
    var h = try H.init(4);
    defer h.deinit();
    const s = try h.reopen();
    defer s.close();

    _ = try s.put(1, "k", "first", "text/plain", &.{"a"}, 30 * day);
    h.mclock.advance(60);
    const r2 = try s.put(1, "k", "second", "application/json", &.{}, 2 * day);
    try testing.expect(!r2.created);

    var buf: [64]u8 = undefined;
    const got = (try s.get(1, "k", &buf)).?;
    try testing.expectEqualStrings("second", got.body);
    try testing.expectEqualStrings("application/json", got.content_type);
    try testing.expectEqual(@as(u8, 0), got.tag_count);
    // Lifetime came from the new write, not inherited from the old one.
    try testing.expectEqual(H.start_time + 60 + 2 * day, got.expires_at);
    try testing.expectEqual(@as(u64, 1), s.stats().index.live);
}

test "an expired entry is indistinguishable from an absent one" {
    var h = try H.init(5);
    defer h.deinit();
    const s = try h.reopen();
    defer s.close();

    _ = try s.put(1, "short", "gone soon", "", &.{}, 120);

    var buf: [64]u8 = undefined;
    try testing.expect(try s.get(1, "short", &buf) != null);
    h.mclock.advance(119);
    try testing.expect(try s.get(1, "short", &buf) != null);
    h.mclock.advance(1); // exactly at expiry
    try testing.expect(try s.get(1, "short", &buf) == null);
}

test "reading does not extend lifetime" {
    var h = try H.init(6);
    defer h.deinit();
    const s = try h.reopen();
    defer s.close();

    _ = try s.put(1, "notouch", "x", "", &.{}, 300);
    var buf: [64]u8 = undefined;

    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        h.mclock.advance(50);
        _ = try s.get(1, "notouch", &buf);
    }
    // 250s of reads must not have moved the deadline.
    try testing.expectEqual(H.start_time + 300, (try s.get(1, "notouch", &buf)).?.expires_at);
    h.mclock.advance(50);
    try testing.expect(try s.get(1, "notouch", &buf) == null);
}

test "delete removes an entry and is not repeatable" {
    var h = try H.init(7);
    defer h.deinit();
    const s = try h.reopen();
    defer s.close();

    _ = try s.put(1, "doomed", "bye", "", &.{"t"}, day);
    try testing.expect(try s.delete(1, "doomed"));

    var buf: [64]u8 = undefined;
    try testing.expect(try s.get(1, "doomed", &buf) == null);
    try testing.expect(!try s.delete(1, "doomed"));
}

test "a name can be rewritten after deletion" {
    var h = try H.init(8);
    defer h.deinit();
    const s = try h.reopen();
    defer s.close();

    _ = try s.put(1, "phoenix", "v1", "", &.{}, day);
    try testing.expect(try s.delete(1, "phoenix"));
    const r = try s.put(1, "phoenix", "v2", "", &.{}, day);
    try testing.expect(r.created); // counts as new: nothing was live

    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("v2", (try s.get(1, "phoenix", &buf)).?.body);
}

test "lifetime chooses the class, and each class gets its own stream" {
    var h = try H.init(9);
    defer h.deinit();
    const s = try h.reopen();
    defer s.close();

    const r0 = try s.put(1, "a", "x", "", &.{}, 600); // <= 1h
    const r1 = try s.put(1, "b", "x", "", &.{}, 6 * 60 * 60); // <= 24h
    const r2 = try s.put(1, "c", "x", "", &.{}, 3 * day); // <= 7d
    const r3 = try s.put(1, "d", "x", "", &.{}, 20 * day); // <= max

    try testing.expectEqual(@as(config.Class, 0), r0.loc.class());
    try testing.expectEqual(@as(config.Class, 1), r1.loc.class());
    try testing.expectEqual(@as(config.Class, 2), r2.loc.class());
    try testing.expectEqual(@as(config.Class, 3), r3.loc.class());
    try testing.expectEqual(@as(u32, 4), s.stats().segments.segments);
}

// -- listing --------------------------------------------------------------

const Collect = struct {
    names: std.ArrayListUnmanaged([]u8) = .empty,
    gpa: std.mem.Allocator,

    fn emit(self: *Collect, _: Location, rec: record.Record) Error!void {
        const copy = try self.gpa.dupe(u8, rec.name);
        try self.names.append(self.gpa, copy);
    }
    fn deinit(self: *Collect) void {
        for (self.names.items) |n| self.gpa.free(n);
        self.names.deinit(self.gpa);
    }
};

test "list returns a tag's entries newest first" {
    var h = try H.init(10);
    defer h.deinit();
    const s = try h.reopen();
    defer s.close();

    var nb: [32]u8 = undefined;
    var i: u32 = 0;
    while (i < 8) : (i += 1) {
        const name = try std.fmt.bufPrint(&nb, "e{d}", .{i});
        _ = try s.put(1, name, "x", "", &.{"grp"}, day);
        h.mclock.advance(1);
    }

    var c: Collect = .{ .gpa = testing.allocator };
    defer c.deinit();
    const r = try s.list(1, "grp", 50, .{}, &c, Collect.emit);

    try testing.expectEqual(@as(u32, 8), r.emitted);
    try testing.expect(r.complete);
    try testing.expectEqualStrings("e7", c.names.items[0]);
    try testing.expectEqualStrings("e0", c.names.items[7]);
}

test "list skips superseded versions rather than showing duplicates" {
    var h = try H.init(11);
    defer h.deinit();
    const s = try h.reopen();
    defer s.close();

    // Same name written repeatedly under one tag: the chain holds every version,
    // but only the current one may be listed.
    var i: u32 = 0;
    while (i < 6) : (i += 1) {
        _ = try s.put(1, "rewritten", "v", "", &.{"tag"}, day);
        h.mclock.advance(1);
    }
    _ = try s.put(1, "other", "v", "", &.{"tag"}, day);

    var c: Collect = .{ .gpa = testing.allocator };
    defer c.deinit();
    const r = try s.list(1, "tag", 50, .{}, &c, Collect.emit);

    try testing.expectEqual(@as(u32, 2), r.emitted);
    // Six of the seven hops were superseded versions, so hops far exceed results.
    try testing.expect(r.hops > r.emitted);
}

test "list omits deleted and expired entries" {
    var h = try H.init(12);
    defer h.deinit();
    const s = try h.reopen();
    defer s.close();

    _ = try s.put(1, "keep", "x", "", &.{"m"}, day);
    _ = try s.put(1, "remove", "x", "", &.{"m"}, day);
    _ = try s.put(1, "lapse", "x", "", &.{"m"}, 120);

    try testing.expect(try s.delete(1, "remove"));
    h.mclock.advance(200); // "lapse" is now expired

    var c: Collect = .{ .gpa = testing.allocator };
    defer c.deinit();
    const r = try s.list(1, "m", 50, .{}, &c, Collect.emit);

    try testing.expectEqual(@as(u32, 1), r.emitted);
    try testing.expectEqualStrings("keep", c.names.items[0]);
}

test "list merges chains across classes in true newest-first order" {
    var h = try H.init(13);
    defer h.deinit();
    const s = try h.reopen();
    defer s.close();

    // Alternate classes under one tag, so correctness depends on the merge and
    // not on any single chain's order.
    const ttls = [_]u32{ 600, 6 * 60 * 60, 3 * day, 20 * day, 600, 3 * day };
    var nb: [32]u8 = undefined;
    for (ttls, 0..) |ttl, i| {
        const name = try std.fmt.bufPrint(&nb, "x{d}", .{i});
        _ = try s.put(1, name, "b", "", &.{"mix"}, ttl);
        h.mclock.advance(1);
    }

    var c: Collect = .{ .gpa = testing.allocator };
    defer c.deinit();
    const r = try s.list(1, "mix", 50, .{}, &c, Collect.emit);

    try testing.expectEqual(@as(u32, 6), r.emitted);
    for (0..6) |i| {
        const expect = try std.fmt.bufPrint(&nb, "x{d}", .{5 - i});
        try testing.expectEqualStrings(expect, c.names.items[i]);
    }
}

test "an entry that changes class is listed once, at its new position" {
    var h = try H.init(14);
    defer h.deinit();
    const s = try h.reopen();
    defer s.close();

    _ = try s.put(1, "mover", "v1", "", &.{"t"}, 600); // class 0
    h.mclock.advance(5);
    _ = try s.put(1, "static", "v", "", &.{"t"}, day);
    h.mclock.advance(5);
    _ = try s.put(1, "mover", "v2", "", &.{"t"}, 20 * day); // class 3 now
    h.mclock.advance(5);

    var c: Collect = .{ .gpa = testing.allocator };
    defer c.deinit();
    const r = try s.list(1, "t", 50, .{}, &c, Collect.emit);

    // The class-0 version is stale and must be skipped, not double-counted.
    try testing.expectEqual(@as(u32, 2), r.emitted);
    try testing.expectEqualStrings("mover", c.names.items[0]);
    try testing.expectEqualStrings("static", c.names.items[1]);

    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("v2", (try s.get(1, "mover", &buf)).?.body);
}

test "list paginates without repeating or dropping entries" {
    var h = try H.init(15);
    defer h.deinit();
    const s = try h.reopen();
    defer s.close();

    const total = 30;
    var nb: [32]u8 = undefined;
    var i: u32 = 0;
    while (i < total) : (i += 1) {
        const name = try std.fmt.bufPrint(&nb, "p{d}", .{i});
        _ = try s.put(1, name, "x", "", &.{"page"}, day);
        h.mclock.advance(1);
    }

    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var it = seen.keyIterator();
        while (it.next()) |k| testing.allocator.free(k.*);
        seen.deinit(testing.allocator);
    }

    var cursor: tagchain.Cursor = .{};
    var pages: u32 = 0;
    while (pages < 20) : (pages += 1) {
        var c: Collect = .{ .gpa = testing.allocator };
        defer c.deinit();
        const r = try s.list(1, "page", 7, cursor, &c, Collect.emit);
        for (c.names.items) |n| {
            const key = try testing.allocator.dupe(u8, n);
            const gop = try seen.getOrPut(testing.allocator, key);
            if (gop.found_existing) {
                testing.allocator.free(key);
                std.debug.print("duplicate across pages: {s}\n", .{n});
                return error.TestUnexpectedResult;
            }
        }
        cursor = r.cursor;
        if (r.complete) break;
    }

    try testing.expectEqual(@as(usize, total), seen.count());
}

// -- recovery -------------------------------------------------------------

test "everything survives a clean reopen" {
    var h = try H.init(16);
    defer h.deinit();

    var nb: [32]u8 = undefined;
    {
        const s = try h.reopen();
        defer s.close();
        var i: u32 = 0;
        while (i < 200) : (i += 1) {
            const name = try std.fmt.bufPrint(&nb, "r/{d}", .{i});
            _ = try s.put(1, name, "body", "text/plain", &.{"all"}, day);
        }
    }
    {
        const s = try h.reopen();
        defer s.close();

        var buf: [4096]u8 = undefined;
        var i: u32 = 0;
        while (i < 200) : (i += 1) {
            const name = try std.fmt.bufPrint(&nb, "r/{d}", .{i});
            const got = try s.get(1, name, &buf) orelse {
                std.debug.print("lost {s} across reopen\n", .{name});
                return error.TestUnexpectedResult;
            };
            try testing.expectEqualStrings("body", got.body);
        }
        try testing.expectEqual(@as(u64, 200), s.stats().index.live);
    }
}

test "recovery works without a snapshot, from segments alone" {
    var h = try H.init(17);
    defer h.deinit();

    var nb: [32]u8 = undefined;
    {
        const s = try h.reopen();
        // Deliberately no close(), so no final snapshot is written. Everything
        // must be reconstructed from the segments.
        var i: u32 = 0;
        while (i < 150) : (i += 1) {
            const name = try std.fmt.bufPrint(&nb, "ns/{d}", .{i});
            _ = try s.put(1, name, "v", "", &.{"tag"}, day);
        }
        s.segs.deinit();
        s.heads.deinit();
        s.idx.deinit();
        testing.allocator.destroy(s);
    }
    {
        const s = try h.reopen();
        defer s.close();
        try testing.expectEqual(@as(u64, 150), s.stats().index.live);
        try testing.expect(s.stats().recovery_records >= 150);

        var buf: [256]u8 = undefined;
        try testing.expect(try s.get(1, "ns/0", &buf) != null);
        try testing.expect(try s.get(1, "ns/149", &buf) != null);

        // Tag chains rebuilt from replay, so listing still works.
        var c: Collect = .{ .gpa = testing.allocator };
        defer c.deinit();
        const r = try s.list(1, "tag", 100, .{}, &c, Collect.emit);
        try testing.expectEqual(@as(u32, 100), r.emitted);
    }
}

test "tag chains survive a snapshot, which they could not be rebuilt from" {
    var h = try H.init(18);
    defer h.deinit();

    var nb: [32]u8 = undefined;
    {
        const s = try h.reopen();
        defer s.close();
        var i: u32 = 0;
        while (i < 40) : (i += 1) {
            const name = try std.fmt.bufPrint(&nb, "t/{d}", .{i});
            _ = try s.put(1, name, "v", "", &.{ "alpha", "beta" }, day);
        }
        // Snapshot, so replay has nothing left to reconstruct heads from.
        try s.snapshot();
    }
    {
        const s = try h.reopen();
        defer s.close();
        try testing.expectEqual(@as(u64, 0), s.stats().recovery_records);

        for ([_][]const u8{ "alpha", "beta" }) |tag| {
            var c: Collect = .{ .gpa = testing.allocator };
            defer c.deinit();
            const r = try s.list(1, tag, 100, .{}, &c, Collect.emit);
            try testing.expectEqual(@as(u32, 40), r.emitted);
        }
    }
}

test "a deletion survives restart and does not resurrect" {
    var h = try H.init(19);
    defer h.deinit();

    {
        const s = try h.reopen();
        defer s.close();
        _ = try s.put(1, "gone", "data", "", &.{"t"}, 20 * day);
        _ = try s.put(1, "stays", "data", "", &.{"t"}, 20 * day);
        try testing.expect(try s.delete(1, "gone"));
    }
    {
        const s = try h.reopen();
        defer s.close();
        var buf: [64]u8 = undefined;
        try testing.expect(try s.get(1, "gone", &buf) == null);
        try testing.expect(try s.get(1, "stays", &buf) != null);

        var c: Collect = .{ .gpa = testing.allocator };
        defer c.deinit();
        const r = try s.list(1, "t", 50, .{}, &c, Collect.emit);
        try testing.expectEqual(@as(u32, 1), r.emitted);
        try testing.expectEqualStrings("stays", c.names.items[0]);
    }
}

test "a deletion recovered from segments alone also does not resurrect" {
    var h = try H.init(20);
    defer h.deinit();

    {
        const s = try h.reopen();
        _ = try s.put(1, "zap", "data", "", &.{}, 20 * day);
        _ = try s.delete(1, "zap");
        // No snapshot: the tombstone must be replayed from the segment.
        s.segs.deinit();
        s.heads.deinit();
        s.idx.deinit();
        testing.allocator.destroy(s);
    }
    {
        const s = try h.reopen();
        defer s.close();
        var buf: [64]u8 = undefined;
        try testing.expect(try s.get(1, "zap", &buf) == null);
        try testing.expectEqual(@as(u64, 0), s.stats().index.live);
    }
}

test "expiry survives restart" {
    var h = try H.init(21);
    defer h.deinit();

    {
        const s = try h.reopen();
        defer s.close();
        _ = try s.put(1, "brief", "x", "", &.{}, 300);
        _ = try s.put(1, "long", "x", "", &.{}, 20 * day);
    }
    h.mclock.advance(600); // "brief" lapses while the store is down
    {
        const s = try h.reopen();
        defer s.close();
        var buf: [64]u8 = undefined;
        try testing.expect(try s.get(1, "brief", &buf) == null);
        try testing.expect(try s.get(1, "long", &buf) != null);
        try testing.expectEqual(@as(u64, 1), s.stats().index.live);
    }
}

test "recovery survives segment rotation since the snapshot" {
    var h = try H.init(22);
    defer h.deinit();

    const body = "b" ** 2048;
    var nb: [32]u8 = undefined;
    {
        const s = try h.reopen();
        try s.snapshot(); // snapshot first, then force several rotations
        var i: u32 = 0;
        while (i < 300) : (i += 1) {
            const name = try std.fmt.bufPrint(&nb, "rot/{d}", .{i});
            _ = try s.put(1, name, body, "", &.{"r"}, day);
        }
        try testing.expect(s.stats().segments.segments > 1);
        s.segs.deinit();
        s.heads.deinit();
        s.idx.deinit();
        testing.allocator.destroy(s);
    }
    {
        const s = try h.reopen();
        defer s.close();
        try testing.expectEqual(@as(u64, 300), s.stats().index.live);

        var buf: [8192]u8 = undefined;
        var i: u32 = 0;
        while (i < 300) : (i += 1) {
            const name = try std.fmt.bufPrint(&nb, "rot/{d}", .{i});
            const got = try s.get(1, name, &buf) orelse {
                std.debug.print("lost {s} after rotation\n", .{name});
                return error.TestUnexpectedResult;
            };
            try testing.expectEqualStrings(body, got.body);
        }
    }
}

test "recovery is idempotent, so a crash during it is survivable" {
    var h = try H.init(23);
    defer h.deinit();

    var nb: [32]u8 = undefined;
    {
        const s = try h.reopen();
        var i: u32 = 0;
        while (i < 100) : (i += 1) {
            const name = try std.fmt.bufPrint(&nb, "idem/{d}", .{i});
            _ = try s.put(1, name, "v", "", &.{"t"}, day);
        }
        s.segs.deinit();
        s.heads.deinit();
        s.idx.deinit();
        testing.allocator.destroy(s);
    }

    // Recover repeatedly without ever snapshotting. Each pass replays the same
    // tail and must land on the same state.
    var pass: u32 = 0;
    while (pass < 3) : (pass += 1) {
        const s = try h.reopen();
        try testing.expectEqual(@as(u64, 100), s.stats().index.live);

        var c: Collect = .{ .gpa = testing.allocator };
        defer c.deinit();
        const r = try s.list(1, "t", 100, .{}, &c, Collect.emit);
        try testing.expectEqual(@as(u32, 100), r.emitted);

        s.segs.deinit();
        s.heads.deinit();
        s.idx.deinit();
        testing.allocator.destroy(s);
    }
}

// -- maintenance ----------------------------------------------------------

test "maintain reclaims segments whose contents have all expired" {
    var h = try H.init(24);
    defer h.deinit();
    const s = try h.reopen();
    defer s.close();

    // Fill and rotate class 0 with short lifetimes.
    const body = "x" ** 2048;
    var nb: [32]u8 = undefined;
    var i: u32 = 0;
    while (i < 200) : (i += 1) {
        const name = try std.fmt.bufPrint(&nb, "sh/{d}", .{i});
        _ = try s.put(1, name, body, "", &.{}, 600);
    }
    try testing.expect(s.stats().segments.sealed >= 1);

    h.mclock.advance(3600); // everything in class 0 has lapsed
    const m = try s.maintain();

    try testing.expect(m.segments_reclaimed >= 1);
    try testing.expect(m.swept > 0);
    try testing.expect(s.stats().segments.reclaimed >= 1);
}

test "reclamation never strands a reader on a missing segment" {
    var h = try H.init(25);
    defer h.deinit();
    const s = try h.reopen();
    defer s.close();

    const body = "y" ** 2048;
    var nb: [32]u8 = undefined;
    var i: u32 = 0;
    while (i < 200) : (i += 1) {
        const name = try std.fmt.bufPrint(&nb, "gone/{d}", .{i});
        _ = try s.put(1, name, body, "", &.{"t"}, 600);
    }
    _ = try s.put(1, "survivor", "keep", "", &.{"t"}, 20 * day);

    h.mclock.advance(3600);
    _ = try s.maintain();

    // Every expired name reads as absent, never as an error.
    var buf: [8192]u8 = undefined;
    i = 0;
    while (i < 200) : (i += 1) {
        const name = try std.fmt.bufPrint(&nb, "gone/{d}", .{i});
        try testing.expect(try s.get(1, name, &buf) == null);
    }
    try testing.expect(try s.get(1, "survivor", &buf) != null);

    // And listing still finds the survivor despite chains into dead segments.
    var c: Collect = .{ .gpa = testing.allocator };
    defer c.deinit();
    const r = try s.list(1, "t", 50, .{}, &c, Collect.emit);
    try testing.expectEqual(@as(u32, 1), r.emitted);
    try testing.expectEqualStrings("survivor", c.names.items[0]);
}

// -- validation -----------------------------------------------------------

test "names are validated per the data model" {
    try validateName("ok");
    try validateName("tenant/42/state");
    try validateName("a" ** 256);
    try validateName("weird!@#$%^&*()_+-=[]{}|;:'\",.<>?`~");

    try testing.expectError(error.NameInvalid, validateName(""));
    try testing.expectError(error.NameInvalid, validateName("a" ** 257));
    try testing.expectError(error.NameInvalid, validateName("/leading"));
    try testing.expectError(error.NameInvalid, validateName("trailing/"));
    try testing.expectError(error.NameInvalid, validateName("double//slash"));
    try testing.expectError(error.NameInvalid, validateName("has space"));
    try testing.expectError(error.NameInvalid, validateName("tab\there"));
    try testing.expectError(error.NameInvalid, validateName("caf\xc3\xa9")); // non-ASCII
    try testing.expectError(error.NameInvalid, validateName("."));
    try testing.expectError(error.NameInvalid, validateName(".."));
    try testing.expectError(error.NameInvalid, validateName("a/../b"));
    try testing.expectError(error.NameInvalid, validateName("a/./b"));
    try testing.expectError(error.NameInvalid, validateName("a/.."));
}

test "tags are validated per the data model" {
    try validateTag("ci");
    try validateTag("run:8f21");
    try validateTag("a.b_c-d:e");
    try validateTag("t" ** 64);

    try testing.expectError(error.TagInvalid, validateTag(""));
    try testing.expectError(error.TagInvalid, validateTag("t" ** 65));
    try testing.expectError(error.TagInvalid, validateTag("UPPER"));
    try testing.expectError(error.TagInvalid, validateTag("has space"));
    try testing.expectError(error.TagInvalid, validateTag("sla/sh"));
}

test "the store rejects out-of-range writes" {
    var h = try H.init(26);
    defer h.deinit();
    const s = try h.reopen();
    defer s.close();

    try testing.expectError(error.TtlTooShort, s.put(1, "k", "v", "", &.{}, 59));
    try testing.expectError(error.TtlTooLong, s.put(1, "k", "v", "", &.{}, 31 * day));
    try testing.expectError(error.TooManyTags, s.put(1, "k", "v", "", &.{ "a", "b", "c", "d", "e", "f" }, day));
    try testing.expectError(error.NameInvalid, s.put(1, "", "v", "", &.{}, day));
    try testing.expectError(error.TagInvalid, s.put(1, "k", "v", "", &.{"BAD"}, day));

    const big = try testing.allocator.alloc(u8, config.max_body_bytes + 1);
    defer testing.allocator.free(big);
    @memset(big, 'z');
    try testing.expectError(error.BodyTooLarge, s.put(1, "k", big, "", &.{}, day));
}

test "a maximum-size body round-trips" {
    var h = try H.init(27);
    defer h.deinit();
    const s = try h.reopen();
    defer s.close();

    const big = try testing.allocator.alloc(u8, config.max_body_bytes);
    defer testing.allocator.free(big);
    for (big, 0..) |*b, i| b.* = @intCast(i % 251);

    _ = try s.put(1, "big", big, "application/octet-stream", &.{"b"}, day);

    const buf = try testing.allocator.alloc(u8, record.max_record_bytes);
    defer testing.allocator.free(buf);
    const got = (try s.get(1, "big", buf)).?;
    try testing.expectEqual(@as(usize, config.max_body_bytes), got.body.len);
    try testing.expectEqualSlices(u8, big, got.body);
}

test "an empty body is valid, which a lock or flag needs" {
    var h = try H.init(28);
    defer h.deinit();
    const s = try h.reopen();
    defer s.close();

    _ = try s.put(1, "flag", "", "", &.{}, day);
    var buf: [256]u8 = undefined;
    const got = (try s.get(1, "flag", &buf)).?;
    try testing.expectEqual(@as(usize, 0), got.body.len);
}
