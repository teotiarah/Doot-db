//! Spike C, the real one: minimal HTTP/1.1 + keep-alive directly on
//! std.os.linux.IoUring.
//!
//! std.Io.Uring has no networking in Zig 0.16.0 (13 vtable entries are
//! Unavailable stubs) and std.Io.Threaded wedges at async_limit connections
//! because every idle keep-alive connection permanently owns a pool thread.
//! So this measures the third option: drive the ring ourselves.
//!
//! Connection state is a struct we size, not a fiber with a reserved stack,
//! which is the whole point.
//!
//! Throwaway. Deleted at M1.
//!
//! usage: ringserver <port> <per_conn_buf_bytes> [page|slab]
//!
//! page = one page_allocator allocation per Conn and per buffer (naive)
//! slab = Conn from a static array, buffers carved from one arena (pooled)

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const IoUring = linux.IoUring;

const max_fd = 65_536;

const Op = enum(u8) { accept = 1, recv = 2, send = 3, close = 4, tick = 5 };

fn ud(op: Op, fd: i32) u64 {
    return (@as(u64, @intFromEnum(op)) << 32) | @as(u64, @as(u32, @bitCast(fd)));
}
fn udOp(v: u64) u8 {
    return @intCast(v >> 32);
}
fn udFd(v: u64) i32 {
    return @bitCast(@as(u32, @truncate(v)));
}

/// Per-connection state. Deliberately small and explicit: this struct plus its
/// read buffer is the entire memory cost of holding a connection open.
const Conn = struct {
    buf: []u8,
    /// Bytes of a request head accumulated so far.
    len: usize = 0,
};

const response =
    "HTTP/1.1 200 OK\r\n" ++
    "Content-Type: text/plain\r\n" ++
    "Content-Length: 3\r\n" ++
    "\r\n" ++
    "ok\n";

const max_pipeline = 512;
/// One shared read-only buffer of `max_pipeline` identical responses. Because
/// every response is byte-identical, a pipelined reply is just a slice of this,
/// which keeps pipelining free of per-connection memory.
var response_batch: [max_pipeline * response.len]u8 = undefined;

var conns: [max_fd]?*Conn = @splat(null);

/// Pooled allocation. Conn structs live in one static array and read buffers are
/// carved from a single arena, so small buffers pack many per page instead of
/// each burning a whole one.
var slab_mode = false;
var conn_slab: [max_fd]Conn = undefined;
var buf_arena: []u8 = &.{};
var buf_stride: usize = 0;
var live: i64 = 0;
var peak: i64 = 0;
var reqs: u64 = 0;

pub fn main(init: std.process.Init.Minimal) !void {
    var args = init.args.iterate();
    _ = args.next();
    const port = try std.fmt.parseInt(u16, args.next() orelse "9797", 10);
    const buf_size = try std.fmt.parseInt(usize, args.next() orelse "8192", 10);
    slab_mode = std.mem.eql(u8, args.next() orelse "page", "slab");

    const gpa = std.heap.page_allocator;

    for (0..max_pipeline) |i| {
        @memcpy(response_batch[i * response.len ..][0..response.len], response);
    }

    var ring = try IoUring.init(4096, 0);
    defer ring.deinit();

    const lfd = try listenSocket(port);
    defer _ = linux.close(lfd);

    if (slab_mode) {
        buf_stride = buf_size;
        buf_arena = try gpa.alloc(u8, buf_stride * max_fd);
    }

    std.debug.print(
        "ringserver on 127.0.0.1:{d} buf={d}B sizeOf(Conn)={d}B mode={s} baseline rss={d}KB vsz={d}KB\n",
        .{ port, buf_size, @sizeOf(Conn), if (slab_mode) "slab" else "page", rssKb(), vszKb() },
    );

    _ = try ring.accept_multishot(ud(.accept, lfd), lfd, null, null, 0);

    // Without this the ring blocks forever on an idle server and housekeeping
    // never runs. A real server needs the same timer for expiry sweeps.
    const tick_ts: linux.kernel_timespec = .{ .sec = 1, .nsec = 0 };
    _ = try ring.timeout(ud(.tick, 0), &tick_ts, 0, 0);
    _ = try ring.submit();

    var cqes: [512]linux.io_uring_cqe = undefined;
    var last_report = nowMs();
    var last_reqs: u64 = 0;

    while (true) {
        // Wait for at least one completion, but with a timeout so the reporter
        // still runs on an idle server.
        const n = ring.copy_cqes(&cqes, 1) catch |err| switch (err) {
            error.SignalInterrupt => continue,
            else => return err,
        };

        for (cqes[0..n]) |cqe| {
            const fd = udFd(cqe.user_data);
            switch (@as(Op, @enumFromInt(udOp(cqe.user_data)))) {
                .accept => {
                    if (cqe.res >= 0) {
                        const cfd = cqe.res;
                        if (cfd < max_fd) try onAccept(&ring, gpa, cfd, buf_size);
                    }
                    // Multishot accept is re-armed by the kernel unless F_MORE
                    // is clear, in which case we must re-post it.
                    if (cqe.flags & linux.IORING_CQE_F_MORE == 0) {
                        _ = try ring.accept_multishot(ud(.accept, fd), fd, null, null, 0);
                    }
                },
                .recv => {
                    if (cqe.res <= 0) {
                        closeConn(&ring, gpa, fd);
                    } else {
                        try onRecv(&ring, gpa, fd, @intCast(cqe.res));
                    }
                },
                .send => {
                    if (cqe.res < 0) {
                        closeConn(&ring, gpa, fd);
                    } else if (conns[@intCast(fd)]) |c| {
                        // Ready for the next request on this keep-alive conn.
                        _ = try ring.recv(ud(.recv, fd), fd, .{ .buffer = c.buf[c.len..] }, 0);
                    }
                },
                .close => {},
                .tick => {
                    _ = try ring.timeout(ud(.tick, 0), &tick_ts, 0, 0);
                },
            }
        }
        _ = try ring.submit();

        const now = nowMs();
        if (now - last_report >= 1000) {
            const rss = rssKb();
            const per: f64 = if (live > 0)
                @as(f64, @floatFromInt(rss)) / @as(f64, @floatFromInt(live))
            else
                0;
            std.debug.print(
                "live={d} peak={d} rps={d} rss={d}KB ({d:.2}KB/conn) vsz={d}KB\n",
                .{ @as(u64, @intCast(live)), @as(u64, @intCast(peak)), reqs - last_reqs, rss, per, vszKb() },
            );
            last_reqs = reqs;
            last_report = now;
        }
    }
}

fn onAccept(ring: *IoUring, gpa: std.mem.Allocator, cfd: i32, buf_size: usize) !void {
    const c = blk: {
        if (slab_mode) {
            // Indexing both by fd needs no free list: the kernel already
            // guarantees fds are unique among open connections.
            const c = &conn_slab[@intCast(cfd)];
            const off = @as(usize, @intCast(cfd)) * buf_stride;
            c.* = .{ .buf = buf_arena[off .. off + buf_size] };
            break :blk c;
        }
        const c = gpa.create(Conn) catch {
            _ = linux.close(cfd);
            return;
        };
        c.* = .{ .buf = gpa.alloc(u8, buf_size) catch {
            gpa.destroy(c);
            _ = linux.close(cfd);
            return;
        } };
        break :blk c;
    };
    conns[@intCast(cfd)] = c;
    live += 1;
    if (live > peak) peak = live;

    // TCP_NODELAY: small responses are all this service ever sends.
    const one: u32 = 1;
    _ = linux.setsockopt(cfd, linux.IPPROTO.TCP, linux.TCP.NODELAY, @ptrCast(&one), 4);

    _ = try ring.recv(ud(.recv, cfd), cfd, .{ .buffer = c.buf }, 0);
}

fn onRecv(ring: *IoUring, gpa: std.mem.Allocator, fd: i32, got: usize) !void {
    const c = conns[@intCast(fd)] orelse return;
    c.len += got;

    // Count every complete request head in the buffer, not just the first: a
    // pipelining client puts many in a single recv, and answering only one
    // deadlocks it. Real parsing is M2's problem; correct framing is not.
    var complete: usize = 0;
    var scan: usize = 0;
    while (std.mem.indexOf(u8, c.buf[scan..c.len], "\r\n\r\n")) |rel| {
        scan += rel + 4;
        complete += 1;
        if (complete == max_pipeline) break;
    }

    if (complete > 0) {
        // Keep any trailing partial request.
        const leftover = c.len - scan;
        if (leftover > 0) std.mem.copyForwards(u8, c.buf[0..leftover], c.buf[scan..c.len]);
        c.len = leftover;
        reqs += complete;
        _ = try ring.send(
            ud(.send, fd),
            fd,
            response_batch[0 .. complete * response.len],
            linux.MSG.NOSIGNAL,
        );
        return;
    }

    if (c.len >= c.buf.len) { // head too large for the buffer
        closeConn(ring, gpa, fd);
        return;
    }
    _ = try ring.recv(ud(.recv, fd), fd, .{ .buffer = c.buf[c.len..] }, 0);
}

fn closeConn(ring: *IoUring, gpa: std.mem.Allocator, fd: i32) void {
    _ = ring;
    if (fd < 0 or fd >= max_fd) return;
    if (conns[@intCast(fd)]) |c| {
        if (!slab_mode) {
            gpa.free(c.buf);
            gpa.destroy(c);
        }
        conns[@intCast(fd)] = null;
        live -= 1;
    }
    _ = linux.close(fd);
}

fn listenSocket(port: u16) !i32 {
    const rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM, 0);
    if (@as(isize, @bitCast(rc)) < 0) return error.SocketFailed;
    const fd: i32 = @intCast(rc);

    const one: u32 = 1;
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, @ptrCast(&one), 4);
    // SO_REUSEPORT is how this scales to one ring per core later.
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.REUSEPORT, @ptrCast(&one), 4);

    const addr: linux.sockaddr.in = .{
        .port = std.mem.nativeToBig(u16, port),
        .addr = std.mem.nativeToBig(u32, 0x7f00_0001),
    };
    if (@as(isize, @bitCast(linux.bind(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in)))) < 0)
        return error.BindFailed;
    if (@as(isize, @bitCast(linux.listen(fd, 8192))) < 0) return error.ListenFailed;
    return fd;
}

fn nowMs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(ts.nsec, 1_000_000);
}

fn statmField(index: usize) u64 {
    var buf: [256]u8 = undefined;
    const rc = linux.open("/proc/self/statm", .{ .ACCMODE = .RDONLY }, 0);
    if (@as(isize, @bitCast(rc)) < 0) return 0;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    const nr = linux.read(fd, &buf, buf.len);
    if (@as(isize, @bitCast(nr)) < 0) return 0;
    var it = std.mem.tokenizeScalar(u8, buf[0..nr], ' ');
    var i: usize = 0;
    while (it.next()) |tok| : (i += 1) {
        if (i == index) {
            return (std.fmt.parseInt(u64, std.mem.trim(u8, tok, " \n"), 10) catch return 0) * 4;
        }
    }
    return 0;
}

fn rssKb() u64 {
    return statmField(1);
}
fn vszKb() u64 {
    return statmField(0);
}
