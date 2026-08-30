//! Spike C load generator. Two modes:
//!
//!   idle  <port> <conns>            open N keep-alive conns, one request each,
//!                                   then hold them idle so server RSS can settle
//!   bench <port> <conns> <seconds>  hammer N connections with keep-alive requests
//!
//! Deliberately written on the same std.Io.Uring stack as the server so the
//! client is not the bottleneck at these connection counts.
//!
//! Throwaway. Deleted at M1.

const std = @import("std");
const Io = std.Io;
const net = Io.net;

var established: std.atomic.Value(u64) = .init(0);
var failed: std.atomic.Value(u64) = .init(0);
var completed: std.atomic.Value(u64) = .init(0);
var stop: std.atomic.Value(bool) = .init(false);

const request = "GET /x HTTP/1.1\r\nHost: localhost\r\n\r\n";

pub fn main(init: std.process.Init.Minimal) !void {
    var args = init.args.iterate();
    _ = args.next();
    const mode = args.next() orelse "bench";
    const port = try std.fmt.parseInt(u16, args.next() orelse "9797", 10);
    const conns = try std.fmt.parseInt(usize, args.next() orelse "100", 10);
    const seconds = try std.fmt.parseInt(u64, args.next() orelse "5", 10);

    const gpa = std.heap.page_allocator;

    var ev: Io.Uring = undefined;
    try Io.Uring.init(&ev, gpa, .{ .log2_ring_entries = 12 });
    defer ev.deinit();
    const io = ev.io();

    const idle = std.mem.eql(u8, mode, "idle");
    std.debug.print("mode={s} port={d} conns={d}\n", .{ mode, port, conns });

    var group: Io.Group = .init;
    const t0 = Io.Timestamp.now(io, .awake);

    for (0..conns) |_| {
        group.async(io, worker, .{ io, gpa, port, idle });
    }

    if (idle) {
        // Let connections establish, then hold them open while the server
        // reports RSS. The whole point is measuring cost of doing nothing.
        var waited: u64 = 0;
        while (waited < 60_000) : (waited += 500) {
            try io.sleep(.fromMilliseconds(500), .awake);
            if (established.load(.monotonic) + failed.load(.monotonic) >= conns) break;
        }
        std.debug.print(
            "established={d} failed={d} — holding idle for {d}s\n",
            .{ established.load(.monotonic), failed.load(.monotonic), seconds },
        );
        try io.sleep(.fromMilliseconds(@intCast(seconds * 1000)), .awake);
        stop.store(true, .monotonic);
        group.cancel(io);
        std.debug.print("done: established={d} failed={d}\n", .{
            established.load(.monotonic), failed.load(.monotonic),
        });
        return;
    }

    try io.sleep(.fromMilliseconds(@intCast(seconds * 1000)), .awake);
    stop.store(true, .monotonic);
    group.cancel(io);

    const t1 = Io.Timestamp.now(io, .awake);
    const ms = t0.durationTo(t1).toMilliseconds();
    const done = completed.load(.monotonic);
    const rps = if (ms > 0) @divTrunc(@as(i64, @intCast(done)) * 1000, ms) else 0;
    std.debug.print(
        "requests={d} in {d}ms => {d} req/s (conns={d} established={d} failed={d})\n",
        .{ done, ms, rps, conns, established.load(.monotonic), failed.load(.monotonic) },
    );
}

fn worker(io: Io, gpa: std.mem.Allocator, port: u16, idle: bool) Io.Cancelable!void {
    const addr: net.IpAddress = .{ .ip4 = .loopback(port) };
    const stream = addr.connect(io, .{ .mode = .stream }) catch {
        _ = failed.fetchAdd(1, .monotonic);
        return;
    };
    defer stream.close(io);
    _ = established.fetchAdd(1, .monotonic);

    const rbuf = gpa.alloc(u8, 1024) catch return;
    defer gpa.free(rbuf);
    const wbuf = gpa.alloc(u8, 256) catch return;
    defer gpa.free(wbuf);

    var reader = stream.reader(io, rbuf);
    var writer = stream.writer(io, wbuf);

    // One request so the connection is genuinely live and past accept, then
    // either hold it (idle) or loop (bench).
    while (!stop.load(.monotonic)) {
        writer.interface.writeAll(request) catch return;
        writer.interface.flush() catch return;

        while (true) {
            const line = reader.interface.takeDelimiterInclusive('\n') catch return;
            if (line.len <= 2) break;
        }
        // Trivial fixed body: "ok\n"
        reader.interface.discardAll(3) catch return;
        _ = completed.fetchAdd(1, .monotonic);

        if (idle) {
            // Hold the connection open, doing nothing, until cancelled.
            io.sleep(.fromMilliseconds(3_600_000), .awake) catch return;
            return;
        }
    }
}
