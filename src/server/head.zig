//! HTTP/1.1 request head parsing.
//!
//! A pure function over caller-supplied bytes, like everything in `src/api/`: no
//! allocation, no clock, no sockets. The head is the only part of a request the
//! transport interprets — the body is opaque bytes it moves and never reads (D4).
//!
//! The origin speaks **HTTP/1.1 only** and always has exactly one peer, Cloudflare
//! (`05-architecture.md`). That narrowness is why several things RFC 9112 permits are
//! refused here rather than supported: each one is a request-smuggling surface, and
//! none of them can be produced by the single client that exists.
//!
//! Specification: `docs/05-architecture.md` ("HTTP behaviour that actually matters")
//! and the error table in `docs/02-api.md`.

const std = @import("std");
const api = @import("api");
const storage = @import("storage");
const config = @import("config.zig");

const Code = api.errors.Code;

pub const Method = enum {
    get,
    put,
    post,
    delete,
    /// Anything else. Carried rather than rejected, because deciding between `405` and
    /// `404` needs the path, and the path is the router's business, not the parser's.
    other,

    pub fn fromToken(token: []const u8) Method {
        // Case-sensitive: RFC 9110 methods are case-sensitive tokens, and a lowercase
        // `get` is a broken client rather than a polite variant.
        if (std.mem.eql(u8, token, "GET")) return .get;
        if (std.mem.eql(u8, token, "PUT")) return .put;
        if (std.mem.eql(u8, token, "POST")) return .post;
        if (std.mem.eql(u8, token, "DELETE")) return .delete;
        return .other;
    }

    /// Whether this method carries a body, and therefore requires `Content-Length`.
    pub fn expectsBody(m: Method) bool {
        return switch (m) {
            .put, .post => true,
            .get, .delete, .other => false,
        };
    }
};

pub const Version = enum { http_1_0, http_1_1 };

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

/// A parsed request head. Every slice borrows the caller's buffer, which must stay
/// unmodified for as long as the head is used.
pub const Head = struct {
    method: Method = .other,
    /// The raw method token, for the `Allow` header on a `405` and for logging a
    /// method we do not implement.
    method_token: []const u8 = &.{},
    /// Origin-form request target, exactly as received: still percent-encoded, query
    /// string still attached. Decoding is `api.parse`'s job and happens after routing.
    target: []const u8 = &.{},
    version: Version = .http_1_1,

    headers: [config.max_headers]Header = undefined,
    header_count: u16 = 0,

    /// Bytes the head occupied, including the terminating empty line. The body, if
    /// any, begins here.
    head_len: usize = 0,

    /// Absent means no body was declared. `0` and absent are different: a `PUT`
    /// without the header is `411`, a `PUT` declaring `0` is a valid empty entry.
    content_length: ?u64 = null,
    expects_continue: bool = false,
    connection_close: bool = false,
    connection_keep_alive: bool = false,

    pub fn header(h: *const Head, name: []const u8) ?[]const u8 {
        for (h.headers[0..h.header_count]) |f| {
            if (std.ascii.eqlIgnoreCase(f.name, name)) return f.value;
        }
        return null;
    }

    /// The target up to `?`.
    pub fn path(h: *const Head) []const u8 {
        const q = std.mem.indexOfScalar(u8, h.target, '?') orelse return h.target;
        return h.target[0..q];
    }

    /// The target after `?`, empty when there is none.
    pub fn query(h: *const Head) []const u8 {
        const q = std.mem.indexOfScalar(u8, h.target, '?') orelse return &.{};
        return h.target[q + 1 ..];
    }

    pub fn bodyLen(h: *const Head) u64 {
        return h.content_length orelse 0;
    }

    /// Keep-alive is the default on 1.1 and must be asked for on 1.0.
    ///
    /// The origin never closes a connection the edge might still reuse, so this only
    /// ever answers "did the client ask us to close".
    pub fn keepAlive(h: *const Head) bool {
        if (h.connection_close) return false;
        return switch (h.version) {
            .http_1_1 => true,
            .http_1_0 => h.connection_keep_alive,
        };
    }
};

pub const Result = union(enum) {
    /// No empty line yet. Read more and call again.
    incomplete,
    complete: Head,
    /// Terminal. The caller answers with this code and closes, because a head it
    /// could not parse means it cannot know where the next request begins.
    invalid: Code,
};

/// Parses a request head from the front of `buf`.
///
/// `buf` may contain the head plus any amount of body; only the head is examined and
/// `head_len` reports where the body starts.
pub fn parse(buf: []const u8) Result {
    var h: Head = .{};

    var lines = LineIter{ .buf = buf };

    // ---- request line ----
    const request_line = switch (lines.next()) {
        .none => return .incomplete,
        .over_limit => return .{ .invalid = .headers_too_large },
        .line => |l| l,
    };
    // An empty first line is a stray CRLF left over from a previous request, which
    // RFC 9112 says to ignore. Treat it as malformed instead: the connection is
    // ours alone and a client emitting them is one we would rather see fail loudly.
    if (request_line.len == 0) return .{ .invalid = .invalid_request };

    if (!parseRequestLine(request_line, &h)) return .{ .invalid = .invalid_request };

    // ---- header block ----
    var seen_content_length = false;
    var seen_transfer_encoding = false;
    var seen_host = false;

    while (true) {
        const line = switch (lines.next()) {
            .none => return .incomplete,
            .over_limit => return .{ .invalid = .headers_too_large },
            .line => |l| l,
        };
        if (line.len == 0) break; // end of head

        // Obsolete line folding. Refused: it is a smuggling primitive, RFC 9112
        // deprecates it, and no client Doot will ever see emits it.
        if (line[0] == ' ' or line[0] == '\t') return .{ .invalid = .invalid_request };

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse
            return .{ .invalid = .invalid_request };
        const name = line[0..colon];
        if (name.len == 0) return .{ .invalid = .invalid_request };
        // Whitespace between the name and the colon is the classic desync trick, so
        // it is rejected rather than trimmed.
        if (name[name.len - 1] == ' ' or name[name.len - 1] == '\t')
            return .{ .invalid = .invalid_request };
        if (!isToken(name)) return .{ .invalid = .invalid_request };

        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");

        if (h.header_count == config.max_headers) return .{ .invalid = .headers_too_large };
        h.headers[h.header_count] = .{ .name = name, .value = value };
        h.header_count += 1;

        // ---- the ones the transport itself acts on ----
        if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            // A repeated Content-Length is refused even when the values agree.
            // Collapsing duplicates is permitted and is also how request smuggling
            // starts, and there is no legitimate client that sends two.
            if (seen_content_length) return .{ .invalid = .invalid_request };
            seen_content_length = true;
            h.content_length = std.fmt.parseInt(u64, value, 10) catch
                return .{ .invalid = .invalid_request };
        } else if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
            seen_transfer_encoding = true;
        } else if (std.ascii.eqlIgnoreCase(name, "host")) {
            if (seen_host) return .{ .invalid = .invalid_request };
            seen_host = true;
        } else if (std.ascii.eqlIgnoreCase(name, "expect")) {
            // Only `100-continue` is recognised. RFC 9110 says an unmeetable
            // expectation is `417`, but the catalogue has no `417` (D52) and the one
            // client that exists never sends another expectation, so an unknown value
            // is ignored: we simply do not send an interim response.
            if (std.ascii.eqlIgnoreCase(value, "100-continue")) h.expects_continue = true;
        } else if (std.ascii.eqlIgnoreCase(name, "connection")) {
            var it = std.mem.splitScalar(u8, value, ',');
            while (it.next()) |raw| {
                const token = std.mem.trim(u8, raw, " \t");
                if (std.ascii.eqlIgnoreCase(token, "close")) h.connection_close = true;
                if (std.ascii.eqlIgnoreCase(token, "keep-alive")) h.connection_keep_alive = true;
            }
        }
    }

    h.head_len = lines.pos;

    // ---- cross-header consistency ----

    // Both framings at once is unresolvable and is the canonical smuggling setup.
    if (seen_transfer_encoding and seen_content_length) return .{ .invalid = .invalid_request };

    // No chunked request bodies in v1. `Content-Length` is what lets an oversized
    // upload be refused before it is read and keeps buffer sizing static, so its
    // absence on a write is `411` whatever the reason — including a
    // `Transfer-Encoding` we do not implement.
    if (seen_transfer_encoding) return .{ .invalid = .length_required };

    // HTTP/1.1 requires exactly one Host. 1.0 predates it.
    if (h.version == .http_1_1 and !seen_host) return .{ .invalid = .invalid_request };

    if (h.method.expectsBody()) {
        if (h.content_length == null) return .{ .invalid = .length_required };
        // Refused from the declared length, before a single body byte is read.
        if (h.content_length.? > storage.config.max_body_bytes)
            return .{ .invalid = .body_too_large };
    } else if (h.content_length) |len| {
        // `Content-Length: 0` is common padding on a GET and is harmless. A real body
        // on a method that has no use for one would have to be drained to keep the
        // connection usable, and draining a body we will not read is exactly what
        // 05-architecture.md refuses to do.
        if (len > 0) return .{ .invalid = .invalid_request };
    }

    return .{ .complete = h };
}

fn parseRequestLine(line: []const u8, h: *Head) bool {
    const first_sp = std.mem.indexOfScalar(u8, line, ' ') orelse return false;
    const rest = line[first_sp + 1 ..];
    const second_sp = std.mem.indexOfScalar(u8, rest, ' ') orelse return false;

    const method_token = line[0..first_sp];
    const target = rest[0..second_sp];
    const version_token = rest[second_sp + 1 ..];

    // Exactly three tokens. A fourth space means something is wrong with the target,
    // and guessing which part is the path is how a parser ends up disagreeing with
    // the proxy in front of it.
    if (std.mem.indexOfScalar(u8, version_token, ' ') != null) return false;
    if (method_token.len == 0 or target.len == 0) return false;
    if (!isToken(method_token)) return false;

    // Origin-form only. Absolute-form is for forward proxies, and authority-form is
    // for CONNECT; Doot is neither, and accepting a second way to spell a target
    // means reconciling it with Host on every request.
    if (target[0] != '/') return false;
    // A target must be printable ASCII with no control bytes. Percent-decoding and
    // the name character set are validated later, by `api.parse`.
    for (target) |c| if (c < 0x21 or c > 0x7e) return false;

    h.method_token = method_token;
    h.method = Method.fromToken(method_token);
    h.target = target;

    if (std.mem.eql(u8, version_token, "HTTP/1.1")) {
        h.version = .http_1_1;
    } else if (std.mem.eql(u8, version_token, "HTTP/1.0")) {
        h.version = .http_1_0;
    } else {
        // Includes HTTP/2 and HTTP/3, which the origin never sees: the edge speaks
        // 1.1 to us and provides h2 and h3 to clients (`05-architecture.md`). RFC
        // 9110's answer is `505`, which the catalogue deliberately does not carry, so
        // an unsupported version is reported as the malformed request line it is.
        return false;
    }
    return true;
}

/// RFC 9110 `token`: the characters legal in a method or a header field name.
fn isToken(s: []const u8) bool {
    for (s) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9' => {},
        '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => {},
        else => return false,
    };
    return true;
}

/// Splits on `\n`, tolerating a missing `\r`, and stops at `max_head_bytes`.
///
/// RFC 9112 recommends accepting a bare LF, and Doot's callers are shell scripts —
/// a hand-rolled `printf 'GET / HTTP/1.1\n\n'` is a plausible first request rather
/// than an attack.
const LineIter = struct {
    buf: []const u8,
    pos: usize = 0,

    const Next = union(enum) {
        line: []const u8,
        /// Ran out of bytes mid-line.
        none,
        /// The head exceeded its ceiling without terminating.
        over_limit,
    };

    fn next(it: *LineIter) Next {
        if (it.pos >= it.buf.len) {
            // Nothing left, and no empty line seen, so the head is still arriving —
            // unless it has already outgrown what we will ever accept.
            return if (it.pos >= config.max_head_bytes) .over_limit else .none;
        }
        const limit = @min(it.buf.len, @as(usize, config.max_head_bytes));
        const nl = std.mem.indexOfScalarPos(u8, it.buf[0..limit], it.pos, '\n') orelse {
            return if (limit >= config.max_head_bytes) .over_limit else .none;
        };
        var line = it.buf[it.pos..nl];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        it.pos = nl + 1;
        return .{ .line = line };
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectComplete(raw: []const u8) Head {
    return switch (parse(raw)) {
        .complete => |h| h,
        .incomplete => @panic("expected complete, got incomplete"),
        .invalid => |c| {
            std.debug.print("expected complete, got invalid: {s}\n", .{c.slug()});
            @panic("expected complete");
        },
    };
}

fn expectInvalid(raw: []const u8, want: Code) !void {
    switch (parse(raw)) {
        .invalid => |got| try testing.expectEqual(want, got),
        .complete => {
            std.debug.print("expected {s}, parsed clean\n", .{want.slug()});
            return error.TestExpectedInvalid;
        },
        .incomplete => {
            std.debug.print("expected {s}, got incomplete\n", .{want.slug()});
            return error.TestExpectedInvalid;
        },
    }
}

test "a minimal GET parses" {
    const h = expectComplete("GET /healthz HTTP/1.1\r\nHost: doot.run\r\n\r\n");
    try testing.expectEqual(Method.get, h.method);
    try testing.expectEqualStrings("/healthz", h.target);
    try testing.expectEqual(Version.http_1_1, h.version);
    try testing.expectEqual(@as(u16, 1), h.header_count);
    try testing.expect(h.keepAlive());
    try testing.expectEqual(@as(u64, 0), h.bodyLen());
    try testing.expectEqual(@as(usize, 41), h.head_len);
}

test "head_len points exactly at the body" {
    const raw = "PUT /v1/entries/a HTTP/1.1\r\nHost: d\r\nContent-Length: 5\r\n\r\nhello";
    const h = expectComplete(raw);
    try testing.expectEqualStrings("hello", raw[h.head_len..]);
    try testing.expectEqual(@as(u64, 5), h.bodyLen());
}

test "headers are retrievable case-insensitively" {
    const h = expectComplete(
        "PUT /v1/entries/x HTTP/1.1\r\n" ++
            "Host: doot.run\r\n" ++
            "Authorization: Bearer doot_live_abc\r\n" ++
            "X-Doot-Tags: ci,main\r\n" ++
            "Content-Length: 0\r\n\r\n",
    );
    try testing.expectEqualStrings("Bearer doot_live_abc", h.header("authorization").?);
    try testing.expectEqualStrings("Bearer doot_live_abc", h.header("AUTHORIZATION").?);
    try testing.expectEqualStrings("ci,main", h.header("X-Doot-Tags").?);
    try testing.expect(h.header("X-Doot-TTL") == null);
}

test "values are trimmed of surrounding whitespace but not internally" {
    const h = expectComplete("GET / HTTP/1.1\r\nHost: d\r\nX-Doot-Tags:  \tci, main \t \r\n\r\n");
    try testing.expectEqualStrings("ci, main", h.header("x-doot-tags").?);
}

test "path and query split at the first question mark" {
    const h = expectComplete("GET /v1/entries?tag=ci&limit=10 HTTP/1.1\r\nHost: d\r\n\r\n");
    try testing.expectEqualStrings("/v1/entries", h.path());
    try testing.expectEqualStrings("tag=ci&limit=10", h.query());

    const none = expectComplete("GET /v1/whoami HTTP/1.1\r\nHost: d\r\n\r\n");
    try testing.expectEqualStrings("/v1/whoami", none.path());
    try testing.expectEqualStrings("", none.query());
}

test "a name may contain slashes and percent escapes, undecoded here" {
    const h = expectComplete("GET /v1/entries/tenant/42/a%2Fb HTTP/1.1\r\nHost: d\r\n\r\n");
    try testing.expectEqualStrings("/v1/entries/tenant/42/a%2Fb", h.target);
}

test "an incomplete head asks for more bytes rather than failing" {
    try testing.expectEqual(Result.incomplete, parse("GET / HTTP/1.1\r\n"));
    try testing.expectEqual(Result.incomplete, parse("GET / HTTP/1.1\r\nHost: d\r\n"));
    try testing.expectEqual(Result.incomplete, parse("GET / HTTP"));
    try testing.expectEqual(Result.incomplete, parse(""));
    // Terminator half-arrived.
    try testing.expectEqual(Result.incomplete, parse("GET / HTTP/1.1\r\nHost: d\r\n\r"));
}

test "a bare LF terminates lines, as RFC 9112 recommends accepting" {
    const h = expectComplete("GET /healthz HTTP/1.1\nHost: doot.run\n\n");
    try testing.expectEqual(Method.get, h.method);
    try testing.expectEqualStrings("/healthz", h.target);
    try testing.expectEqual(@as(usize, 38), h.head_len);
}

test "all four methods, and an unknown one is carried not rejected" {
    inline for (.{
        .{ "GET", Method.get },
        .{ "PUT", Method.put },
        .{ "POST", Method.post },
        .{ "DELETE", Method.delete },
    }) |case| {
        const raw = case[0] ++ " /v1/entries/x HTTP/1.1\r\nHost: d\r\nContent-Length: 0\r\n\r\n";
        try testing.expectEqual(case[1], expectComplete(raw).method);
    }

    // Routing decides between 404 and 405, so the parser must not pre-empt it.
    const h = expectComplete("PATCH /v1/entries/x HTTP/1.1\r\nHost: d\r\n\r\n");
    try testing.expectEqual(Method.other, h.method);
    try testing.expectEqualStrings("PATCH", h.method_token);

    // Lowercase is a broken client, not a variant spelling.
    try testing.expectEqual(Method.other, expectComplete("get / HTTP/1.1\r\nHost: d\r\n\r\n").method);
}

test "a write without Content-Length is 411" {
    try expectInvalid("PUT /v1/entries/x HTTP/1.1\r\nHost: d\r\n\r\n", .length_required);
    try expectInvalid("POST /v1/entries HTTP/1.1\r\nHost: d\r\n\r\n", .length_required);
}

test "chunked is 411 rather than a body we cannot bound" {
    try expectInvalid(
        "PUT /v1/entries/x HTTP/1.1\r\nHost: d\r\nTransfer-Encoding: chunked\r\n\r\n",
        .length_required,
    );
    // Even on a method that carries no body: we still could not find the next request.
    try expectInvalid(
        "GET /v1/entries/x HTTP/1.1\r\nHost: d\r\nTransfer-Encoding: chunked\r\n\r\n",
        .length_required,
    );
}

test "an oversized body is refused from Content-Length alone" {
    // 262,145 — one byte over. No body bytes appear in the buffer at all, which is
    // the point: 05-architecture.md refuses to drain an upload it intends to reject.
    try expectInvalid(
        "PUT /v1/entries/x HTTP/1.1\r\nHost: d\r\nContent-Length: 262145\r\n\r\n",
        .body_too_large,
    );
    // Exactly at the ceiling is accepted.
    const h = expectComplete("PUT /v1/entries/x HTTP/1.1\r\nHost: d\r\nContent-Length: 262144\r\n\r\n");
    try testing.expectEqual(@as(u64, 262_144), h.bodyLen());
}

test "Content-Length: 0 on a write is an empty entry, not a missing header" {
    const h = expectComplete("PUT /v1/entries/lock HTTP/1.1\r\nHost: d\r\nContent-Length: 0\r\n\r\n");
    try testing.expectEqual(@as(u64, 0), h.bodyLen());
    try testing.expect(h.content_length != null);
}

test "Content-Length: 0 is tolerated on a GET but a real body is not" {
    _ = expectComplete("GET /v1/whoami HTTP/1.1\r\nHost: d\r\nContent-Length: 0\r\n\r\n");
    try expectInvalid(
        "GET /v1/whoami HTTP/1.1\r\nHost: d\r\nContent-Length: 7\r\n\r\npayload",
        .invalid_request,
    );
}

test "the smuggling shapes are all refused" {
    // Both framings at once.
    try expectInvalid(
        "PUT /x HTTP/1.1\r\nHost: d\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\n",
        .invalid_request,
    );
    // Duplicate Content-Length, even in agreement.
    try expectInvalid(
        "PUT /x HTTP/1.1\r\nHost: d\r\nContent-Length: 5\r\nContent-Length: 5\r\n\r\nhello",
        .invalid_request,
    );
    // Space before the colon.
    try expectInvalid("GET / HTTP/1.1\r\nHost : d\r\n\r\n", .invalid_request);
    // Obsolete line folding.
    try expectInvalid("GET / HTTP/1.1\r\nHost: d\r\nX-A: one\r\n  two\r\n\r\n", .invalid_request);
    // Duplicate Host.
    try expectInvalid("GET / HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n", .invalid_request);
    // Non-numeric and signed lengths.
    try expectInvalid("PUT /x HTTP/1.1\r\nHost: d\r\nContent-Length: abc\r\n\r\n", .invalid_request);
    try expectInvalid("PUT /x HTTP/1.1\r\nHost: d\r\nContent-Length: -1\r\n\r\n", .invalid_request);
    try expectInvalid("PUT /x HTTP/1.1\r\nHost: d\r\nContent-Length: 1 5\r\n\r\n", .invalid_request);
}

test "malformed request lines are refused" {
    for ([_][]const u8{
        "GET\r\nHost: d\r\n\r\n", // one token
        "GET /\r\nHost: d\r\n\r\n", // two tokens
        "GET / HTTP/1.1 extra\r\nHost: d\r\n\r\n", // four tokens
        " / HTTP/1.1\r\nHost: d\r\n\r\n", // no method
        "GET  HTTP/1.1\r\nHost: d\r\n\r\n", // empty target
        "GET / HTTP/0.9\r\nHost: d\r\n\r\n", // unsupported version
        "GET / HTTP/2.0\r\nHost: d\r\n\r\n", // the edge never sends this
        "GET / HTTP/1.2\r\nHost: d\r\n\r\n",
        "GET / http/1.1\r\nHost: d\r\n\r\n", // version is case-sensitive
        "GET http://doot.run/x HTTP/1.1\r\nHost: d\r\n\r\n", // absolute-form
        "GET doot.run:443 HTTP/1.1\r\nHost: d\r\n\r\n", // authority-form
        "GE(T / HTTP/1.1\r\nHost: d\r\n\r\n", // illegal token byte in method
        "\r\nGET / HTTP/1.1\r\nHost: d\r\n\r\n", // leading empty line
        "GET /a b HTTP/1.1\r\nHost: d\r\n\r\n", // space inside the target
    }) |bad| {
        try expectInvalid(bad, .invalid_request);
    }
}

test "a header block with no name is refused" {
    try expectInvalid("GET / HTTP/1.1\r\nHost: d\r\n: value\r\n\r\n", .invalid_request);
    try expectInvalid("GET / HTTP/1.1\r\nHost: d\r\nnocolon\r\n\r\n", .invalid_request);
}

test "HTTP/1.1 requires Host and HTTP/1.0 does not" {
    try expectInvalid("GET / HTTP/1.1\r\n\r\n", .invalid_request);
    const h = expectComplete("GET / HTTP/1.0\r\n\r\n");
    try testing.expectEqual(Version.http_1_0, h.version);
}

test "keep-alive defaults by version and Connection overrides it" {
    try testing.expect(expectComplete("GET / HTTP/1.1\r\nHost: d\r\n\r\n").keepAlive());
    try testing.expect(!expectComplete(
        "GET / HTTP/1.1\r\nHost: d\r\nConnection: close\r\n\r\n",
    ).keepAlive());

    try testing.expect(!expectComplete("GET / HTTP/1.0\r\n\r\n").keepAlive());
    try testing.expect(expectComplete(
        "GET / HTTP/1.0\r\nConnection: keep-alive\r\n\r\n",
    ).keepAlive());

    // A list, case-insensitive, as RFC 9110 defines the field.
    try testing.expect(!expectComplete(
        "GET / HTTP/1.1\r\nHost: d\r\nConnection: TE, Close\r\n\r\n",
    ).keepAlive());
}

test "Expect: 100-continue is recognised and other expectations are ignored" {
    try testing.expect(expectComplete(
        "PUT /x HTTP/1.1\r\nHost: d\r\nContent-Length: 3\r\nExpect: 100-continue\r\n\r\n",
    ).expects_continue);
    // Case-insensitive value.
    try testing.expect(expectComplete(
        "PUT /x HTTP/1.1\r\nHost: d\r\nContent-Length: 3\r\nExpect: 100-Continue\r\n\r\n",
    ).expects_continue);
    // Unknown expectation: no interim response, but not an error either.
    try testing.expect(!expectComplete(
        "PUT /x HTTP/1.1\r\nHost: d\r\nContent-Length: 3\r\nExpect: something-else\r\n\r\n",
    ).expects_continue);
}

test "too many headers is 431, counted separately from the byte ceiling" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try buf.appendSlice(testing.allocator, "GET / HTTP/1.1\r\nHost: d\r\n");
    // One past the limit, counting Host.
    var line: [32]u8 = undefined;
    for (0..config.max_headers) |i| {
        try buf.appendSlice(testing.allocator, try std.fmt.bufPrint(&line, "X-{d}: v\r\n", .{i}));
    }
    try buf.appendSlice(testing.allocator, "\r\n");
    try testing.expect(buf.items.len < config.max_head_bytes);
    try expectInvalid(buf.items, .headers_too_large);
}

test "a head that outgrows its ceiling is 431 rather than incomplete forever" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try buf.appendSlice(testing.allocator, "GET / HTTP/1.1\r\nHost: d\r\n");
    // One enormous header value, so the header *count* stays legal.
    try buf.appendSlice(testing.allocator, "X-Big: ");
    try buf.appendNTimes(testing.allocator, 'a', config.max_head_bytes);
    try buf.appendSlice(testing.allocator, "\r\n\r\n");
    try expectInvalid(buf.items, .headers_too_large);
}

test "exactly at the byte ceiling still parses" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const prefix = "GET / HTTP/1.1\r\nHost: d\r\nX-Pad: ";
    const suffix = "\r\n\r\n";
    try buf.appendSlice(testing.allocator, prefix);
    try buf.appendNTimes(testing.allocator, 'a', config.max_head_bytes - prefix.len - suffix.len);
    try buf.appendSlice(testing.allocator, suffix);
    try testing.expectEqual(@as(usize, config.max_head_bytes), buf.items.len);

    const h = expectComplete(buf.items);
    try testing.expectEqual(@as(usize, config.max_head_bytes), h.head_len);
}

test "pipelined requests parse one at a time, leaving the remainder" {
    const raw =
        "GET /a HTTP/1.1\r\nHost: d\r\n\r\n" ++
        "GET /b HTTP/1.1\r\nHost: d\r\n\r\n";
    const first = expectComplete(raw);
    try testing.expectEqualStrings("/a", first.target);

    const second = expectComplete(raw[first.head_len..]);
    try testing.expectEqualStrings("/b", second.target);
    try testing.expectEqual(raw.len, first.head_len + second.head_len);
}

test "a body is never mistaken for the next request" {
    const raw = "PUT /a HTTP/1.1\r\nHost: d\r\nContent-Length: 30\r\n\r\n" ++
        "GET /not-a-request HTTP/1.1\r\n\r\n";
    const h = expectComplete(raw);
    try testing.expectEqual(@as(u64, 30), h.bodyLen());
    try testing.expectEqualStrings("GET /not-a-request HTTP/1.1\r\n\r\n", raw[h.head_len..]);
}

test "the header array cannot be overrun by a head that fits the byte ceiling" {
    // Guards the bound directly: `max_headers` slots exist, and the parser must stop
    // rather than write past them.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try buf.appendSlice(testing.allocator, "GET / HTTP/1.1\r\nHost: d\r\n");
    var line: [32]u8 = undefined;
    for (0..config.max_headers * 4) |i| {
        try buf.appendSlice(testing.allocator, try std.fmt.bufPrint(&line, "H{d}: v\r\n", .{i}));
    }
    try buf.appendSlice(testing.allocator, "\r\n");
    switch (parse(buf.items)) {
        .invalid => |c| try testing.expectEqual(Code.headers_too_large, c),
        else => return error.TestExpectedInvalid,
    }
}
