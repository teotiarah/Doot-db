//! Crash-injection subject and verifier (M1 exit condition 1).
//!
//! Two modes over one shared, deterministic program:
//!
//!   run <dir> <crash_after_fsync>   execute the workload; die after the Nth fsync
//!   verify <dir>                    reopen and check the invariants held
//!
//! Both derive the operation list from `buildProgram`, so the verifier knows
//! exactly what was attempted without being told.
//!
//! ## How the acknowledgement journal keeps the test honest
//!
//! After each operation *returns* — meaning the store has declared it durable —
//! the child appends the operation index to a journal and flushes it with an
//! uncounted flush, so the harness's own durability does not shift the engine's
//! crash points.
//!
//! Crashing after the engine's fsync but before the journal append leaves the
//! journal short. That direction is safe: the verifier only *requires* what the
//! journal claims, so a missing entry weakens the requirement rather than
//! inventing one. Extra surviving data is expected and allowed.
//!
//! ## Why each key is written at most once
//!
//! Operations after the last acknowledged one may also have landed — the crash
//! point is a flush boundary, not an operation boundary. If keys were rewritten,
//! an unacknowledged later write could legitimately change a key the verifier was
//! asserting on, and every assertion would have to weaken to "some value".
//!
//! So the program touches each key at most twice, and the second touch is always
//! its final one. The verifier then asserts *exactly* for any key whose last
//! operation is acknowledged, and skips the rest.

const std = @import("std");
const storage = @import("storage");

const os = storage.os;
const config = storage.config;

const start_time: u32 = 1_700_000_000;
const long_ttl: u32 = 20 * 24 * 60 * 60;
const short_ttl: u32 = 120;
const body_bytes: usize = 4096;

const ack_file = "ACKS";
const fsync_file = "FSYNCS";

const max_key = 32;

const Kind = enum { put, del, snap };

const Op = struct {
    kind: Kind,
    key: [max_key]u8 = @splat(0),
    key_len: u8 = 0,
    ttl: u32 = 0,
    /// Bodies are generated from this, so no operation needs stored payload.
    body_seed: u8 = 0,
    tag: [max_key]u8 = @splat(0),
    tag_len: u8 = 0,

    fn name(o: *const Op) []const u8 {
        return o.key[0..o.key_len];
    }
    fn tagName(o: *const Op) []const u8 {
        return o.tag[0..o.tag_len];
    }
};

fn mkOp(kind: Kind, key: []const u8, ttl: u32, seed: u8, tag: []const u8) Op {
    var o: Op = .{ .kind = kind, .ttl = ttl, .body_seed = seed };
    @memcpy(o.key[0..key.len], key);
    o.key_len = @intCast(key.len);
    @memcpy(o.tag[0..tag.len], tag);
    o.tag_len = @intCast(tag.len);
    return o;
}

fn fillBody(buf: []u8, seed: u8) void {
    for (buf, 0..) |*b, i| b.* = @intCast((@as(usize, seed) * 7 + i * 31) % 251);
}

/// The workload, identical in both modes.
///
/// Deliberately exercises segment sealing (small segments plus 2 KiB bodies),
/// tag chains, deletion, expiry, and an explicit snapshot — so the crash sweep
/// covers a flush in each of those paths, not just plain appends.
fn buildProgram(out: []Op) usize {
    var n: usize = 0;
    var kb: [max_key]u8 = undefined;

    // Keys that will later be deleted.
    for (0..6) |i| {
        const k = std.fmt.bufPrint(&kb, "del{d}", .{i}) catch unreachable;
        out[n] = mkOp(.put, k, long_ttl, @intCast(i), "d");
        n += 1;
    }
    // Keys that will lapse on their own.
    for (0..4) |i| {
        const k = std.fmt.bufPrint(&kb, "exp{d}", .{i}) catch unreachable;
        out[n] = mkOp(.put, k, short_ttl, @intCast(50 + i), "e");
        n += 1;
    }

    // The crash window: unique puts interleaved with the deletions, and a
    // snapshot partway so crash-during-snapshot is covered too.
    var puts: usize = 0;
    var dels: usize = 0;
    for (0..26) |i| {
        if (i == 12) {
            out[n] = .{ .kind = .snap };
            n += 1;
            continue;
        }
        if (i % 4 == 3 and dels < 6) {
            const k = std.fmt.bufPrint(&kb, "del{d}", .{dels}) catch unreachable;
            out[n] = mkOp(.del, k, 0, 0, "");
            dels += 1;
            n += 1;
            continue;
        }
        const k = std.fmt.bufPrint(&kb, "put{d}", .{puts}) catch unreachable;
        var tb: [max_key]u8 = undefined;
        const t = std.fmt.bufPrint(&tb, "p{d}", .{puts % 3}) catch unreachable;
        out[n] = mkOp(.put, k, long_ttl, @intCast(100 + puts), t);
        puts += 1;
        n += 1;
    }
    return n;
}

fn opts() config.Options {
    return .{
        // Small enough that the workload seals and rotates segments.
        .segment_bytes = 64 * 1024,
        .index_hash_key = @splat(0x5A),
        .max_ttl_s = 30 * 24 * 60 * 60,
    };
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    var args = init.minimal.args.iterate();
    _ = args.next();
    const mode = args.next() orelse return usage();
    const dir_path = args.next() orelse return usage();

    const dir = try os.openDir(os.cwd, dir_path);
    defer os.close(dir);

    if (std.mem.eql(u8, mode, "run")) {
        const n = try std.fmt.parseInt(u64, args.next() orelse "0", 10);
        return runWorkload(gpa, dir, n);
    }
    if (std.mem.eql(u8, mode, "verify")) return verify(gpa, dir);
    return usage();
}

fn usage() u8 {
    std.debug.print("usage: crashchild run <dir> <crash_after_fsync> | verify <dir>\n", .{});
    return 2;
}

fn runWorkload(gpa: std.mem.Allocator, dir: os.Fd, crash_after: u64) !u8 {
    var program: [64]Op = undefined;
    const count = buildProgram(&program);

    const ack = try os.open(dir, ack_file, .{ .write = true, .create = true, .truncate = true });
    defer os.close(ack);

    var mclock: storage.clock.Manual = .init(start_time);

    // Armed before the store opens, so a crash during recovery is in scope too.
    os.crash_after_fsync.store(crash_after, .monotonic);

    const s = try storage.Store.open(gpa, dir, mclock.clock(), opts());

    const body = try gpa.alloc(u8, body_bytes);
    defer gpa.free(body);

    var acks: u64 = 0;
    for (program[0..count], 0..) |*op, i| {
        switch (op.kind) {
            .put => {
                fillBody(body, op.body_seed);
                const tags = [_][]const u8{ "all", op.tagName() };
                const r = try s.put(1, op.name(), body, "application/octet-stream", &tags, op.ttl);
                // A process kill cannot detect a missing flush, because dirty
                // page cache outlives the process. Assert durability directly at
                // the moment the engine claims it.
                if (!s.com.isDurable(r.loc.class(), r.seq)) {
                    std.debug.print("FAIL op {d} ({s}) acknowledged before durable\n", .{ i, op.name() });
                    return 1;
                }
            },
            .del => {
                if (try s.delete(1, op.name())) {
                    if (!s.com.isDurable(0, s.com.lastSeq())) {
                        std.debug.print("FAIL delete {d} ({s}) acknowledged before durable\n", .{ i, op.name() });
                        return 1;
                    }
                }
            },
            .snap => try s.snapshot(),
        }

        // The operation is durable now. Record that, durably, without spending a
        // counted flush.
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, i, .little);
        try os.pwriteAll(ack, &buf, acks * 8);
        try os.fsyncUncounted(ack);
        acks += 1;
    }

    // Reached only when no crash was armed, or it was armed beyond the workload.
    // Publish the flush total so the driver knows how many crash points exist.
    var fb: [8]u8 = undefined;
    std.mem.writeInt(u64, &fb, os.fsync_count.load(.monotonic), .little);
    const f = try os.open(dir, fsync_file, .{ .write = true, .create = true, .truncate = true });
    defer os.close(f);
    try os.pwriteAll(f, &fb, 0);
    try os.fsyncUncounted(f);

    // Disarm before the clean shutdown so close() cannot trip the crash point.
    os.crash_after_fsync.store(0, .monotonic);
    s.close();
    return 0;
}

fn lastAcked(dir: os.Fd) !?u64 {
    const fd = os.open(dir, ack_file, .{}) catch |e| switch (e) {
        error.FileNotFound => return null,
        else => return e,
    };
    defer os.close(fd);
    const size = try os.fileSize(fd);
    if (size < 8) return null;

    var buf: [8]u8 = undefined;
    // Entries are appended in order, so the last complete one is the watermark.
    const idx = (size / 8) - 1;
    if (try os.preadAll(fd, &buf, idx * 8) != 8) return null;
    return std.mem.readInt(u64, &buf, .little);
}

fn verify(gpa: std.mem.Allocator, dir: os.Fd) !u8 {
    var program: [64]Op = undefined;
    const count = buildProgram(&program);
    const acked = try lastAcked(dir);

    var mclock: storage.clock.Manual = .init(start_time);
    // Never armed in verify: recovery must be allowed to finish.
    os.crash_after_fsync.store(0, .monotonic);

    const s = storage.Store.open(gpa, dir, mclock.clock(), opts()) catch |e| {
        std.debug.print("FAIL recovery errored: {t}\n", .{e});
        return 1;
    };
    defer s.close();

    const buf = try gpa.alloc(u8, storage.record.max_record_bytes);
    defer gpa.free(buf);
    const expect_body = try gpa.alloc(u8, body_bytes);
    defer gpa.free(expect_body);

    var failures: u32 = 0;
    var checked: u32 = 0;

    if (acked) |limit| {
        for (program[0..count], 0..) |*op, i| {
            if (op.kind == .snap) continue;
            // Only assert on keys whose final operation is acknowledged. A later
            // unacknowledged operation on the same key would make the expected
            // value ambiguous.
            if (lastIndexOfKey(program[0..count], op.name()) != i) continue;
            if (i > limit) continue;

            checked += 1;
            const got = s.get(1, op.name(), buf) catch |e| {
                std.debug.print("FAIL get({s}) errored: {t}\n", .{ op.name(), e });
                failures += 1;
                continue;
            };

            switch (op.kind) {
                .put => {
                    if (got == null) {
                        std.debug.print("FAIL acknowledged put lost: {s} (op {d} <= acked {d})\n", .{ op.name(), i, limit });
                        failures += 1;
                        continue;
                    }
                    fillBody(expect_body, op.body_seed);
                    if (!std.mem.eql(u8, got.?.body, expect_body)) {
                        std.debug.print("FAIL body mismatch for {s}\n", .{op.name()});
                        failures += 1;
                    }
                },
                .del => {
                    if (got != null) {
                        std.debug.print("FAIL deleted key resurrected: {s} (op {d} <= acked {d})\n", .{ op.name(), i, limit });
                        failures += 1;
                    }
                },
                .snap => unreachable,
            }
        }
    }

    // Expiry is absolute: past the deadline these must be gone whether or not
    // their writes were ever acknowledged.
    mclock.advance(short_ttl + 60);
    for (program[0..count]) |*op| {
        if (op.kind != .put or op.ttl != short_ttl) continue;
        const got = s.get(1, op.name(), buf) catch |e| {
            std.debug.print("FAIL get({s}) errored: {t}\n", .{ op.name(), e });
            failures += 1;
            continue;
        };
        if (got != null) {
            std.debug.print("FAIL expired key still readable: {s}\n", .{op.name()});
            failures += 1;
        }
    }
    mclock.set(start_time);

    // The store must still work, not merely survive.
    _ = s.put(1, "post-recovery/canary", "ok", "text/plain", &.{"canary"}, long_ttl) catch |e| {
        std.debug.print("FAIL store unusable after recovery: {t}\n", .{e});
        failures += 1;
    };
    if (failures == 0) {
        const got = s.get(1, "post-recovery/canary", buf) catch null;
        if (got == null or !std.mem.eql(u8, got.?.body, "ok")) {
            std.debug.print("FAIL canary not readable after recovery\n", .{});
            failures += 1;
        }
    }

    if (failures != 0) {
        std.debug.print("VERIFY FAILED: {d} problem(s), acked={?d}, checked={d}\n", .{ failures, acked, checked });
        return 1;
    }
    return 0;
}

fn lastIndexOfKey(program: []const Op, key: []const u8) usize {
    var last: usize = 0;
    for (program, 0..) |*o, i| {
        if (o.kind == .snap) continue;
        if (std.mem.eql(u8, o.name(), key)) last = i;
    }
    return last;
}
