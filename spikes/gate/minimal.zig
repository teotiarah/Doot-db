const std = @import("std");
pub fn main() !void {
    var ev: std.Io.Uring = undefined;
    try std.Io.Uring.init(&ev, std.heap.page_allocator, .{});
    defer ev.deinit();
    const io = ev.io();
    _ = io;
}
