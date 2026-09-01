//! Path and method matching for the seven endpoints.
//!
//! A pure function over the request line: no store, no account, no allocation. Which
//! makes the whole routing table testable as a table, which is what it is.
//!
//! Specification: the Surface table in `docs/02-api.md`.

const std = @import("std");
const server = @import("server");

const Method = server.head.Method;

pub const Route = union(enum) {
    /// `GET /healthz` — unauthenticated and unmetered, the only endpoint that is.
    healthz,
    /// `GET /v1/whoami`
    whoami,
    /// `GET /v1/entries?tag=…`
    list,
    /// `GET /v1/entries/{name}` — the name still percent-encoded.
    read: []const u8,
    /// `DELETE /v1/entries/{name}`
    remove: []const u8,

    /// The path exists; the method does not. Carries the `Allow` value `02-api.md`
    /// requires on a `405`.
    wrong_method: []const u8,

    /// No such path.
    ///
    /// Answered as `404 not_found` — the same code a missing entry gets, deliberately,
    /// so an unauthenticated prober cannot map which paths exist. In practice the two
    /// never collide, because authentication happens before routing: an unknown `/v1`
    /// path with a bad key is a `401` and never reaches here (`02-api.md`).
    unrouted,
};

/// Everything under `/v1/entries/` is a name, including further slashes — which is why
/// names may be namespaced at all.
const entries_prefix = "/v1/entries/";

/// `Allow` lists the methods that are **implemented**, not the ones `02-api.md` will
/// eventually document.
///
/// `PUT /v1/entries/{name}` and `POST /v1/entries` are the write path, and the write path
/// is the next slice — it needs credit accounting and idempotency, neither of which
/// exists yet. Routing them now would mean answering a documented endpoint with a `500`,
/// which tells a caller the server is broken rather than that the method is not there. A
/// `405` with an accurate `Allow` is true at this commit and stays true; these two
/// constants gain their methods when the handlers do.
const collection_allow = "GET";
const entry_allow = "GET, DELETE";

pub fn route(method: Method, path: []const u8) Route {
    if (std.mem.eql(u8, path, "/healthz")) {
        return if (method == .get) .healthz else .{ .wrong_method = "GET" };
    }
    if (std.mem.eql(u8, path, "/v1/whoami")) {
        return if (method == .get) .whoami else .{ .wrong_method = "GET" };
    }
    if (std.mem.eql(u8, path, "/v1/entries")) {
        return switch (method) {
            .get => .list,
            else => .{ .wrong_method = collection_allow },
        };
    }
    if (std.mem.startsWith(u8, path, entries_prefix)) {
        // May be empty — `/v1/entries/` addresses a zero-length name, which validation
        // rejects as `invalid_name`. Routing does not second-guess it, because the
        // difference between "no such path" and "unusable name" is the caller's to see.
        const name = path[entries_prefix.len..];
        return switch (method) {
            .get => .{ .read = name },
            .delete => .{ .remove = name },
            else => .{ .wrong_method = entry_allow },
        };
    }
    return .unrouted;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "every implemented endpoint routes" {
    try testing.expectEqual(Route.healthz, route(.get, "/healthz"));
    try testing.expectEqual(Route.whoami, route(.get, "/v1/whoami"));
    try testing.expectEqual(Route.list, route(.get, "/v1/entries"));

    try testing.expectEqualStrings("a", route(.get, "/v1/entries/a").read);
    try testing.expectEqualStrings("a", route(.delete, "/v1/entries/a").remove);
}

test "the write methods are a 405 with an Allow that does not mention them" {
    // Honest at this commit rather than aspirational: answering a documented endpoint
    // with a `500` would say the server is broken instead of that the method is absent.
    try testing.expectEqualStrings("GET", route(.post, "/v1/entries").wrong_method);
    try testing.expectEqualStrings("GET, DELETE", route(.put, "/v1/entries/a").wrong_method);

    // And the Allow values never advertise something unroutable.
    for ([_][]const u8{ "GET", "GET, DELETE" }) |allow| {
        var it = std.mem.splitSequence(u8, allow, ", ");
        while (it.next()) |m| try testing.expect(Method.fromToken(m) != .other);
    }
}

test "a name keeps its slashes, which is what namespacing means" {
    try testing.expectEqualStrings(
        "tenant/42/session-state",
        route(.get, "/v1/entries/tenant/42/session-state").read,
    );
    // And its percent-encoding: decoding happens after routing.
    try testing.expectEqualStrings("a%2Fb", route(.get, "/v1/entries/a%2Fb").read);
}

test "an empty name routes and is rejected later, not here" {
    // `/v1/entries/` is the entries path with nothing after it. Reporting `404` would
    // tell the caller the path is wrong when the name is.
    try testing.expectEqualStrings("", route(.get, "/v1/entries/").read);
    try testing.expectEqualStrings("", route(.delete, "/v1/entries/").remove);
}

test "a known path with an unsupported method carries its Allow" {
    try testing.expectEqualStrings("GET", route(.put, "/healthz").wrong_method);
    try testing.expectEqualStrings("GET", route(.delete, "/v1/whoami").wrong_method);
    try testing.expectEqualStrings("GET", route(.delete, "/v1/entries").wrong_method);
    // An unknown method token routes to the same place.
    try testing.expectEqualStrings("GET, DELETE", route(.other, "/v1/entries/a").wrong_method);
}

test "anything else is unrouted" {
    for ([_][]const u8{
        "/",
        "/v1",
        "/v1/",
        "/v2/entries",
        "/v1/entrie",
        "/v1/entriesx",
        "/healthzz",
        "/health",
        "/app/account",
        "/v1/whoami/extra",
        "/favicon.ico",
    }) |path| {
        try testing.expectEqual(Route.unrouted, route(.get, path));
    }
}

test "the entries collection and a named entry are different routes" {
    // The distinction is the trailing slash, and getting it wrong would make
    // `/v1/entries` a read of an empty name rather than a list.
    try testing.expectEqual(Route.list, route(.get, "/v1/entries"));
    try testing.expect(route(.get, "/v1/entries/") == .read);
}

test "routing ignores the query string, because the caller passes a path" {
    // `head.path()` has already split at `?`; this asserts the contract rather than
    // re-implementing it.
    try testing.expectEqual(Route.list, route(.get, "/v1/entries"));
    try testing.expectEqual(Route.unrouted, route(.get, "/v1/entries?tag=ci"));
}
