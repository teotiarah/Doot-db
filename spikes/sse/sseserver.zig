//! Spike A server: SSE on the raw std.os.linux.IoUring loop.
//!
//! D18 makes the live dashboard a slice of the storage sequence stream over
//! SSE. Two things have to be true: our side must stream incrementally rather
//! than buffer, and many idle subscribers must be cheap. Both are measured here.
//!
//! The tick timer that Spike C needed for housekeeping is the same mechanism
//! that drives broadcasts, so SSE costs no extra machinery.
//!
//! Throwaway. Deleted at M1.
//!
//! usage: sseserver <port> [event_interval_ms] [heartbeat_ms]
//!
//! Heartbeat defaults to 15s: Cloudflare Free/Pro close an idle origin response
//! after 100s with a 524, so this is not a decoration (D31).

const std = @import("std");
const linux = std.os.linux;
const IoUring = linux.IoUring;

const max_fd = 65_536;
const Op = enum(u8) { accept = 1, recv = 2, send = 3, tick = 4 };

fn ud(op: Op, fd: i32) u64 {
    return (@as(u64, @intFromEnum(op)) << 32) | @as(u64, @as(u32, @bitCast(fd)));
}
/// Same, plus the frame slot a send borrows, so its completion can release it.
fn udSlot(op: Op, fd: i32, slot: u16) u64 {
    return ud(op, fd) | (@as(u64, slot) << 40);
}
fn udSlotOf(v: u64) u16 {
    return @truncate(v >> 40);
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
fn nowMs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(ts.nsec, 1_000_000);
}

const sse_headers =
    "HTTP/1.1 200 OK\r\n" ++
    "Content-Type: text/event-stream\r\n" ++
    // No caching anywhere, at any layer. A cached event stream is a broken one.
    "Cache-Control: no-cache, no-store, no-transform\r\n" ++
    // Nginx-family proxies buffer streamed responses unless told not to.
    // Harmless elsewhere, essential when it is respected.
    "X-Accel-Buffering: no\r\n" ++
    "Connection: keep-alive\r\n" ++
    "\r\n" ++
    // Comment line, flushed with the headers so the client's stream opens
    // immediately rather than on the first real event.
    ": stream open\n\n";

/// A subscriber. Deliberately tiny: everything an SSE connection needs is a
/// small per-connection send buffer, because event payloads are shared.
const Sub = struct {
    /// Small buffer for the request head only.
    head: [512]u8 = undefined,
    head_len: usize = 0,
    streaming: bool = false,
    /// Pending outbound frame, owned by the shared broadcast buffer.
    in_flight: bool = false,
};

var subs: [max_fd]?*Sub = @splat(null);
var live: i64 = 0;
var peak: i64 = 0;
var seq: u64 = 0;
var sent_events: u64 = 0;
var dropped: u64 = 0;

/// Broadcast frames are identical for every subscriber, so sharing one buffer
/// across all of them keeps per-subscriber memory flat. But io_uring reads a
/// send buffer *asynchronously*, so a single shared buffer that gets rewritten
/// on the next tick tears frames in flight — measured at 40k torn frames with
/// 2000 subscribers. Hence a pool of refcounted slots: a slot is only reused
/// once every send borrowing it has completed.
const frame_slots = 256;
const FrameSlot = struct {
    buf: [512]u8 = undefined,
    len: usize = 0,
    refs: u32 = 0,
};
var slots: [frame_slots]FrameSlot = @splat(.{});
var free_slots: [frame_slots]u16 = undefined;
var free_top: usize = 0;
var slot_exhausted: u64 = 0;

fn slotAcquire() ?u16 {
    if (free_top == 0) return null;
    free_top -= 1;
    return free_slots[free_top];
}
fn slotRelease(i: u16) void {
    free_slots[free_top] = i;
    free_top += 1;
}

pub fn main(init: std.process.Init.Minimal) !void {
    var args = init.args.iterate();
    _ = args.next();
    const port = try std.fmt.parseInt(u16, args.next() orelse "9600", 10);
    const event_ms = try std.fmt.parseInt(i64, args.next() orelse "250", 10);
    const heartbeat_ms = try std.fmt.parseInt(i64, args.next() orelse "15000", 10);

    const gpa = std.heap.page_allocator;

    for (0..frame_slots) |i| free_slots[i] = @intCast(frame_slots - 1 - i);
    free_top = frame_slots;

    var ring = try IoUring.init(4096, 0);
    defer ring.deinit();

    const lfd = try listenSocket(port);
    defer _ = linux.close(lfd);

    std.debug.print(
        "sse on 127.0.0.1:{d} event_every={d}ms heartbeat_every={d}ms baseline rss={d}KB\n",
        .{ port, event_ms, heartbeat_ms, rssKb() },
    );

    _ = try ring.accept_multishot(ud(.accept, lfd), lfd, null, null, 0);
    // 50ms tick: fine enough to drive events, coarse enough to be free.
    const tick: linux.kernel_timespec = .{ .sec = 0, .nsec = 50 * std.time.ns_per_ms };
    _ = try ring.timeout(ud(.tick, 0), &tick, 0, 0);
    _ = try ring.submit();

    var cqes: [512]linux.io_uring_cqe = undefined;
    var last_event = nowMs();
    var last_beat = nowMs();
    var last_report = nowMs();

    while (true) {
        const n = ring.copy_cqes(&cqes, 1) catch |err| switch (err) {
            error.SignalInterrupt => continue,
            else => return err,
        };

        for (cqes[0..n]) |cqe| {
            const fd = udFd(cqe.user_data);
            switch (@as(Op, @enumFromInt(udOp(cqe.user_data)))) {
                .accept => {
                    if (cqe.res >= 0 and cqe.res < max_fd) try onAccept(&ring, gpa, cqe.res);
                    if (cqe.flags & linux.IORING_CQE_F_MORE == 0) {
                        _ = try ring.accept_multishot(ud(.accept, fd), fd, null, null, 0);
                    }
                },
                .recv => {
                    if (cqe.res <= 0) closeSub(gpa, fd) else try onRecv(&ring, gpa, fd, @intCast(cqe.res));
                },
                .send => {
                    const idx = udSlotOf(cqe.user_data);
                    if (idx < frame_slots) {
                        const slot = &slots[idx];
                        if (slot.refs > 0) {
                            slot.refs -= 1;
                            if (slot.refs == 0) slotRelease(idx);
                        }
                    }
                    if (cqe.res < 0) {
                        closeSub(gpa, fd);
                    } else if (subs[@intCast(fd)]) |s| {
                        s.in_flight = false;
                    }
                },
                .tick => {
                    _ = try ring.timeout(ud(.tick, 0), &tick, 0, 0);
                },
            }
        }

        const t = nowMs();
        if (t - last_event >= event_ms) {
            last_event = t;
            seq += 1;
            // Shape mirrors the real change feed: sequence number plus a name.
            broadcast(
                &ring,
                "id: {d}\nevent: entry\ndata: {{\"seq\":{d},\"name\":\"spike/{d}\",\"op\":\"put\"}}\n\n",
                .{ seq, seq, seq },
            );
        }
        if (t - last_beat >= heartbeat_ms) {
            last_beat = t;
            // Comment-only frame: ignored by EventSource, but keeps
            // intermediaries from idling the connection out.
            broadcast(&ring, ": heartbeat {d}\n\n", .{t});
        }
        if (t - last_report >= 1000) {
            last_report = t;
            const rss = rssKb();
            const per: f64 = if (live > 0)
                @as(f64, @floatFromInt(rss)) / @as(f64, @floatFromInt(live))
            else
                0;
            std.debug.print(
                "subs={d} peak={d} seq={d} frames_sent={d} dropped={d} slot_exhausted={d} free_slots={d} rss={d}KB ({d:.2}KB/sub)\n",
                .{ @as(u64, @intCast(live)), @as(u64, @intCast(peak)), seq, sent_events, dropped, slot_exhausted, free_top, rss, per },
            );
        }
        _ = ring.submit() catch {};
    }
}

/// Formats one frame into a pooled slot and sends it to every subscriber.
/// The slot's refcount is the number of sends still borrowing it.
fn broadcast(ring: *IoUring, comptime fmt: []const u8, fmt_args: anytype) void {
    const idx = slotAcquire() orelse {
        slot_exhausted += 1;
        return;
    };
    const slot = &slots[idx];
    const body_slice = std.fmt.bufPrint(&slot.buf, fmt, fmt_args) catch {
        slotRelease(idx);
        return;
    };
    slot.len = body_slice.len;
    slot.refs = 0;

    for (subs, 0..) |maybe, i| {
        const s = maybe orelse continue;
        if (!s.streaming) continue;
        if (s.in_flight) {
            // Previous frame still unacknowledged: skip rather than queue
            // without bound. The feed is best-effort by design (D18).
            dropped += 1;
            continue;
        }
        const fd: i32 = @intCast(i);
        _ = ring.send(
            udSlot(.send, fd, idx),
            fd,
            slot.buf[0..slot.len],
            linux.MSG.NOSIGNAL,
        ) catch {
            dropped += 1;
            continue;
        };
        s.in_flight = true;
        slot.refs += 1;
        sent_events += 1;
    }

    // Nobody borrowed it (no subscribers, or all busy): reclaim immediately.
    if (slot.refs == 0) slotRelease(idx);
}

fn onAccept(ring: *IoUring, gpa: std.mem.Allocator, cfd: i32) !void {
    const s = gpa.create(Sub) catch {
        _ = linux.close(cfd);
        return;
    };
    s.* = .{};
    subs[@intCast(cfd)] = s;
    live += 1;
    if (live > peak) peak = live;

    const one: u32 = 1;
    _ = linux.setsockopt(cfd, linux.IPPROTO.TCP, linux.TCP.NODELAY, @ptrCast(&one), 4);

    _ = try ring.recv(ud(.recv, cfd), cfd, .{ .buffer = &s.head }, 0);
}

fn onRecv(ring: *IoUring, gpa: std.mem.Allocator, fd: i32, got: usize) !void {
    const s = subs[@intCast(fd)] orelse return;
    if (s.streaming) return; // subscribers do not talk after subscribing

    s.head_len += got;
    if (std.mem.indexOf(u8, s.head[0..s.head_len], "\r\n\r\n") == null) {
        if (s.head_len >= s.head.len) {
            closeSub(gpa, fd);
            return;
        }
        _ = try ring.recv(ud(.recv, fd), fd, .{ .buffer = s.head[s.head_len..] }, 0);
        return;
    }

    s.streaming = true;
    s.in_flight = true;
    // Headers go out immediately, before any event exists. If this were
    // withheld until the first event, every client would appear to hang.
    _ = try ring.send(ud(.send, fd), fd, sse_headers, linux.MSG.NOSIGNAL);
}

fn closeSub(gpa: std.mem.Allocator, fd: i32) void {
    if (fd < 0 or fd >= max_fd) return;
    if (subs[@intCast(fd)]) |s| {
        gpa.destroy(s);
        subs[@intCast(fd)] = null;
        live -= 1;
    }
    _ = linux.close(fd);
}

fn listenSocket(port: u16) !i32 {
    const rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM, 0);
    if (!ok(rc)) return error.SocketFailed;
    const fd: i32 = @intCast(rc);
    const one: u32 = 1;
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, @ptrCast(&one), 4);
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.REUSEPORT, @ptrCast(&one), 4);
    const addr: linux.sockaddr.in = .{
        .port = std.mem.nativeToBig(u16, port),
        .addr = std.mem.nativeToBig(u32, 0x7f00_0001),
    };
    if (!ok(linux.bind(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in)))) return error.BindFailed;
    if (!ok(linux.listen(fd, 8192))) return error.ListenFailed;
    return fd;
}

fn statmField(index: usize) u64 {
    var buf: [256]u8 = undefined;
    const rc = linux.open("/proc/self/statm", .{ .ACCMODE = .RDONLY }, 0);
    if (!ok(rc)) return 0;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    const nr = linux.read(fd, &buf, buf.len);
    if (!ok(nr)) return 0;
    var it = std.mem.tokenizeScalar(u8, buf[0..nr], ' ');
    var i: usize = 0;
    while (it.next()) |tok| : (i += 1) {
        if (i == index) return (std.fmt.parseInt(u64, std.mem.trim(u8, tok, " \n"), 10) catch return 0) * 4;
    }
    return 0;
}
fn rssKb() u64 {
    return statmField(1);
}
