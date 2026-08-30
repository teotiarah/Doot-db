//! Spike C server: minimal HTTP/1.1 + keep-alive on std.Io.Uring.
//!
//! Measures the two numbers D14 asserts:
//!   1. requests/sec on a trivial handler
//!   2. RSS at N idle keep-alive connections
//!
//! Throwaway. Deleted at M1.
//!
//! usage: server <backend:uring|threaded> <port> <per_conn_buf_bytes>

const std = @import("std");
const Io = std.Io;
const net = Io.net;

var live_conns: std.atomic.Value(i64) = .init(0);
var total_conns: std.atomic.Value(u64) = .init(0);
var total_reqs: std.atomic.Value(u64) = .init(0);
var peak_conns: std.atomic.Value(i64) = .init(0);

const response =
    "HTTP/1.1 200 OK\r\n" ++
    "Content-Type: text/plain\r\n" ++
    "Content-Length: 3\r\n" ++
    "\r\n" ++
    "ok\n";

pub fn main(init: std.process.Init.Minimal) !void {
    var args = init.args.iterate();
    _ = args.next();
    const backend = args.next() orelse "uring";
    const port = try std.fmt.parseInt(u16, args.next() orelse "9797", 10);
    const buf_size = try std.fmt.parseInt(usize, args.next() orelse "8192", 10);

    // page_allocator so fiber stacks are mmap'd and lazily committed. Whether
    // that actually holds is the thing this spike measures.
    const gpa = std.heap.page_allocator;

    if (std.mem.eql(u8, backend, "threaded")) {
        var th: Io.Threaded = .init(gpa, .{});
        defer th.deinit();
        std.debug.print("backend=threaded async_limit=default\n", .{});
        return run(th.io(), gpa, port, buf_size);
    }

    var ev: Io.Uring = undefined;
    try Io.Uring.init(&ev, gpa, .{ .log2_ring_entries = 12 });
    defer ev.deinit();
    std.debug.print("backend=uring\n", .{});
    return run(ev.io(), gpa, port, buf_size);
}

fn run(io: Io, gpa: std.mem.Allocator, port: u16, buf_size: usize) !void {
    const addr: net.IpAddress = .{ .ip4 = .loopback(port) };
    var server = try addr.listen(io, .{
        .reuse_address = true,
        .kernel_backlog = 8192,
    });
    defer server.deinit(io);

    std.debug.print(
        "listening on 127.0.0.1:{d}  per-conn buffer={d}B  baseline rss={d}KB vsz={d}KB\n",
        .{ port, buf_size, rssKb(), vszKb() },
    );

    var group: Io.Group = .init;

    group.async(io, reporter, .{io});

    while (true) {
        const stream = server.accept(io) catch |err| switch (err) {
            error.Canceled => break,
            else => {
                std.debug.print("accept error: {t}\n", .{err});
                continue;
            },
        };
        group.async(io, handle, .{ io, gpa, stream, buf_size });
    }
}

fn handle(io: Io, gpa: std.mem.Allocator, stream: net.Stream, buf_size: usize) Io.Cancelable!void {
    defer stream.close(io);

    const n = live_conns.fetchAdd(1, .monotonic) + 1;
    _ = total_conns.fetchAdd(1, .monotonic);
    _ = peak_conns.fetchMax(n, .monotonic);
    defer _ = live_conns.fetchSub(1, .monotonic);

    const rbuf = gpa.alloc(u8, buf_size) catch return;
    defer gpa.free(rbuf);
    const wbuf = gpa.alloc(u8, 256) catch return;
    defer gpa.free(wbuf);

    var reader = stream.reader(io, rbuf);
    var writer = stream.writer(io, wbuf);

    // Keep-alive loop: consume request head, reply, repeat.
    while (true) {
        var saw_any = false;
        while (true) {
            const line = reader.interface.takeDelimiterInclusive('\n') catch return;
            saw_any = true;
            if (line.len <= 2) break; // bare CRLF: end of head
        }
        if (!saw_any) return;

        writer.interface.writeAll(response) catch return;
        writer.interface.flush() catch return;
        _ = total_reqs.fetchAdd(1, .monotonic);
    }
}

fn reporter(io: Io) Io.Cancelable!void {
    var last_reqs: u64 = 0;
    while (true) {
        try io.sleep(.fromMilliseconds(1000), .awake);
        const reqs = total_reqs.load(.monotonic);
        const live = live_conns.load(.monotonic);
        const rss = rssKb();
        const per_conn: f64 = if (live > 0)
            @as(f64, @floatFromInt(rss)) / @as(f64, @floatFromInt(live))
        else
            0;
        std.debug.print(
            "live={d:<6} peak={d:<6} rps={d:<8} rss={d}KB ({d:.2}KB/conn) vsz={d}KB\n",
            .{ live, peak_conns.load(.monotonic), reqs - last_reqs, rss, per_conn, vszKb() },
        );
        last_reqs = reqs;
    }
}

fn statmField(index: usize) u64 {
    var buf: [256]u8 = undefined;
    const linux = std.os.linux;
    const rc = linux.open("/proc/self/statm", .{ .ACCMODE = .RDONLY }, 0);
    if (@as(isize, @bitCast(rc)) < 0) return 0;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    const nr = linux.read(fd, &buf, buf.len);
    if (@as(isize, @bitCast(nr)) < 0) return 0;
    const n: usize = nr;
    var it = std.mem.tokenizeScalar(u8, buf[0..n], ' ');
    var i: usize = 0;
    while (it.next()) |tok| : (i += 1) {
        if (i == index) {
            const pages = std.fmt.parseInt(u64, std.mem.trim(u8, tok, " \n"), 10) catch return 0;
            return pages * 4; // KB, assuming 4KiB pages
        }
    }
    return 0;
}

/// Resident set size in KB.
fn rssKb() u64 {
    return statmField(1);
}

/// Virtual size in KB. Fiber stacks are reserved here even when not committed.
fn vszKb() u64 {
    return statmField(0);
}
