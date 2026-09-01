//! Transport harness (M2 Pass 2, slice 1).
//!
//! Runs the real event loop behind a handler that answers a handful of fixed shapes,
//! so an external HTTP client can be pointed at it. `src/server/loop.zig`'s own tests
//! already drive the loop over a real socket with a client written for the purpose;
//! what this adds is a client we did not write.
//!
//! That distinction is the whole reason it exists. Our test client accepts our
//! responses because both sides came out of the same head. `curl` does not: it decides
//! for itself whether a response is well framed, whether a connection can be reused,
//! and whether `Expect: 100-continue` was honoured — and it stalls a full second when
//! it was not, which is a bug our own client would never notice.
//!
//! No storage, no accounts, no router. Those arrive in the next slice.
//!
//!   transport [listen-addr]        default 127.0.0.1:0
//!
//! Prints the bound address on stderr once listening, so a caller that asked for port
//! 0 can find out where to connect. Runs until killed.

const std = @import("std");
const server = @import("server");
const storage = @import("storage");

const Incoming = server.handler.Incoming;
const Reply = server.handler.Reply;

/// Answers the shapes `transport-check.sh` exercises.
const Fixture = struct {
    fn respond(_: *anyopaque, in: Incoming, out: *Reply) server.handler.Disposition {
        const path = in.path();

        if (std.mem.eql(u8, path, "/fixed")) {
            out.header("Content-Type", "text/plain");
            out.body = "ok\n";
        } else if (std.mem.eql(u8, path, "/echo")) {
            // The body is in the request slot, which outlives the write, so it goes
            // back without a copy.
            out.header("Content-Type", "application/octet-stream");
            out.body = in.body;
        } else if (std.mem.eql(u8, path, "/method")) {
            out.header("Content-Type", "text/plain");
            out.body = in.head.method_token;
        } else if (std.mem.eql(u8, path, "/query")) {
            out.header("Content-Type", "text/plain");
            out.body = in.query();
        } else if (std.mem.eql(u8, path, "/empty")) {
            out.body = &.{};
        } else if (std.mem.eql(u8, path, "/goodbye")) {
            out.header("Content-Type", "text/plain");
            out.body = "bye\n";
            out.close = true;
        } else if (std.mem.eql(u8, path, "/big")) {
            // Filled into the transport-supplied buffer, which is what a record read
            // will do in the next slice.
            const n = requested(in, out.out.len);
            for (out.out[0..n], 0..) |*b, i| b.* = @intCast('A' + (i % 26));
            out.header("Content-Type", "application/octet-stream");
            out.body = out.out[0..n];
        } else if (std.mem.eql(u8, path, "/missing")) {
            out.fail(.not_found);
        } else if (std.mem.eql(u8, path, "/limited")) {
            out.fail(.rate_limited);
            out.retry_after_s = 34;
        } else if (std.mem.eql(u8, path, "/created")) {
            out.ok(201, "Created");
            out.header("Location", "/v1/entries/01JBQ2K9XW4V7N8M3PZR6TYAC5");
        } else {
            out.fail(.not_found);
        }
        // Nothing here touches storage, so nothing here needs an I/O worker (D57). The
        // service harness is where deferred replies get exercised externally.
        return .complete;
    }

    /// `?n=` from the query, clamped to what the reply buffer can hold.
    fn requested(in: Incoming, limit: usize) usize {
        const q = in.query();
        const marker = "n=";
        const at = std.mem.indexOf(u8, q, marker) orelse return @min(limit, 200_000);
        const rest = q[at + marker.len ..];
        const end = std.mem.indexOfScalar(u8, rest, '&') orelse rest.len;
        const asked = std.fmt.parseInt(usize, rest[0..end], 10) catch return @min(limit, 200_000);
        return @min(asked, limit);
    }

    fn handler() server.Handler {
        // Stateless, so the context pointer is never read. A pointer to the enclosing
        // type keeps it non-null without inventing an instance.
        return .{ .ctx = @constCast(@ptrCast(&fixture_tag)), .respondFn = respond };
    }
};

var fixture_tag: u8 = 0;

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    var args = init.minimal.args.iterate();
    _ = args.next();
    const addr = args.next() orelse "127.0.0.1:0";

    var clock = storage.clock.Real{};

    const loop = server.Loop.init(gpa, .{
        .address = addr,
        .handler = Fixture.handler(),
        .clock = clock.clock(),
    }) catch |err| {
        std.debug.print("transport: cannot listen on {s}: {s}\n", .{ addr, @errorName(err) });
        return 1;
    };
    defer loop.deinit(gpa);

    // The port, because the caller may have asked for an ephemeral one. Printed before
    // the loop starts, so a script can wait for this line and know the listener is
    // already bound rather than racing it.
    std.debug.print("transport: listening 127.0.0.1:{d}\n", .{try loop.port()});

    try loop.run();
    return 0;
}
