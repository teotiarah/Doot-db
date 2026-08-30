//! Spike B: TLS 1.3 server at the origin, from a vendored pure-Zig library
//! compiled into the same binary.
//!
//! D13 claims Cloudflare terminates TLS for clients but the edge->origin hop
//! must also be encrypted, and that a vendored source dependency satisfies the
//! single-binary constraint. This proves the handshake actually completes
//! against a mainstream TLS client, with a CA-signed chain, and optionally with
//! client-certificate verification — which is what Cloudflare Authenticated
//! Origin Pulls requires the origin to do.
//!
//! Throwaway. Deleted at M1.
//!
//! usage: tlsserver <port> <cert.crt> <key.key> [client_ca.crt]

const std = @import("std");
const tls = @import("tls");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len < 4) {
        std.debug.print("usage: tlsserver <port> <cert> <key> [client_ca]\n", .{});
        return error.BadUsage;
    }
    const port = try std.fmt.parseInt(u16, args[1], 10);
    const cert_path = args[2];
    const key_path = args[3];
    const client_ca_path: ?[]const u8 = if (args.len > 4) args[4] else null;

    const cwd = std.Io.Dir.cwd();

    var auth = try tls.config.CertKeyPair.fromFilePath(gpa, io, cwd, cert_path, key_path);
    defer auth.deinit(gpa);
    std.debug.print("loaded chain={s} key={s}\n", .{ cert_path, key_path });

    var client_root_ca: ?tls.config.cert.Bundle = null;
    defer if (client_root_ca) |*b| b.deinit(gpa);
    if (client_ca_path) |p| {
        client_root_ca = try tls.config.cert.fromFilePath(gpa, io, cwd, p);
        std.debug.print("client-cert verification REQUIRED, ca={s}\n", .{p});
    }

    const address = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    var server = try address.listen(io, .{ .mode = .stream, .reuse_address = true });
    defer server.deinit(io);

    const rng_impl: std.Random.IoSource = .{ .io = io };

    std.debug.print("tls listening on 127.0.0.1:{d}\n", .{port});

    var served: usize = 0;
    while (served < 8) : (served += 1) {
        const stream = try server.accept(io);
        defer stream.close(io);

        var opt: tls.config.Server = .{
            .auth = &auth,
            .now = std.Io.Clock.real.now(io),
            .rng = rng_impl.interface(),
        };
        if (client_root_ca) |bundle| {
            opt.client_auth = .{ .auth_type = .require, .root_ca = bundle };
        }

        var conn = tls.serverFromStream(io, stream, opt) catch |err| {
            std.debug.print("HANDSHAKE FAILED: {t}\n", .{err});
            continue;
        };

        std.debug.print("HANDSHAKE OK cipher={t}\n", .{@as(tls.config.CipherSuite, conn.cipher)});

        // Read the request head, then answer. Proves bidirectional encrypted
        // traffic, not just a completed handshake.
        var buf: [4096]u8 = undefined;
        const n = conn.read(&buf) catch 0;
        const first_line = std.mem.sliceTo(buf[0..n], '\r');
        std.debug.print("decrypted request: \"{s}\" ({d} bytes)\n", .{ first_line, n });

        const body = "doot tls spike ok\n";
        var head_buf: [128]u8 = undefined;
        const head = try std.fmt.bufPrint(
            &head_buf,
            "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: {d}\r\n\r\n",
            .{body.len},
        );
        try conn.writeAll(head);
        try conn.writeAll(body);
        try conn.close();
        std.debug.print("response sent and connection closed cleanly\n", .{});
    }
}
