//! Thin socket syscall layer.
//!
//! The same shape and the same reasoning as `storage/os.zig`: straight to
//! `std.os.linux`, errno turned into Zig errors, no `std.Io` in the I/O path (D27).
//! Kept separate from `os.zig` because the storage engine is deliberately free of
//! networking and nothing in `src/storage/` should gain a reason to import this.
//!
//! Only the setup path lives here. Once a descriptor exists, every read and write on
//! it goes through io_uring rather than through this file.

const std = @import("std");
const linux = std.os.linux;
const storage = @import("storage");

pub const Fd = storage.os.Fd;

pub const Error = error{
    AccessDenied,
    AddressFamilyNotSupported,
    AddressInUse,
    AddressNotAvailable,
    InvalidAddress,
    ProcessFdQuotaExceeded,
    ProtocolNotSupported,
    SystemFdQuotaExceeded,
    SystemResources,
    Unexpected,
};

fn failed(rc: usize) bool {
    return @as(isize, @bitCast(rc)) < 0;
}

fn toError(rc: usize) Error {
    return switch (linux.errno(rc)) {
        .ACCES, .PERM => error.AccessDenied,
        .AFNOSUPPORT => error.AddressFamilyNotSupported,
        .ADDRINUSE => error.AddressInUse,
        .ADDRNOTAVAIL => error.AddressNotAvailable,
        .FAULT, .INVAL => error.InvalidAddress,
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        .PROTONOSUPPORT => error.ProtocolNotSupported,
        .NOMEM, .NOBUFS => error.SystemResources,
        else => error.Unexpected,
    };
}

/// A bindable socket address.
///
/// Owned here rather than taken from `std.Io.net`, because what `bind` needs is a
/// `linux.sockaddr` and the transport has no business holding an `Io`. The textual
/// parsing below does borrow `std.Io.net`'s literal parsers, which are pure functions
/// — the same distinction D29 relies on for tls.zig's `nonblock` API.
pub const Address = union(enum) {
    in: linux.sockaddr.in,
    in6: linux.sockaddr.in6,

    pub fn family(a: Address) u16 {
        return switch (a) {
            .in => linux.AF.INET,
            .in6 => linux.AF.INET6,
        };
    }

    pub fn port(a: Address) u16 {
        return switch (a) {
            .in => |v4| std.mem.bigToNative(u16, v4.port),
            .in6 => |v6| std.mem.bigToNative(u16, v6.port),
        };
    }

    pub fn sockLen(a: Address) linux.socklen_t {
        return switch (a) {
            .in => @sizeOf(linux.sockaddr.in),
            .in6 => @sizeOf(linux.sockaddr.in6),
        };
    }

    fn sockaddr(a: *const Address) *const linux.sockaddr {
        return switch (a.*) {
            .in => |*v4| @ptrCast(v4),
            .in6 => |*v6| @ptrCast(v6),
        };
    }
};

/// Parses `host:port`, accepting IPv4 (`0.0.0.0:8080`) and bracketed IPv6
/// (`[::]:8080`, `[::1]:8080`).
///
/// Brackets are mandatory for IPv6 and an unbracketed one is refused, because
/// `::1:9000` is genuinely ambiguous about where the address ends — it is a valid
/// IPv6 address on its own. `DOOT_LISTEN_ADDR` is operator-supplied configuration,
/// and configuration that parses two ways is configuration that is eventually wrong
/// in production, quietly.
pub fn parseAddress(text: []const u8) Error!Address {
    if (text.len == 0) return error.InvalidAddress;

    if (text[0] == '[') {
        const end = std.mem.indexOfScalar(u8, text, ']') orelse return error.InvalidAddress;
        if (end + 1 >= text.len or text[end + 1] != ':') return error.InvalidAddress;
        const host = text[1..end];
        const p = try parsePort(text[end + 2 ..]);
        const parsed = std.Io.net.IpAddress.parseIp6(host, p) catch return error.InvalidAddress;
        return .{ .in6 = .{
            .port = std.mem.nativeToBig(u16, p),
            .flowinfo = parsed.ip6.flow,
            .addr = parsed.ip6.bytes,
            .scope_id = 0,
        } };
    }

    const colon = std.mem.lastIndexOfScalar(u8, text, ':') orelse return error.InvalidAddress;
    const host = text[0..colon];
    if (host.len == 0) return error.InvalidAddress;
    // An unbracketed colon in the host means an IPv6 literal without its brackets.
    if (std.mem.indexOfScalar(u8, host, ':') != null) return error.InvalidAddress;

    const p = try parsePort(text[colon + 1 ..]);
    const parsed = std.Io.net.IpAddress.parseIp4(host, p) catch return error.InvalidAddress;
    return .{ .in = .{
        .port = std.mem.nativeToBig(u16, p),
        .addr = @bitCast(parsed.ip4.bytes),
    } };
}

fn parsePort(text: []const u8) Error!u16 {
    if (text.len == 0) return error.InvalidAddress;
    return std.fmt.parseInt(u16, text, 10) catch error.InvalidAddress;
}

/// Creates a bound, listening socket.
///
/// `SO_REUSEPORT` is set because it is the mechanism the process model depends on:
/// one ring and one accept socket per worker thread, with the kernel distributing
/// connections, so there is no shared accept lock and no thundering herd. It has to be
/// set before `bind`, which is why it lives here rather than in the loop.
pub fn listen(addr: Address, backlog: u31) Error!Fd {
    const rc = linux.socket(
        addr.family(),
        linux.SOCK.STREAM | linux.SOCK.CLOEXEC,
        linux.IPPROTO.TCP,
    );
    if (failed(rc)) return toError(rc);
    const fd: Fd = @intCast(rc);
    errdefer storage.os.close(fd);

    try setOption(fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, 1);
    try setOption(fd, linux.SOL.SOCKET, linux.SO.REUSEPORT, 1);

    const bind_rc = linux.bind(fd, addr.sockaddr(), addr.sockLen());
    if (failed(bind_rc)) return toError(bind_rc);

    const listen_rc = linux.listen(fd, backlog);
    if (failed(listen_rc)) return toError(listen_rc);

    return fd;
}

/// Disables Nagle.
///
/// Not a micro-optimisation: the Nagle / delayed-ACK interaction adds a silent 40 ms
/// to small responses, and small responses are essentially all Doot returns. Set per
/// accepted connection because the option does not inherit from the listener.
pub fn setNoDelay(fd: Fd) void {
    // Best effort by design. A connection that cannot take TCP_NODELAY is still a
    // usable connection, and failing the accept over it would be the worse trade.
    setOption(fd, linux.IPPROTO.TCP, linux.TCP.NODELAY, 1) catch {};
}

fn setOption(fd: Fd, level: i32, optname: u32, value: u32) Error!void {
    const rc = linux.setsockopt(fd, level, optname, @ptrCast(&value), @sizeOf(u32));
    if (failed(rc)) return toError(rc);
}

/// The port a listener actually bound to.
///
/// Exists for port 0. The transport harness binds an ephemeral port and then tells a
/// client where to connect, because a hardcoded port makes concurrent test runs
/// collide on a shared machine.
pub fn boundPort(fd: Fd) Error!u16 {
    // An in6 is the larger of the two layouts, so it is a safe landing area for
    // either family.
    var addr: linux.sockaddr.in6 = undefined;
    var len: linux.socklen_t = @sizeOf(linux.sockaddr.in6);
    const rc = linux.getsockname(fd, @ptrCast(&addr), &len);
    if (failed(rc)) return toError(rc);
    return switch (addr.family) {
        linux.AF.INET => blk: {
            const v4: *const linux.sockaddr.in = @ptrCast(&addr);
            break :blk std.mem.bigToNative(u16, v4.port);
        },
        linux.AF.INET6 => std.mem.bigToNative(u16, addr.port),
        else => error.AddressFamilyNotSupported,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "IPv4 host and port round-trip" {
    const addr = try parseAddress("127.0.0.1:8080");
    try testing.expectEqual(@as(u16, 8080), addr.port());
    try testing.expectEqual(@as(u16, linux.AF.INET), addr.family());
    try testing.expectEqual(@as(linux.socklen_t, 16), addr.sockLen());
    // Stored big-endian, in the order the bytes were written.
    try testing.expectEqual(@as(u32, @bitCast([4]u8{ 127, 0, 0, 1 })), addr.in.addr);
}

test "the wildcard address parses" {
    const addr = try parseAddress("0.0.0.0:80");
    try testing.expectEqual(@as(u16, 80), addr.port());
    try testing.expectEqual(@as(u32, 0), addr.in.addr);
}

test "bracketed IPv6 parses and unbracketed is refused" {
    const addr = try parseAddress("[::1]:9000");
    try testing.expectEqual(@as(u16, 9000), addr.port());
    try testing.expectEqual(@as(u16, linux.AF.INET6), addr.family());
    try testing.expectEqual(@as(u8, 1), addr.in6.addr[15]);

    const wildcard6 = try parseAddress("[::]:9000");
    try testing.expectEqual(@as(u16, 9000), wildcard6.port());
    try testing.expectEqual([16]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, wildcard6.in6.addr);

    // A valid IPv6 address in its own right, so it is refused rather than guessed at.
    try testing.expectError(error.InvalidAddress, parseAddress("::1:9000"));
}

test "malformed addresses are refused rather than defaulted" {
    for ([_][]const u8{
        "",
        "127.0.0.1",
        "127.0.0.1:",
        ":8080",
        "127.0.0.1:notaport",
        "127.0.0.1:99999",
        "not-an-ip:8080",
        "[::1]8080",
        "[::1:8080",
        "[::1]:",
        "[not-ip]:80",
        "[::1]:notaport",
    }) |bad| {
        try testing.expectError(error.InvalidAddress, parseAddress(bad));
    }
}

test "a listener binds, reports its ephemeral port, and closes" {
    const fd = try listen(try parseAddress("127.0.0.1:0"), 128);
    defer storage.os.close(fd);
    try testing.expect(try boundPort(fd) != 0);
}

test "two listeners share a port, which is what one ring per worker needs" {
    // SO_REUSEPORT has to be set before bind or the second bind fails, so this is
    // really asserting the ordering inside `listen`.
    const first = try listen(try parseAddress("127.0.0.1:0"), 128);
    defer storage.os.close(first);
    const port = try boundPort(first);

    var buf: [32]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "127.0.0.1:{d}", .{port});
    const second = try listen(try parseAddress(text), 128);
    defer storage.os.close(second);

    try testing.expectEqual(port, try boundPort(second));
}

test "an IPv6 listener binds on its own family" {
    const fd = listen(try parseAddress("[::1]:0"), 128) catch |err| switch (err) {
        // Some build environments have IPv6 compiled out entirely.
        error.AddressFamilyNotSupported, error.AddressNotAvailable => return,
        else => return err,
    };
    defer storage.os.close(fd);
    try testing.expect(try boundPort(fd) != 0);
}
