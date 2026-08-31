//! Doot's HTTP transport.
//!
//! Everything between a TCP connection and a request handler: the io_uring event
//! loop, HTTP/1.1 framing, pooled connection and body memory, and the response
//! writer. It knows nothing about entries, accounts or credits — routing and the
//! seven endpoints sit above it behind the `Handler` seam in `handler.zig`.
//!
//! No `std.Io`. The ring is driven directly, because on the pinned toolchain
//! `std.Io.Uring` stubs out its entire networking surface and `std.Io.Threaded`
//! wedges after `async_limit` keep-alive connections (D26, D27).
//!
//! Specification: `docs/05-architecture.md`. Decisions: `docs/07-decisions.md` D27
//! (drive the ring directly), D28 (pooled connection state, cost is pages touched),
//! D30 (a buffer handed to the ring belongs to the kernel until its completion).

const std = @import("std");

pub const config = @import("server/config.zig");
pub const net = @import("server/net.zig");
pub const head = @import("server/head.zig");
pub const response = @import("server/response.zig");
pub const conn = @import("server/conn.zig");
pub const handler = @import("server/handler.zig");
pub const loop = @import("server/loop.zig");

pub const Method = head.Method;
pub const Head = head.Head;
pub const Outbound = response.Outbound;
pub const Conn = conn.Conn;
pub const Request = conn.Request;
pub const Handler = handler.Handler;
pub const Incoming = handler.Incoming;
pub const Reply = handler.Reply;
pub const Loop = loop.Loop;
pub const Options = loop.Options;
pub const Stats = loop.Stats;

test {
    _ = config;
    _ = net;
    _ = head;
    _ = response;
    _ = conn;
    _ = handler;
    _ = loop;
}
