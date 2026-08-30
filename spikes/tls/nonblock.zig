//! Spike B, part 2: TLS 1.3 termination driven entirely over buffers, on top of
//! a raw std.os.linux.IoUring loop.
//!
//! This is the combination the architecture actually needs. Spike C established
//! that std.Io has no usable networking in Zig 0.16.0, so the server must drive
//! io_uring itself; this shows a vendored TLS library can sit on top of that,
//! because its nonblock API is a pure buffer transformation with no I/O of its
//! own.
//!
//! Throwaway. Deleted at M1.
//!
//! usage: nonblock <port> <cert.crt> <key.key>

const std = @import("std");
const tls = @import("tls");
const linux = std.os.linux;
const IoUring = linux.IoUring;

const max_fd = 4096;
const Op = enum(u8) { accept = 1, recv = 2, send = 3, tick = 4 };

fn ud(op: Op, fd: i32) u64 {
    return (@as(u64, @intFromEnum(op)) << 32) | @as(u64, @as(u32, @bitCast(fd)));
}
fn udOp(v: u64) u8 {
    return @intCast(v >> 32);
}
fn udFd(v: u64) i32 {
    return @bitCast(@as(u32, @truncate(v)));
}
fn ok(rc: usize) bool {
    return @as(isize, @bitCast(rc)) >= 0;
}

const body = "doot tls-on-io_uring ok\n";

const Conn = struct {
    hs: tls.nonblock.Server,
    conn: ?tls.nonblock.Connection = null,
    /// Ciphertext accumulated from the peer but not yet consumed.
    recv: []u8,
    recv_len: usize = 0,
    /// Scratch for ciphertext we are sending.
    send: []u8,
    handshake_logged: bool = false,
};

var conns: [max_fd]?*Conn = @splat(null);
var completed: usize = 0;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 4) return error.BadUsage;

    const port = try std.fmt.parseInt(u16, args[1], 10);
    const cwd = std.Io.Dir.cwd();

    var auth = try tls.config.CertKeyPair.fromFilePath(gpa, io, cwd, args[2], args[3]);
    defer auth.deinit(gpa);

    const rng_impl: std.Random.IoSource = .{ .io = io };
    const opt: tls.config.Server = .{
        .auth = &auth,
        .now = std.Io.Clock.real.now(io),
        .rng = rng_impl.interface(),
    };

    var ring = try IoUring.init(256, 0);
    defer ring.deinit();

    const lfd = try listenSocket(port);
    defer _ = linux.close(lfd);

    std.debug.print("tls-on-io_uring listening on 127.0.0.1:{d}\n", .{port});

    _ = try ring.accept_multishot(ud(.accept, lfd), lfd, null, null, 0);
    const tick: linux.kernel_timespec = .{ .sec = 1, .nsec = 0 };
    _ = try ring.timeout(ud(.tick, 0), &tick, 0, 0);
    _ = try ring.submit();

    var cqes: [64]linux.io_uring_cqe = undefined;
    while (completed < 4) {
        const n = ring.copy_cqes(&cqes, 1) catch |err| switch (err) {
            error.SignalInterrupt => continue,
            else => return err,
        };
        for (cqes[0..n]) |cqe| {
            const fd = udFd(cqe.user_data);
            switch (@as(Op, @enumFromInt(udOp(cqe.user_data)))) {
                .accept => {
                    if (cqe.res >= 0 and cqe.res < max_fd) try onAccept(&ring, gpa, cqe.res, opt);
                    if (cqe.flags & linux.IORING_CQE_F_MORE == 0) {
                        _ = try ring.accept_multishot(ud(.accept, fd), fd, null, null, 0);
                    }
                },
                .recv => {
                    if (cqe.res <= 0) closeConn(gpa, fd) else try onRecv(&ring, gpa, fd, @intCast(cqe.res));
                },
                .send => {
                    if (cqe.res < 0) {
                        closeConn(gpa, fd);
                    } else if (conns[@intCast(fd)]) |c| {
                        _ = try ring.recv(ud(.recv, fd), fd, .{ .buffer = c.recv[c.recv_len..] }, 0);
                    }
                },
                .tick => _ = try ring.timeout(ud(.tick, 0), &tick, 0, 0),
            }
        }
        _ = try ring.submit();
    }
    std.debug.print("completed {d} TLS sessions over io_uring\n", .{completed});
}

fn onAccept(ring: *IoUring, gpa: std.mem.Allocator, cfd: i32, opt: tls.config.Server) !void {
    const c = try gpa.create(Conn);
    c.* = .{
        .hs = tls.nonblock.Server.init(opt),
        .recv = try gpa.alloc(u8, tls.input_buffer_len),
        .send = try gpa.alloc(u8, tls.output_buffer_len),
    };
    conns[@intCast(cfd)] = c;
    _ = try ring.recv(ud(.recv, cfd), cfd, .{ .buffer = c.recv }, 0);
}

fn onRecv(ring: *IoUring, gpa: std.mem.Allocator, fd: i32, got: usize) !void {
    const c = conns[@intCast(fd)] orelse return;
    c.recv_len += got;

    if (!c.hs.done()) {
        // Handshake phase: hand the library whatever ciphertext we have and it
        // tells us how much it consumed and what to send back. No I/O inside.
        const r = c.hs.run(c.recv[0..c.recv_len], c.send) catch |err| {
            std.debug.print("HANDSHAKE FAILED: {t}\n", .{err});
            closeConn(gpa, fd);
            return;
        };
        consume(c, r.recv_pos);

        if (c.hs.done() and !c.handshake_logged) {
            c.handshake_logged = true;
            c.conn = tls.nonblock.Connection.init(c.hs.cipher().?);
            std.debug.print("HANDSHAKE OK over io_uring (no std.Io networking)\n", .{});
        }
        if (r.send.len > 0) {
            _ = try ring.send(ud(.send, fd), fd, r.send, linux.MSG.NOSIGNAL);
            return;
        }
        _ = try ring.recv(ud(.recv, fd), fd, .{ .buffer = c.recv[c.recv_len..] }, 0);
        return;
    }

    // Application phase: decrypt, and once a request head has arrived, reply.
    var conn = &c.conn.?;
    var clear: [8192]u8 = undefined;
    const d = conn.decrypt(c.recv[0..c.recv_len], &clear) catch |err| {
        std.debug.print("DECRYPT FAILED: {t}\n", .{err});
        closeConn(gpa, fd);
        return;
    };
    consume(c, d.ciphertext_pos);

    if (d.cleartext.len > 0) {
        const line = std.mem.sliceTo(d.cleartext, '\r');
        std.debug.print("decrypted over io_uring: \"{s}\"\n", .{line});
    }

    if (std.mem.indexOf(u8, d.cleartext, "\r\n\r\n") != null) {
        var head_buf: [128]u8 = undefined;
        const head = try std.fmt.bufPrint(
            &head_buf,
            "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: {d}\r\n\r\n",
            .{body.len},
        );
        var plain_buf: [512]u8 = undefined;
        @memcpy(plain_buf[0..head.len], head);
        @memcpy(plain_buf[head.len..][0..body.len], body);
        const plain = plain_buf[0 .. head.len + body.len];

        const e = try conn.encrypt(plain, c.send);
        completed += 1;
        _ = try ring.send(ud(.send, fd), fd, e.ciphertext, linux.MSG.NOSIGNAL);
        return;
    }
    _ = try ring.recv(ud(.recv, fd), fd, .{ .buffer = c.recv[c.recv_len..] }, 0);
}

fn consume(c: *Conn, n: usize) void {
    if (n == 0) return;
    const left = c.recv_len - n;
    if (left > 0) std.mem.copyForwards(u8, c.recv[0..left], c.recv[n..c.recv_len]);
    c.recv_len = left;
}

fn closeConn(gpa: std.mem.Allocator, fd: i32) void {
    if (fd < 0 or fd >= max_fd) return;
    if (conns[@intCast(fd)]) |c| {
        gpa.free(c.recv);
        gpa.free(c.send);
        gpa.destroy(c);
        conns[@intCast(fd)] = null;
    }
    _ = linux.close(fd);
}

fn listenSocket(port: u16) !i32 {
    const rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM, 0);
    if (!ok(rc)) return error.SocketFailed;
    const fd: i32 = @intCast(rc);
    const one: u32 = 1;
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, @ptrCast(&one), 4);
    const addr: linux.sockaddr.in = .{
        .port = std.mem.nativeToBig(u16, port),
        .addr = std.mem.nativeToBig(u32, 0x7f00_0001),
    };
    if (!ok(linux.bind(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in)))) return error.BindFailed;
    if (!ok(linux.listen(fd, 128))) return error.ListenFailed;
    return fd;
}
