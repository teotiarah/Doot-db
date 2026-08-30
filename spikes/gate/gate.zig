const std = @import("std");
const Io = std.Io;

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var ev: Io.Uring = undefined;
    Io.Uring.init(&ev, gpa, .{ .log2_ring_entries = 10 }) catch |err| {
        std.debug.print("io_uring init FAILED: {t}\n", .{err});
        return err;
    };
    defer ev.deinit();
    const io = ev.io();
    std.debug.print("io_uring_setup OK (1024 ring entries)\n", .{});

    // Prove the ring completes a real timer op, not just that setup succeeded.
    const t0 = Io.Timestamp.now(io, .awake);
    try io.sleep(.fromMilliseconds(50), .awake);
    const t1 = Io.Timestamp.now(io, .awake);
    std.debug.print("timer op through ring: {d} ms (asked 50)\n", .{t0.durationTo(t1).toMilliseconds()});

    // Prove concurrency: 1000 fibers each sleeping, all must finish ~concurrently.
    var group: Io.Group = .init;
    const t2 = Io.Timestamp.now(io, .awake);
    for (0..1000) |_| group.async(io, sleeper, .{io});
    try group.await(io);
    const t3 = Io.Timestamp.now(io, .awake);
    std.debug.print("1000 concurrent fibers x 50ms sleep: {d} ms total (serial would be 50000)\n", .{t2.durationTo(t3).toMilliseconds()});
}

fn sleeper(io: Io) Io.Cancelable!void {
    try io.sleep(.fromMilliseconds(50), .awake);
}
