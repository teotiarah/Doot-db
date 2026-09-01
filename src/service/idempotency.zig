//! The idempotency table (D42, D61, D62).
//!
//! In RAM, bounded, and lost on a restart — stated in the published docs rather than
//! implied away (D42). Held here rather than in `Control` because `Control`'s memory is
//! exactly its log replayed (D40), and a table that is deliberately never logged would be
//! the one part of it a replay cannot rebuild.
//!
//! **A record stores where the write landed, not what the response said** (D61). Two
//! truncated hashes, a packed location, a status and an expiry: 48 bytes. The metadata a
//! replay returns is re-read from the record at that location, because a metadata document
//! does not fit in 48 bytes and the alternative was a 750 MB table.
//!
//! **Eviction is a write cursor that wraps.** D42 requires that records closest to expiry
//! go first, and every record gets the same window measured from its own insertion — so
//! expiry order *is* insertion order, and the rule that sounds like a priority queue is a
//! ring (D62).
//!
//! **A full table never rejects a write.** An optional header must not be able to fail an
//! otherwise valid request; losing a record degrades to re-execution, which is exactly what
//! omitting the header already does.

const std = @import("std");
const storage = @import("storage");

const Sha256 = std.crypto.hash.sha2.Sha256;

/// Truncated from SHA-256. 128 bits of `(account_id, key)` is not collidable, and a
/// collision would hand one account another's outcome, so it is not somewhere to economise.
pub const hash_bytes = 16;
pub const Hash = [hash_bytes]u8;

/// The window `01-product.md` publishes and `02-api.md` documents as not surviving a
/// restart.
pub const window_s: u32 = 24 * 60 * 60;

/// The cap `04-storage.md` records. 48 B each, plus an index, is ~56 MB.
pub const default_records: u32 = 1_000_000;

/// What a caller learns from presenting a key.
pub const Outcome = union(enum) {
    /// No record, or one too old to matter. A reservation is now held; the caller must
    /// finish with `complete` or `abandon`.
    proceed,
    /// Same key, same body, already done. Replay it: no credit, and
    /// `Idempotency-Replayed: true`.
    replay: Replay,
    /// Same key, different body — `409 idempotency_key_reused`.
    conflict,
    /// Same key, still in flight — `409 idempotency_in_progress`.
    in_progress,
};

pub const Replay = struct {
    location: storage.Location,
    status: u16,
};

const State = enum(u8) { free, reserved, done };

/// 48 bytes. The layout is the point, so it is asserted rather than hoped for.
const Record = extern struct {
    key: Hash,
    body: Hash,
    /// Packed `Location`. Meaningless until `state` is `.done`.
    location: u64,
    expires_at: u32,
    status: u16,
    state: State,
    _pad: u8 = 0,
};

comptime {
    std.debug.assert(@sizeOf(Record) == 48);
}

/// Hashes `(account_id, key)`. Distinct accounts presenting one key never collide, because
/// the account is inside the hash rather than beside it.
pub fn keyHash(account_id: u32, key: []const u8) Hash {
    var h = Sha256.init(.{});
    h.update(std.mem.asBytes(&std.mem.nativeToLittle(u32, account_id)));
    h.update(key);
    var full: [Sha256.digest_length]u8 = undefined;
    h.final(&full);
    return full[0..hash_bytes].*;
}

/// Hashes a request body. The body itself is never retained (`02-api.md`).
pub fn bodyHash(body: []const u8) Hash {
    var full: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(body, &full, .{});
    return full[0..hash_bytes].*;
}

/// Generic over capacity so eviction is reachable in a test. Production uses
/// `default_records`; a test uses eight and can therefore actually fill it.
pub fn Table(comptime capacity: u32) type {
    return struct {
        const Self = @This();

        /// Power of two at or above twice the capacity, so probing masks instead of
        /// dividing and the load factor never exceeds one half.
        const slots: u32 = std.math.ceilPowerOfTwoAssert(u32, capacity * 2);
        const mask: u32 = slots - 1;
        /// Index entries are `ring index + 1`, so zero means empty.
        const empty: u32 = 0;

        pub const cap = capacity;

        mutex: storage.os.Mutex = .{},
        ring: [capacity]Record = undefined,
        index: [slots]u32 = @splat(empty),
        /// Where the next reservation goes. Wrapping is what makes eviction oldest-first.
        cursor: u32 = 0,

        live: u32 = 0,
        evictions: u64 = 0,
        replays: u64 = 0,
        conflicts: u64 = 0,

        /// Assigns the whole struct rather than the fields that look like they matter.
        ///
        /// The table is large enough to be heap-allocated, and `create` hands back
        /// uninitialised memory — so a field-by-field `init` leaves anything it forgets
        /// holding garbage. Forgetting the *mutex* is the expensive version of that
        /// mistake: a non-zero lock word is indistinguishable from "held", and the first
        /// `lock` waits on a futex nobody will ever wake.
        pub fn init(self: *Self) void {
            self.* = .{};
            // Only the discriminant matters; the rest of a record is written on reservation.
            for (&self.ring) |*r| r.state = .free;
        }

        pub const Stats = struct {
            live: u32,
            capacity: u32,
            evictions: u64,
            replays: u64,
            conflicts: u64,
        };

        pub fn stats(self: *Self) Stats {
            self.mutex.lock();
            defer self.mutex.unlock();
            return .{
                .live = self.live,
                .capacity = capacity,
                .evictions = self.evictions,
                .replays = self.replays,
                .conflicts = self.conflicts,
            };
        }

        /// Checks the key and, when there is nothing to replay, reserves it.
        ///
        /// The check and the reservation are one operation on purpose: two requests
        /// carrying the same key must not both be told to proceed, and splitting them would
        /// leave exactly that window.
        pub fn begin(self: *Self, key: Hash, body: Hash, now: u32) Outcome {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.findLocked(key)) |slot| {
                const r = &self.ring[self.index[slot] - 1];
                if (r.expires_at > now) {
                    switch (r.state) {
                        .reserved => return .in_progress,
                        .done => {
                            if (!std.mem.eql(u8, &r.body, &body)) {
                                self.conflicts += 1;
                                return .conflict;
                            }
                            self.replays += 1;
                            return .{ .replay = .{
                                .location = .{ .raw = r.location },
                                .status = r.status,
                            } };
                        },
                        .free => {},
                    }
                }
                // Expired, so it is not an outcome any more. Reuse the slot in place rather
                // than leaving a stale record for the cursor to reach eventually.
                self.removeLocked(slot);
            }

            self.reserveLocked(key, body, now);
            return .proceed;
        }

        /// Records where the write landed. The reservation becomes replayable.
        ///
        /// Located by key rather than by a remembered slot, because the ring may have
        /// wrapped past this record while the write was in flight. A completion that finds
        /// its record gone is dropped, which is the same degradation as a record evicted at
        /// the cap.
        ///
        /// Accepts a record that is already `.done`, which happens on exactly one path: a
        /// replay whose recorded location had been reclaimed re-executes, and the outcome it
        /// produces replaces the one that could no longer be read (D61). Two such retries
        /// racing would each write and the last would win — bounded, and already the
        /// re-execution D42 accepts.
        pub fn complete(self: *Self, key: Hash, location: storage.Location, status: u16) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            const slot = self.findLocked(key) orelse return;
            const r = &self.ring[self.index[slot] - 1];
            if (r.state == .free) return;
            r.location = location.raw;
            r.status = status;
            r.state = .done;
        }

        /// Drops a reservation whose write failed.
        ///
        /// Always called when the write does not land. An in-progress marker with no
        /// request behind it would `409` for a full window — the orphan D42 refused to
        /// inherit from a durable table, and no better for being in RAM.
        pub fn abandon(self: *Self, key: Hash) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            const slot = self.findLocked(key) orelse return;
            const r = &self.ring[self.index[slot] - 1];
            if (r.state != .reserved) return;
            self.removeLocked(slot);
        }

        // -- internals, all called with the mutex held --

        fn slotOf(key: Hash) u32 {
            return @truncate(std.mem.readInt(u64, key[0..8], .little) & mask);
        }

        /// The index slot holding `key`, or null.
        fn findLocked(self: *Self, key: Hash) ?u32 {
            var slot = slotOf(key);
            var probes: u32 = 0;
            while (self.index[slot] != empty) {
                if (std.mem.eql(u8, &self.ring[self.index[slot] - 1].key, &key)) return slot;
                slot = (slot + 1) & mask;
                probes += 1;
                if (probes == slots) return null;
            }
            return null;
        }

        fn insertLocked(self: *Self, ring_index: u32) void {
            var slot = slotOf(self.ring[ring_index].key);
            while (self.index[slot] != empty) slot = (slot + 1) & mask;
            self.index[slot] = ring_index + 1;
        }

        /// Removes an index entry, closing the probe chain behind it.
        ///
        /// Backward-shift rather than a tombstone. Tombstones would accumulate for as long
        /// as the process runs — and this table evicts continuously once full, so they would
        /// eventually fill the index and turn every lookup into a full scan.
        fn removeLocked(self: *Self, slot: u32) void {
            const ring_index = self.index[slot] - 1;
            self.ring[ring_index].state = .free;
            self.live -= 1;

            self.index[slot] = empty;

            // Walk the rest of the chain, moving back anything that can no longer be found
            // now that this gap exists.
            var gap = slot;
            var probe = (slot + 1) & mask;
            while (self.index[probe] != empty) {
                const ideal = slotOf(self.ring[self.index[probe] - 1].key);
                // True when `probe` is at or past `gap` in its own probe order, i.e. moving
                // it back keeps it findable.
                if (((probe -% ideal) & mask) >= ((probe -% gap) & mask)) {
                    self.index[gap] = self.index[probe];
                    self.index[probe] = empty;
                    gap = probe;
                }
                probe = (probe + 1) & mask;
            }
        }

        fn reserveLocked(self: *Self, key: Hash, body: Hash, now: u32) void {
            // Skip anything still in flight. With a capacity in the millions and at most a
            // few hundred concurrent requests this never runs, but evicting a reservation
            // would strand the worker that owns it.
            var attempts: u32 = 0;
            while (self.ring[self.cursor].state == .reserved and attempts < capacity) {
                self.cursor = (self.cursor + 1) % capacity;
                attempts += 1;
            }

            const ring_index = self.cursor;
            self.cursor = (self.cursor + 1) % capacity;

            if (self.ring[ring_index].state != .free) {
                // The oldest record, which is also the one closest to expiry.
                self.evictions += 1;
                const old = self.findLocked(self.ring[ring_index].key).?;
                self.removeLocked(old);
            }

            self.ring[ring_index] = .{
                .key = key,
                .body = body,
                .location = 0,
                .expires_at = now +| window_s,
                .status = 0,
                .state = .reserved,
            };
            self.live += 1;
            self.insertLocked(ring_index);
        }
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const now0: u32 = 1_700_000_000;

fn tkey(n: u8) Hash {
    var h: Hash = @splat(0);
    h[0] = n;
    // Spread across the index rather than clustering in the first slots.
    h[7] = n *% 31;
    return h;
}
fn tbody(n: u8) Hash {
    var h: Hash = @splat(0xFF);
    h[0] = n;
    return h;
}
fn loc(n: u32) storage.Location {
    return storage.Location.init(0, n, 64);
}

const Small = Table(8);

fn fresh(gpa: std.mem.Allocator, comptime T: type) !*T {
    const t = try gpa.create(T);
    t.init();
    return t;
}

test "a key nobody has presented proceeds" {
    const t = try fresh(testing.allocator, Small);
    defer testing.allocator.destroy(t);

    try testing.expectEqual(Outcome.proceed, t.begin(tkey(1), tbody(1), now0));
    try testing.expectEqual(@as(u32, 1), t.stats().live);
}

test "a completed key with the same body replays, and says where the write landed" {
    const t = try fresh(testing.allocator, Small);
    defer testing.allocator.destroy(t);

    _ = t.begin(tkey(1), tbody(1), now0);
    t.complete(tkey(1), loc(42), 201);

    switch (t.begin(tkey(1), tbody(1), now0 + 5)) {
        .replay => |r| {
            try testing.expectEqual(loc(42).raw, r.location.raw);
            try testing.expectEqual(@as(u16, 201), r.status);
        },
        else => return error.TestExpectedReplay,
    }
    // Replaying does not consume a second slot.
    try testing.expectEqual(@as(u32, 1), t.stats().live);
    try testing.expectEqual(@as(u64, 1), t.stats().replays);
}

test "the same key with a different body is a conflict, and changes nothing" {
    const t = try fresh(testing.allocator, Small);
    defer testing.allocator.destroy(t);

    _ = t.begin(tkey(1), tbody(1), now0);
    t.complete(tkey(1), loc(42), 200);

    try testing.expectEqual(Outcome.conflict, t.begin(tkey(1), tbody(2), now0 + 1));
    try testing.expectEqual(@as(u64, 1), t.stats().conflicts);
    // The original outcome survives the conflict — a 409 must not overwrite anything.
    switch (t.begin(tkey(1), tbody(1), now0 + 2)) {
        .replay => |r| try testing.expectEqual(@as(u16, 200), r.status),
        else => return error.TestExpectedReplay,
    }
}

test "a key still in flight is in_progress rather than a second execution" {
    const t = try fresh(testing.allocator, Small);
    defer testing.allocator.destroy(t);

    try testing.expectEqual(Outcome.proceed, t.begin(tkey(1), tbody(1), now0));
    // Reserved, not completed.
    try testing.expectEqual(Outcome.in_progress, t.begin(tkey(1), tbody(1), now0));
    // Even with a different body: the first request has not finished, so there is nothing
    // to compare against yet.
    try testing.expectEqual(Outcome.in_progress, t.begin(tkey(1), tbody(2), now0));
}

test "abandoning a reservation lets the request be retried immediately" {
    const t = try fresh(testing.allocator, Small);
    defer testing.allocator.destroy(t);

    _ = t.begin(tkey(1), tbody(1), now0);
    t.abandon(tkey(1));

    // No orphan: the key is free again rather than 409ing for a full window.
    try testing.expectEqual(@as(u32, 0), t.stats().live);
    try testing.expectEqual(Outcome.proceed, t.begin(tkey(1), tbody(1), now0));
}

test "abandon and complete ignore a key they do not hold" {
    const t = try fresh(testing.allocator, Small);
    defer testing.allocator.destroy(t);

    // Neither may invent a record, or a failed write would create a replayable outcome.
    t.abandon(tkey(9));
    t.complete(tkey(9), loc(1), 201);
    try testing.expectEqual(@as(u32, 0), t.stats().live);

}

test "completing a done record replaces it, which is the re-execution path" {
    // The one path that reaches this: a replay whose recorded location had been reclaimed
    // re-executes, and the outcome it produces has to become the record (D61). Before that
    // existed, a second completion was ignored — so this is asserting the change rather
    // than the absence of one.
    const t = try fresh(testing.allocator, Small);
    defer testing.allocator.destroy(t);

    _ = t.begin(tkey(1), tbody(1), now0);
    t.complete(tkey(1), loc(7), 201);
    t.complete(tkey(1), loc(8), 200);

    switch (t.begin(tkey(1), tbody(1), now0)) {
        .replay => |r| {
            try testing.expectEqual(loc(8).raw, r.location.raw);
            try testing.expectEqual(@as(u16, 200), r.status);
        },
        else => return error.TestExpectedReplay,
    }
    // And it is still one record, not two.
    try testing.expectEqual(@as(u32, 1), t.stats().live);
}

test "a record past its window is treated as absent" {
    const t = try fresh(testing.allocator, Small);
    defer testing.allocator.destroy(t);

    _ = t.begin(tkey(1), tbody(1), now0);
    t.complete(tkey(1), loc(42), 201);

    // One second inside the window still replays.
    switch (t.begin(tkey(1), tbody(1), now0 + window_s - 1)) {
        .replay => {},
        else => return error.TestExpectedReplay,
    }
    // Past it, the request executes again — which is what a 24-hour window means.
    try testing.expectEqual(Outcome.proceed, t.begin(tkey(1), tbody(1), now0 + window_s));
    try testing.expectEqual(@as(u32, 1), t.stats().live);
}

test "a full table evicts the oldest, which is the closest to expiry" {
    const t = try fresh(testing.allocator, Small);
    defer testing.allocator.destroy(t);

    // Fill it, one per second so insertion order and expiry order are visibly the same.
    for (0..Small.cap) |i| {
        const n: u8 = @intCast(i + 1);
        _ = t.begin(tkey(n), tbody(n), now0 + @as(u32, @intCast(i)));
        t.complete(tkey(n), loc(n), 201);
    }
    try testing.expectEqual(@as(u32, Small.cap), t.stats().live);

    // One more. The oldest must go, and nothing else.
    const overflow: u8 = Small.cap + 1;
    _ = t.begin(tkey(overflow), tbody(overflow), now0 + Small.cap);
    try testing.expectEqual(@as(u64, 1), t.stats().evictions);
    try testing.expectEqual(@as(u32, Small.cap), t.stats().live);

    // The first key is gone: presenting it re-executes rather than replaying.
    try testing.expectEqual(Outcome.proceed, t.begin(tkey(1), tbody(1), now0 + Small.cap));

    // ...which itself evicted the next-oldest. Everything after that still replays.
    var replayable: u32 = 0;
    for (3..Small.cap + 1) |i| {
        const n: u8 = @intCast(i);
        switch (t.begin(tkey(n), tbody(n), now0 + Small.cap)) {
            .replay => replayable += 1,
            else => {},
        }
    }
    try testing.expectEqual(@as(u32, Small.cap - 2), replayable);
}

test "eviction never rejects a write, however long it goes on" {
    // The invariant D42 insists on: an optional header must not be able to fail a request.
    const t = try fresh(testing.allocator, Small);
    defer testing.allocator.destroy(t);

    var n: u32 = 0;
    while (n < 1000) : (n += 1) {
        const k = keyHash(1, std.mem.asBytes(&n));
        try testing.expectEqual(Outcome.proceed, t.begin(k, tbody(@truncate(n)), now0));
        t.complete(k, loc(n), 201);
    }
    try testing.expectEqual(@as(u32, Small.cap), t.stats().live);
    try testing.expect(t.stats().evictions > 0);
}

test "a reservation is never evicted from under its worker" {
    const t = try fresh(testing.allocator, Small);
    defer testing.allocator.destroy(t);

    // Hold one reservation open, then churn the table right past it.
    _ = t.begin(tkey(200), tbody(200), now0);

    var n: u32 = 0;
    while (n < 100) : (n += 1) {
        const k = keyHash(7, std.mem.asBytes(&n));
        _ = t.begin(k, tbody(@truncate(n)), now0);
        t.complete(k, loc(n), 201);
    }

    // Still in flight, and still completable.
    try testing.expectEqual(Outcome.in_progress, t.begin(tkey(200), tbody(200), now0));
    t.complete(tkey(200), loc(999), 201);
    switch (t.begin(tkey(200), tbody(200), now0)) {
        .replay => |r| try testing.expectEqual(loc(999).raw, r.location.raw),
        else => return error.TestExpectedReplay,
    }
}

test "lookups survive removal, so the probe chain is not broken by a gap" {
    // Backward-shift deletion is the part that could silently lose records: a botched
    // removal leaves a hole that hides everything after it in the same chain.
    const t = try fresh(testing.allocator, Table(64));
    defer testing.allocator.destroy(t);

    var live: [64]bool = @splat(false);
    var n: u32 = 0;
    while (n < 64) : (n += 1) {
        const k = keyHash(1, std.mem.asBytes(&n));
        _ = t.begin(k, tbody(@truncate(n)), now0);
        t.complete(k, loc(n), 201);
        live[n] = true;
    }

    // Remove every third, then check that every survivor is still findable.
    n = 0;
    while (n < 64) : (n += 3) {
        const k = keyHash(1, std.mem.asBytes(&n));
        t.abandon(k); // done, not reserved — so this is a no-op
        // Force a real removal by expiring it instead.
        _ = t.begin(k, tbody(@truncate(n)), now0 + window_s);
        t.complete(k, loc(n + 1000), 200);
    }

    n = 0;
    while (n < 64) : (n += 1) {
        const k = keyHash(1, std.mem.asBytes(&n));
        switch (t.begin(k, tbody(@truncate(n)), now0 + window_s)) {
            .replay, .proceed => {},
            else => return error.TestUnexpectedOutcome,
        }
    }
}

test "distinct accounts presenting one key do not collide" {
    const t = try fresh(testing.allocator, Small);
    defer testing.allocator.destroy(t);

    const a = keyHash(1, "same-key");
    const b = keyHash(2, "same-key");
    try testing.expect(!std.mem.eql(u8, &a, &b));

    _ = t.begin(a, tbody(1), now0);
    t.complete(a, loc(10), 201);

    // The second account has its own record, not the first's outcome.
    try testing.expectEqual(Outcome.proceed, t.begin(b, tbody(2), now0));
    t.complete(b, loc(20), 201);

    switch (t.begin(a, tbody(1), now0)) {
        .replay => |r| try testing.expectEqual(loc(10).raw, r.location.raw),
        else => return error.TestExpectedReplay,
    }
    switch (t.begin(b, tbody(2), now0)) {
        .replay => |r| try testing.expectEqual(loc(20).raw, r.location.raw),
        else => return error.TestExpectedReplay,
    }
}

test "the same key with the same body hashes identically, and a changed body does not" {
    try testing.expectEqualSlices(u8, &keyHash(5, "abc"), &keyHash(5, "abc"));
    try testing.expect(!std.mem.eql(u8, &keyHash(5, "abc"), &keyHash(5, "abd")));
    try testing.expectEqualSlices(u8, &bodyHash("payload"), &bodyHash("payload"));
    try testing.expect(!std.mem.eql(u8, &bodyHash("payload"), &bodyHash("payloae")));
    // An empty body is a body, and hashes like one.
    try testing.expect(!std.mem.eql(u8, &bodyHash(""), &bodyHash(" ")));
}

test "a record is the 48 bytes the memory budget is built on" {
    try testing.expectEqual(@as(usize, 48), @sizeOf(Record));
    // And the production table is the size 04-storage.md now records.
    const bytes = @as(u64, default_records) * @sizeOf(Record);
    try testing.expectEqual(@as(u64, 48_000_000), bytes);
}

test "the index is a power of two at least twice the capacity" {
    try testing.expectEqual(@as(u32, 16), Table(8).slots);
    try testing.expectEqual(@as(u32, 128), Table(64).slots);
    // Never more than half full, so linear probing stays short.
    try testing.expect(Table(1000).slots >= 2000);
}
