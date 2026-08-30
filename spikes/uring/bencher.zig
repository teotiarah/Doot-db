//! Pipelined throughput generator. Writes a batch of P requests per connection
//! then drains the responses, so syscall overhead is amortised and the number
//! reflects server-side request processing rather than round-trip latency.
//!
//! Client and server share the same 8 cores here, so results are a floor.
//!
//! Throwaway. Deleted at M1.
//!
//! usage: bencher <port> <conns> <pipeline_depth> <seconds>

const std = @import("std");
const linux = std.os.linux;

const request = "GET /x HTTP/1.1\r\nHost: localhost\r\n\r\n";
const resp_len = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 3\r\n\r\nok\n".len;

fn ok(rc: usize) bool {
    return @as(isize, @bitCast(rc)) >= 0;
}

fn nowMs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(ts.nsec, 1_000_000);
}

pub fn main(init: std.process.Init.Minimal) !void {
    var args = init.args.iterate();
    _ = args.next();
    const port = try std.fmt.parseInt(u16, args.next() orelse "9797", 10);
    const nconns = try std.fmt.parseInt(usize, args.next() orelse "8", 10);
    const depth = try std.fmt.parseInt(usize, args.next() orelse "256", 10);
    const seconds = try std.fmt.parseInt(i64, args.next() orelse "5", 10);

    const gpa = std.heap.page_allocator;

    const addr: linux.sockaddr.in = .{
        .port = std.mem.nativeToBig(u16, port),
        .addr = std.mem.nativeToBig(u32, 0x7f00_0001),
    };

    const fds = try gpa.alloc(i32, nconns);
    defer gpa.free(fds);
    var n_up: usize = 0;
    for (0..nconns) |_| {
        const rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM, 0);
        if (!ok(rc)) continue;
        const fd: i32 = @intCast(rc);
        if (!ok(linux.connect(fd, &addr, @sizeOf(linux.sockaddr.in)))) {
            _ = linux.close(fd);
            continue;
        }
        const one: u32 = 1;
        _ = linux.setsockopt(fd, linux.IPPROTO.TCP, linux.TCP.NODELAY, @ptrCast(&one), 4);
        fds[n_up] = fd;
        n_up += 1;
    }

    // Pre-build the pipelined request batch once.
    const batch = try gpa.alloc(u8, request.len * depth);
    defer gpa.free(batch);
    for (0..depth) |i| @memcpy(batch[i * request.len ..][0..request.len], request);

    const rbuf = try gpa.alloc(u8, resp_len * depth + 4096);
    defer gpa.free(rbuf);

    std.debug.print("conns={d} depth={d} for {d}s\n", .{ n_up, depth, seconds });

    var done: u64 = 0;
    const t0 = nowMs();
    const deadline = t0 + seconds * 1000;

    outer: while (nowMs() < deadline) {
        for (fds[0..n_up]) |fd| {
            var sent: usize = 0;
            while (sent < batch.len) {
                const w = linux.write(fd, batch.ptr + sent, batch.len - sent);
                if (!ok(w) or w == 0) break :outer;
                sent += w;
            }
            const want = resp_len * depth;
            var got: usize = 0;
            while (got < want) {
                const r = linux.read(fd, rbuf.ptr + got, rbuf.len - got);
                if (!ok(r) or r == 0) break :outer;
                got += r;
            }
            done += depth;
            if (nowMs() >= deadline) break :outer;
        }
    }

    const ms = nowMs() - t0;
    const rps = if (ms > 0) @divTrunc(@as(i64, @intCast(done)) * 1000, ms) else 0;
    std.debug.print("responses={d} in {d}ms => {d} req/s\n", .{ done, ms, rps });

    for (fds[0..n_up]) |fd| _ = linux.close(fd);
}
