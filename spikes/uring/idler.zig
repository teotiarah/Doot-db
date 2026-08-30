//! Opens N keep-alive connections, does one request/response on each, then
//! holds every one of them idle. Sequential and blocking on purpose: the server
//! answers immediately, so no client-side concurrency is needed, and this keeps
//! the measurement about the *server's* cost of holding idle connections.
//!
//! Throwaway. Deleted at M1.
//!
//! usage: idler <port> <conns> <hold_seconds>

const std = @import("std");
const linux = std.os.linux;

const request = "GET /x HTTP/1.1\r\nHost: localhost\r\n\r\n";

fn ok(rc: usize) bool {
    return @as(isize, @bitCast(rc)) >= 0;
}

pub fn main(init: std.process.Init.Minimal) !void {
    var args = init.args.iterate();
    _ = args.next();
    const port = try std.fmt.parseInt(u16, args.next() orelse "9797", 10);
    const want = try std.fmt.parseInt(usize, args.next() orelse "1000", 10);
    const hold_s = try std.fmt.parseInt(u64, args.next() orelse "20", 10);

    const gpa = std.heap.page_allocator;
    const fds = try gpa.alloc(i32, want);
    defer gpa.free(fds);

    const addr: linux.sockaddr.in = .{
        .port = std.mem.nativeToBig(u16, port),
        .addr = std.mem.nativeToBig(u32, 0x7f00_0001), // 127.0.0.1
    };

    var established: usize = 0;
    var connect_fail: usize = 0;
    var io_fail: usize = 0;
    var buf: [512]u8 = undefined;

    for (0..want) |_| {
        const src = linux.socket(linux.AF.INET, linux.SOCK.STREAM, 0);
        if (!ok(src)) {
            connect_fail += 1;
            continue;
        }
        const fd: i32 = @intCast(src);

        if (!ok(linux.connect(fd, &addr, @sizeOf(linux.sockaddr.in)))) {
            _ = linux.close(fd);
            connect_fail += 1;
            continue;
        }

        // One real request so the connection is past accept and genuinely live.
        if (!ok(linux.write(fd, request.ptr, request.len))) {
            _ = linux.close(fd);
            io_fail += 1;
            continue;
        }
        const n = linux.read(fd, &buf, buf.len);
        if (!ok(n) or n == 0) {
            _ = linux.close(fd);
            io_fail += 1;
            continue;
        }

        fds[established] = fd;
        established += 1;

        if (established % 1000 == 0) {
            std.debug.print("  established {d}\n", .{established});
        }
    }

    std.debug.print(
        "established={d} connect_fail={d} io_fail={d} — holding idle {d}s\n",
        .{ established, connect_fail, io_fail, hold_s },
    );

    // Hold everything open, touching nothing.
    var ts: linux.timespec = .{ .sec = @intCast(hold_s), .nsec = 0 };
    _ = linux.nanosleep(&ts, &ts);

    for (fds[0..established]) |fd| _ = linux.close(fd);
    std.debug.print("closed {d}\n", .{established});
}
