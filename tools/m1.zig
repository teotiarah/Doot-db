//! M1 exit-condition harness (docs/08-roadmap.md).
//!
//! Each subcommand proves one exit condition and prints a measured number. None
//! of them assert on wall-clock behaviour: the engine's clock is injected, so the
//! 24-hour soak runs in seconds (D33).
//!
//!   crash    <workdir>              crash injection at every fsync boundary
//!   recovery <workdir> [records]    recovery time with a realistic tail
//!   memory   <workdir> [entries]    index bytes per live entry
//!   soak     <workdir> [hours]      compaction events over simulated time
//!   tags     <workdir>              tag traversal across overwrite/delete/expiry/class
//!   all      <workdir>              everything, with a pass/fail summary

const std = @import("std");
const storage = @import("storage");

const os = storage.os;
const config = storage.config;

const child_binary = "./zig-out/bin/crashchild";

var failures: u32 = 0;

fn hdr(comptime name: []const u8) void {
    std.debug.print("\n=== {s} ===\n", .{name});
}
fn pass(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("  PASS  " ++ fmt ++ "\n", args);
}
fn fail(comptime fmt: []const u8, args: anytype) void {
    failures += 1;
    std.debug.print("  FAIL  " ++ fmt ++ "\n", args);
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    var args = init.minimal.args.iterate();
    _ = args.next();
    const which = args.next() orelse "all";
    const workdir = args.next() orelse "/tmp/doot_m1";
    const arg3 = args.next();

    {
        const wd = try dupZ(gpa, workdir);
        defer gpa.free(wd);
        os.mkdir(os.cwd, wd) catch {};
    }

    const all = std.mem.eql(u8, which, "all");
    if (all or std.mem.eql(u8, which, "crash")) try crashSweep(gpa, workdir);
    if (all or std.mem.eql(u8, which, "recovery")) try recoveryTiming(gpa, workdir, parse(arg3, 300_000), parse(args.next(), 1024));
    if (all or std.mem.eql(u8, which, "memory")) try memoryPerEntry(gpa, parse(arg3, 1_000_000));
    if (all or std.mem.eql(u8, which, "soak")) try soak(gpa, workdir, parse(arg3, 24));
    if (all or std.mem.eql(u8, which, "tags")) try tagTraversal(gpa, workdir);

    std.debug.print("\n{s}: {d} failure(s)\n", .{ if (failures == 0) "ALL EXIT CONDITIONS MET" else "EXIT CONDITIONS NOT MET", failures });
    return if (failures == 0) 0 else 1;
}

fn parse(s: ?[:0]const u8, default: u64) u64 {
    const v = s orelse return default;
    return std.fmt.parseInt(u64, v, 10) catch default;
}

fn dupZ(gpa: std.mem.Allocator, s: []const u8) ![:0]u8 {
    return gpa.dupeZ(u8, s);
}

fn subdir(gpa: std.mem.Allocator, parent: []const u8, name: []const u8) ![:0]u8 {
    return std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ parent, name }, 0);
}

/// Removes and recreates a directory so each case starts clean.
fn freshDir(gpa: std.mem.Allocator, path: [:0]const u8) !os.Fd {
    if (os.openDir(os.cwd, path)) |d| {
        var it = os.DirIterator.init(d);
        while (try it.next()) |e| {
            const n = try dupZ(gpa, e.name);
            defer gpa.free(n);
            os.unlink(d, n) catch {};
        }
        os.close(d);
        _ = std.os.linux.unlinkat(os.cwd, path.ptr, std.os.linux.AT.REMOVEDIR);
    } else |_| {}
    try os.mkdir(os.cwd, path);
    return os.openDir(os.cwd, path);
}

// ---------------------------------------------------------------------------
// 1. Crash injection at every fsync boundary
// ---------------------------------------------------------------------------

fn runChild(gpa: std.mem.Allocator, argv: []const []const u8) !os.Exit {
    var stack: [8]?[*:0]const u8 = @splat(null);
    var owned: [8][:0]u8 = undefined;
    var n: usize = 0;
    defer for (0..n) |i| gpa.free(owned[i]);

    for (argv) |a| {
        owned[n] = try dupZ(gpa, a);
        stack[n] = owned[n].ptr;
        n += 1;
    }
    const pid = try os.spawn(stack[0].?, @ptrCast(&stack));
    return os.wait(pid);
}

fn crashSweep(gpa: std.mem.Allocator, workdir: []const u8) !void {
    hdr("exit condition 1: crash injection at every fsync boundary");

    const dir_path = try subdir(gpa, workdir, "crash");
    defer gpa.free(dir_path);

    // Baseline run with no crash armed, to learn how many flush points exist.
    _ = os.close(try freshDir(gpa, dir_path));
    const base = try runChild(gpa, &.{ child_binary, "run", dir_path, "0" });
    switch (base) {
        .exited => |c| {
            if (c != 0) {
                fail("baseline run exited {d}", .{c});
                return;
            }
        },
        .signaled => |sig| {
            fail("baseline run died on signal {d}", .{sig});
            return;
        },
    }

    const total = blk: {
        const d = try os.openDir(os.cwd, dir_path);
        defer os.close(d);
        const fd = try os.open(d, "FSYNCS", .{});
        defer os.close(fd);
        var b: [8]u8 = undefined;
        _ = try os.preadAll(fd, &b, 0);
        break :blk std.mem.readInt(u64, &b, .little);
    };
    std.debug.print("  workload performs {d} engine fsyncs; testing a crash at each\n", .{total});
    if (total == 0) {
        fail("workload performed no fsyncs, so nothing was tested", .{});
        return;
    }

    var killed: u32 = 0;
    var finished: u32 = 0;
    var bad: u32 = 0;

    var n: u64 = 1;
    while (n <= total) : (n += 1) {
        _ = os.close(try freshDir(gpa, dir_path));

        var nb: [24]u8 = undefined;
        const narg = try std.fmt.bufPrint(&nb, "{d}", .{n});
        const r = try runChild(gpa, &.{ child_binary, "run", dir_path, narg });
        switch (r) {
            .signaled => |sig| {
                if (sig == 9) {
                    killed += 1;
                } else {
                    fail("crash point {d}: unexpected signal {d}", .{ n, sig });
                    bad += 1;
                }
            },
            .exited => |c| {
                // Ran to completion: the arming point was past the last flush.
                if (c == 0) {
                    finished += 1;
                } else {
                    fail("crash point {d}: exited {d}", .{ n, c });
                    bad += 1;
                }
            },
        }

        const v = try runChild(gpa, &.{ child_binary, "verify", dir_path });
        switch (v) {
            .exited => |c| {
                if (c != 0) {
                    fail("crash point {d}: verification failed", .{n});
                    bad += 1;
                }
            },
            .signaled => |sig| {
                fail("crash point {d}: verifier crashed on signal {d}", .{ n, sig });
                bad += 1;
            },
        }
    }

    if (bad == 0) {
        pass("{d} crash points, all recovered: no acknowledged write lost, nothing resurrected", .{total});
        std.debug.print("        ({d} killed mid-run, {d} completed before the armed point)\n", .{ killed, finished });
    }
}

// ---------------------------------------------------------------------------
// 2. Recovery time
// ---------------------------------------------------------------------------

fn recoveryTiming(gpa: std.mem.Allocator, workdir: []const u8, records: u64, body_size: u64) !void {
    hdr("exit condition 2: recovery under 10 s with a realistic tail");

    const dir_path = try subdir(gpa, workdir, "recovery");
    defer gpa.free(dir_path);
    var dir = try freshDir(gpa, dir_path);

    // 1 KiB by default, the figure docs/04-storage.md uses for its tail estimate.
    const body = try gpa.alloc(u8, body_size);
    defer gpa.free(body);
    @memset(body, 'r');

    var mclock: storage.clock.Manual = .init(1_700_000_000);
    const o: config.Options = .{ .index_hash_key = @splat(1), .max_ttl_s = 30 * 24 * 60 * 60 };

    {
        const s = try storage.Store.open(gpa, dir, mclock.clock(), o);
        // Snapshot immediately, so everything written afterwards is tail.
        try s.snapshot();

        var nb: [32]u8 = undefined;
        const t0 = os.monotonicMillis();
        var i: u64 = 0;
        while (i < records) : (i += 1) {
            const name = try std.fmt.bufPrint(&nb, "tail/{d}", .{i});
            _ = try s.put(1, name, body, "application/octet-stream", &.{"t"}, 20 * 24 * 60 * 60);
        }
        const write_ms = os.monotonicMillis() - t0;
        std.debug.print("  wrote {d} records ({d} MiB) in {d} ms\n", .{
            records,
            (records * (body_size + 76)) / (1024 * 1024),
            write_ms,
        });

        // Tear down without a final snapshot: the tail must be replayed.
        s.abandon();
    }

    os.close(dir);
    dir = try os.openDir(os.cwd, dir_path);
    defer os.close(dir);

    const s2 = try storage.Store.open(gpa, dir, mclock.clock(), o);
    defer s2.close();
    const st = s2.stats();

    const bytes = st.recovery_records * (body_size + 76);
    const rate = if (st.recovery_ms > 0) (bytes * 1000) / (st.recovery_ms * 1024 * 1024) else 0;
    std.debug.print("  replayed {d} records ({d} MiB) in {d} ms  =>  {d} MiB/s, {d} ns/record\n", .{
        st.recovery_records, bytes / (1024 * 1024), st.recovery_ms, rate,
        if (st.recovery_records > 0) (st.recovery_ms * 1_000_000) / st.recovery_records else 0,
    });
    if (st.index.live != records) {
        fail("recovered {d} live entries, expected {d}", .{ st.index.live, records });
        return;
    }
    if (st.recovery_ms > config.recovery_target_ms) {
        fail("recovery took {d} ms, target is {d} ms", .{ st.recovery_ms, config.recovery_target_ms });
        return;
    }
    pass("recovery {d} ms for {d} records, target {d} ms", .{ st.recovery_ms, records, config.recovery_target_ms });
}

// ---------------------------------------------------------------------------
// 3. Index memory per live entry
// ---------------------------------------------------------------------------

fn memoryPerEntry(gpa: std.mem.Allocator, entries: u64) !void {
    hdr("exit condition 3: index within 10% of 29 bytes per live entry");

    // The claim is about the index, so measure the index rather than the process.
    // Sized to the admission point, which is where docs/04-storage.md's figure
    // applies: 20 bytes per slot at 0.70 occupancy.
    const slots_needed = entries * config.index_max_load_den / config.index_max_load_num;
    const budget = slots_needed * config.index_slot_bytes;

    var idx = try storage.index.Index.init(gpa, .{
        .index_hash_key = @splat(2),
        .max_index_bytes = budget,
    });
    defer idx.deinit();

    const now: u32 = 1_700_000_000;
    var nb: [32]u8 = undefined;
    var inserted: u64 = 0;
    var i: u64 = 0;
    while (i < entries) : (i += 1) {
        const name = try std.fmt.bufPrint(&nb, "mem/{d}", .{i});
        const h = idx.hash(1, name);
        _ = idx.upsert(h, null, storage.location.none, storage.Location.init(0, 1, 64), now + 100_000, now) catch break;
        inserted += 1;
    }

    const st = idx.stats();
    const per = st.bytesPerLiveEntry();
    std.debug.print("  {d} live entries, {d} slots, {d} bytes, occupancy {d:.3}\n", .{
        st.live, st.capacity, st.bytes, st.occupancy(),
    });
    std.debug.print("  {d:.2} bytes per live entry\n", .{per});

    // 20 / 0.70 = 28.57; the exit condition allows 10%.
    const target: f64 = @as(f64, config.index_slot_bytes) *
        @as(f64, config.index_max_load_den) / @as(f64, config.index_max_load_num);
    if (per > target * 1.10 or per < target * 0.90) {
        fail("{d:.2} B/entry is outside 10% of {d:.2}", .{ per, target });
        return;
    }
    pass("{d:.2} B/entry at {d} entries, within 10% of {d:.2}", .{ per, st.live, target });
}

// ---------------------------------------------------------------------------
// 4. Compaction-free soak over simulated time
// ---------------------------------------------------------------------------

fn soak(gpa: std.mem.Allocator, workdir: []const u8, hours: u64) !void {
    hdr("exit condition 4: zero compaction over a 24 h mixed-lifetime soak");

    const dir_path = try subdir(gpa, workdir, "soak");
    defer gpa.free(dir_path);
    const dir = try freshDir(gpa, dir_path);
    defer os.close(dir);

    var mclock: storage.clock.Manual = .init(1_700_000_000);
    const s = try storage.Store.open(gpa, dir, mclock.clock(), .{
        .segment_bytes = 256 * 1024, // small, so rotation and reclamation both happen often
        .index_hash_key = @splat(3),
        .max_ttl_s = 30 * 24 * 60 * 60,
        .snapshot_interval_s = 300,
    });
    defer s.close();

    const body = try gpa.alloc(u8, 1024);
    defer gpa.free(body);
    @memset(body, 's');

    // A realistic mix: mostly short lifetimes, a long tail of long ones. This is
    // the shape that would pin space if classes did not exist.
    const ttls = [_]u32{ 300, 900, 1800, 3600, 6 * 3600, 24 * 3600, 3 * 86400, 20 * 86400 };
    const weights = [_]u32{ 30, 20, 15, 10, 10, 8, 5, 2 };
    var total_weight: u32 = 0;
    for (weights) |w| total_weight += w;

    var prng = std.Random.DefaultPrng.init(0xD007);
    const rand = prng.random();

    var nb: [32]u8 = undefined;
    var written: u64 = 0;
    var deleted: u64 = 0;

    // One simulated minute per step, writing a small batch each time.
    const steps = hours * 60;
    var step: u64 = 0;
    while (step < steps) : (step += 1) {
        var b: u32 = 0;
        while (b < 12) : (b += 1) {
            const roll = rand.intRangeLessThan(u32, 0, total_weight);
            var acc: u32 = 0;
            var ttl: u32 = ttls[0];
            for (ttls, weights) |t, w| {
                acc += w;
                if (roll < acc) {
                    ttl = t;
                    break;
                }
            }
            const name = try std.fmt.bufPrint(&nb, "soak/{d}", .{written});
            _ = try s.put(1, name, body, "", &.{"soak"}, ttl);
            written += 1;

            // Some churn, so dead index slots and superseded records both occur.
            if (written % 17 == 0 and written > 40) {
                const victim = try std.fmt.bufPrint(&nb, "soak/{d}", .{written - 40});
                if (try s.delete(1, victim)) deleted += 1;
            }
        }

        mclock.advance(60);
        _ = try s.maintain();
    }

    const st = s.stats();
    std.debug.print("  simulated {d} h: {d} writes, {d} deletes\n", .{ hours, written, deleted });
    std.debug.print("  segments now {d} ({d} sealed), {d} reclaimed wholesale\n", .{
        st.segments.segments, st.segments.sealed, st.segments.reclaimed,
    });
    std.debug.print("  dead bytes in live segments: {d}; compaction candidates: {d}\n", .{
        st.segments.dead_bytes, st.segments.compaction_candidates,
    });
    std.debug.print("  index live {d}, dead {d}, {d:.2} B/live entry\n", .{
        st.index.live, st.index.dead, st.index.bytesPerLiveEntry(),
    });
    std.debug.print("  tag heads: {d} pairs, {d} bytes\n", .{ st.tags.pairs, st.tags.bytes });

    if (st.segments.reclaimed == 0) {
        fail("nothing was reclaimed, so the soak did not exercise expiry", .{});
        return;
    }
    // The claim: bounded lifetime replaces compaction. The compactor is the
    // escape hatch and must never have been needed.
    if (st.segments.compactions != 0) {
        fail("{d} compaction event(s) occurred", .{st.segments.compactions});
        return;
    }
    // The stronger statement: no segment ever even met the trigger.
    if (st.segments.compaction_candidates != 0) {
        fail("{d} segment(s) met the compaction trigger, so the escape hatch was needed", .{st.segments.compaction_candidates});
        return;
    }
    pass("0 compactions over {d} simulated hours, {d} segments reclaimed by unlink", .{ hours, st.segments.reclaimed });
}

// ---------------------------------------------------------------------------
// 5. Tag traversal under mutation
// ---------------------------------------------------------------------------

const Collector = struct {
    seen: std.ArrayListUnmanaged([]u8) = .empty,
    gpa: std.mem.Allocator,

    fn emit(self: *Collector, _: storage.Location, rec: storage.Record) storage.store.Error!void {
        try self.seen.append(self.gpa, try self.gpa.dupe(u8, rec.name));
    }
    fn deinit(self: *Collector) void {
        for (self.seen.items) |n| self.gpa.free(n);
        self.seen.deinit(self.gpa);
    }
    fn has(self: *Collector, name: []const u8) bool {
        for (self.seen.items) |n| if (std.mem.eql(u8, n, name)) return true;
        return false;
    }
};

fn tagTraversal(gpa: std.mem.Allocator, workdir: []const u8) !void {
    hdr("exit condition 5: tag traversal across overwrite, delete, expiry, class change");

    const dir_path = try subdir(gpa, workdir, "tags");
    defer gpa.free(dir_path);
    const dir = try freshDir(gpa, dir_path);
    defer os.close(dir);

    var mclock: storage.clock.Manual = .init(1_700_000_000);
    const s = try storage.Store.open(gpa, dir, mclock.clock(), .{
        .segment_bytes = 128 * 1024,
        .index_hash_key = @splat(4),
        .max_ttl_s = 30 * 24 * 60 * 60,
    });
    defer s.close();

    // plain: written once. rewritten: overwritten repeatedly. mover: changes
    // class. doomed: deleted. lapsing: expires. Every case in one chain.
    _ = try s.put(1, "plain", "v", "", &.{"mix"}, 20 * 86400);
    mclock.advance(1);
    for (0..4) |_| {
        _ = try s.put(1, "rewritten", "v", "", &.{"mix"}, 20 * 86400);
        mclock.advance(1);
    }
    _ = try s.put(1, "mover", "v1", "", &.{"mix"}, 600); // class 0
    mclock.advance(1);
    _ = try s.put(1, "doomed", "v", "", &.{"mix"}, 20 * 86400);
    mclock.advance(1);
    _ = try s.put(1, "lapsing", "v", "", &.{"mix"}, 300);
    mclock.advance(1);
    _ = try s.put(1, "mover", "v2", "", &.{"mix"}, 20 * 86400); // now class 3
    mclock.advance(1);
    _ = try s.delete(1, "doomed");

    mclock.advance(400); // "lapsing" is now past its deadline

    var c: Collector = .{ .gpa = gpa };
    defer c.deinit();
    const r = try s.list(1, "mix", 100, .{}, &c, Collector.emit);

    std.debug.print("  emitted {d} of {d} hops walked\n", .{ r.emitted, r.hops });
    for (c.seen.items) |n| std.debug.print("    {s}\n", .{n});

    var ok = true;
    if (!c.has("plain")) {
        fail("plain entry missing", .{});
        ok = false;
    }
    if (!c.has("rewritten")) {
        fail("overwritten entry missing", .{});
        ok = false;
    }
    if (!c.has("mover")) {
        fail("class-changed entry missing", .{});
        ok = false;
    }
    if (c.has("doomed")) {
        fail("deleted entry still listed", .{});
        ok = false;
    }
    if (c.has("lapsing")) {
        fail("expired entry still listed", .{});
        ok = false;
    }
    if (r.emitted != 3) {
        fail("expected exactly 3 live entries, got {d}", .{r.emitted});
        ok = false;
    }
    // Superseded versions must have been walked and rejected, not absent.
    if (r.hops <= r.emitted) {
        fail("hops {d} did not exceed emitted {d}, so stale links were not exercised", .{ r.hops, r.emitted });
        ok = false;
    }

    // And it must survive a restart, since heads come from the snapshot.
    if (ok) {
        try s.snapshot();
        pass("3 live of {d} hops; deleted, expired and superseded all excluded", .{r.hops});
    }
}
