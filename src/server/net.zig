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

    /// The bytes that identify a *client*, for rate-limiting purposes (D74).
    ///
    /// Written into `out`, which must be at least `client_key_bytes`. The result is the
    /// address family followed by the raw address, and is not human-readable — nothing
    /// needs it to be, because its only use is as a hash input.
    ///
    /// **The port is deliberately excluded.** A client's source port differs on every
    /// connection, so including it would give every connection a bucket of its own and
    /// the per-address limit would not exist at all. That is the kind of mistake that
    /// looks like working code, so it is stated here and asserted in a test.
    pub fn clientKey(a: Address, out: []u8) []const u8 {
        std.debug.assert(out.len >= client_key_bytes);
        out[0] = switch (a) {
            .in => 4,
            .in6 => 6,
        };
        return switch (a) {
            .in => |v4| blk: {
                const bytes = std.mem.asBytes(&v4.addr);
                @memcpy(out[1..][0..bytes.len], bytes);
                break :blk out[0 .. 1 + bytes.len];
            },
            .in6 => |v6| blk: {
                @memcpy(out[1..][0..16], &v6.addr);
                break :blk out[0..17];
            },
        };
    }
};

/// Longest `clientKey` output: a family byte plus a 16-byte IPv6 address.
pub const client_key_bytes: usize = 17;

/// The address at the far end of an accepted socket.
///
/// Read on demand rather than captured at accept, and D74's amendment explains why:
/// `accept_multishot` has nowhere to return one, so it would cost a syscall on every
/// connection and bytes in the `Conn` slab whose size D28 publishes — to serve a fallback
/// that the production shape never reaches, because behind Cloudflare the client address
/// arrives in a header.
pub fn peerName(fd: Fd) Error!Address {
    // Sized for the larger of the two, then discriminated on what the kernel filled in.
    var raw: linux.sockaddr.in6 = undefined;
    var len: linux.socklen_t = @sizeOf(linux.sockaddr.in6);
    const rc = linux.getpeername(fd, @ptrCast(&raw), &len);
    if (failed(rc)) return toError(rc);

    return switch (raw.family) {
        linux.AF.INET => .{ .in = @as(*const linux.sockaddr.in, @ptrCast(&raw)).* },
        linux.AF.INET6 => .{ .in6 = raw },
        else => error.AddressFamilyNotSupported,
    };
}

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
/// `SO_REUSEPORT` is set even though only one loop runs. D57 **deferred** the
/// one-ring-per-core model rather than adopting it, so the kernel has nothing to
/// distribute between today — but the option has to be set before `bind`, which is why it
/// lives here rather than in the loop, and setting it now is what keeps that model a
/// configuration change rather than a rewrite. It is inert with a single listener.
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


test "a client key excludes the port, which is the whole point of it" {
    // A client's source port differs on every connection. A key that included it would give
    // every connection a bucket of its own and the per-address rate limit would not exist —
    // a mistake that looks exactly like working code, so it is asserted rather than trusted.
    const a = try parseAddress("203.0.113.7:1024");
    const b = try parseAddress("203.0.113.7:52345");

    var ka: [client_key_bytes]u8 = undefined;
    var kb: [client_key_bytes]u8 = undefined;
    try testing.expectEqualSlices(u8, a.clientKey(&ka), b.clientKey(&kb));

    // And a different address is a different client.
    const c = try parseAddress("203.0.113.8:1024");
    var kc: [client_key_bytes]u8 = undefined;
    try testing.expect(!std.mem.eql(u8, a.clientKey(&ka), c.clientKey(&kc)));
}

test "the two address families cannot collide in a client key" {
    // The family byte leads, so an IPv4 address can never produce the same bytes as an
    // IPv6 one — including the v4-mapped forms, which share the trailing four octets.
    const v4 = try parseAddress("127.0.0.1:80");
    const v6 = parseAddress("[::ffff:127.0.0.1]:80") catch return;

    var k4: [client_key_bytes]u8 = undefined;
    var k6: [client_key_bytes]u8 = undefined;
    const s4 = v4.clientKey(&k4);
    const s6 = v6.clientKey(&k6);
    try testing.expect(!std.mem.eql(u8, s4, s6));
    try testing.expectEqual(@as(u8, 4), s4[0]);
    try testing.expectEqual(@as(u8, 6), s6[0]);
    try testing.expectEqual(@as(usize, 5), s4.len);
    try testing.expectEqual(@as(usize, 17), s6.len);
}

test "the peer of a connected socket is readable, and names the other end" {
    // The lazy read D74's amendment chose. Exercised against a real accepted socket rather
    // than asserted, because `getpeername` on the wrong descriptor is the kind of mistake a
    // unit test with a fake would not catch.
    //
    // `connect` and `accept` are done with raw syscalls here: this module deliberately holds
    // only the setup path, because once a descriptor exists every read and write on it goes
    // through io_uring instead.
    const listen_fd = try listen(try parseAddress("127.0.0.1:0"), 8);
    defer storage.os.close(listen_fd);
    const port = try boundPort(listen_fd);

    var buf: [32]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "127.0.0.1:{d}", .{port});
    const target = try parseAddress(text);

    const client: Fd = @intCast(linux.socket(linux.AF.INET, linux.SOCK.STREAM, 0));
    try testing.expect(client >= 0);
    defer storage.os.close(client);
    try testing.expect(!failed(linux.connect(client, target.sockaddr(), target.sockLen())));

    const accepted: Fd = @intCast(linux.accept4(listen_fd, null, null, 0));
    try testing.expect(accepted >= 0);
    defer storage.os.close(accepted);

    const peer = try peerName(accepted);
    try testing.expectEqual(linux.AF.INET, peer.family());
    // The peer of the accepted socket is the client's ephemeral port, not the listener's.
    try testing.expect(peer.port() != port);
    try testing.expect(peer.port() != 0);

    // And its client key matches the loopback address the connection came from.
    var k: [client_key_bytes]u8 = undefined;
    var expect_k: [client_key_bytes]u8 = undefined;
    const loopback = try parseAddress("127.0.0.1:0");
    try testing.expectEqualSlices(u8, loopback.clientKey(&expect_k), peer.clientKey(&k));
}

test "asking for the peer of something that is not a connected socket fails cleanly" {
    // A handler treats this as "no address" rather than as an error, so the failure has to
    // be an ordinary one and not a panic.
    const listen_fd = try listen(try parseAddress("127.0.0.1:0"), 8);
    defer storage.os.close(listen_fd);
    try testing.expectError(error.Unexpected, peerName(listen_fd));
}
