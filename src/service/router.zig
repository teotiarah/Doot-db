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
    /// `POST /v1/entries` — the server assigns the name.
    create,
    /// `GET /v1/entries/{name}` — the name still percent-encoded.
    read: []const u8,
    /// `PUT /v1/entries/{name}`
    write: []const u8,
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

/// The control plane's prefix (`06-auth.md`).
pub const control_prefix = "/app/";

/// Which plane a path belongs to, decided before any credential is looked at (D73).
///
/// The split has to come first because the two planes authenticate differently and there is
/// no credential to check until the plane is known: `/v1` reads `Authorization` and never a
/// cookie, `/app` reads the session cookie and never a bearer token. That asymmetry is what
/// removes CSRF from the data plane entirely, and it is enforced here by construction rather
/// than by each handler remembering.
///
/// Anything outside both prefixes is treated as the data plane, where `route` answers
/// `unrouted` and the request becomes a `404` — the same code a missing entry gets, so an
/// unauthenticated prober learns nothing (D52).
pub const Plane = enum { data, control };

pub fn plane(path: []const u8) Plane {
    // Exactly `/app` with nothing after it is not the control plane: there is no such
    // endpoint, and treating it as one would mean answering it with a control-plane error
    // shape rather than the 404 every other unknown path gets.
    if (std.mem.startsWith(u8, path, control_prefix)) return .control;
    return .data;
}

/// The control plane's surface (`06-auth.md`).
///
/// **Not public API and not versioned**, so this table may change freely — which is exactly
/// why it is a separate type from `Route` rather than more variants on it. A caller depends
/// on `/v1`; nothing outside our own dashboard depends on this.
pub const AppRoute = union(enum) {
    /// `POST /app/auth/signup` — email and password.
    signup,
    /// `POST /app/auth/verify` — the OTP.
    verify,
    /// `POST /app/auth/login`
    login,
    /// `POST /app/auth/logout`
    logout,
    // `GET /app/auth/github` and its callback are deliberately **absent** until the OAuth
    // exchange exists, for the same reason `/app/stream` is: a route that cannot complete
    // tells a client the path works and then fails in a way no error code describes
    // honestly. The variants stay declared so `needsSynchroniser` and the tests keep
    // covering them, and `routeApp` starts returning them in the commit that implements
    // the flow.
    github_start,
    github_callback,
    /// `POST /app/auth/password/reset` — request a reset code.
    password_reset,
    /// `POST /app/auth/password/confirm` — complete it.
    password_confirm,

    /// `GET /app/account` — state, credits, plan.
    account,
    /// `DELETE /app/account` — self-service deletion.
    ///
    /// `06-auth.md` specifies the whole deletion flow and its surface table omitted the
    /// route, which is a gap in the specification rather than a decision: a flow with no
    /// endpoint cannot be reached. The table has been corrected alongside this.
    account_delete,

    /// `GET /app/keys` · `POST /app/keys`
    keys,
    keys_create,
    /// `DELETE /app/keys/{id}` — the id still as text.
    key_revoke: []const u8,

    /// `GET /app/entries` · `GET /app/entries/{name}` — the read-only explorer.
    entries,
    entry: []const u8,

    // `GET /app/stream` is deliberately **absent** until the live feed exists.
    //
    // D68 keeps the SSE endpoint and its long-polling alternative in M2's scope, behind one
    // transport seam. A route that answers nothing useful is worse than no route: it tells a
    // client the feature is there and then fails in a way no error code describes honestly.
    // Until the seam lands, `/app/stream` is `unrouted` like any other unknown path.

    wrong_method: []const u8,
    unrouted,
};

const keys_prefix = control_prefix ++ "keys/";
const app_entries_prefix = control_prefix ++ "entries/";

/// Is this route one that changes state, and therefore one the synchroniser token must
/// cover?
///
/// A property of the route rather than of the method, because `06-auth.md` requires the
/// token "on state-changing routes" and a handler deciding for itself is a handler that can
/// forget. Login and signup are deliberately **not** included: a caller who has no session
/// yet has no synchroniser token to send, and requiring one would make the first request
/// impossible. They are covered by the per-address limiter instead (D74).
pub fn needsSynchroniser(r: AppRoute) bool {
    return switch (r) {
        .logout,
        .account_delete,
        .keys_create,
        .key_revoke,
        => true,

        // Every one of these is reachable *without* a session, so there is no synchroniser
        // token to send — requiring one would make the request impossible rather than safe.
        // `verify` and `password_confirm` belong here for a sharper reason than signup does:
        // the OTP *is* the credential, and the account is not yet `active`, so a session
        // could not authenticate it even if one existed. All of them are covered by the
        // per-address limiter instead (D74).
        .signup,
        .login,
        .verify,
        .password_confirm,
        .password_reset,
        .github_start,
        .github_callback,
        => false,

        // Nothing read-only needs it.
        .account,
        .keys,
        .entries,
        .entry,
        .wrong_method,
        .unrouted,
        => false,
    };
}

pub fn routeApp(method: Method, path: []const u8) AppRoute {
    // Authentication endpoints first: they are the only ones reachable without a session.
    if (std.mem.eql(u8, path, "/app/auth/signup")) {
        return if (method == .post) .signup else .{ .wrong_method = "POST" };
    }
    if (std.mem.eql(u8, path, "/app/auth/verify")) {
        return if (method == .post) .verify else .{ .wrong_method = "POST" };
    }
    if (std.mem.eql(u8, path, "/app/auth/login")) {
        return if (method == .post) .login else .{ .wrong_method = "POST" };
    }
    if (std.mem.eql(u8, path, "/app/auth/logout")) {
        return if (method == .post) .logout else .{ .wrong_method = "POST" };
    }
    if (std.mem.eql(u8, path, "/app/auth/password/reset")) {
        return if (method == .post) .password_reset else .{ .wrong_method = "POST" };
    }
    if (std.mem.eql(u8, path, "/app/auth/password/confirm")) {
        return if (method == .post) .password_confirm else .{ .wrong_method = "POST" };
    }

    if (std.mem.eql(u8, path, "/app/account")) {
        return switch (method) {
            .get => .account,
            .delete => .account_delete,
            else => .{ .wrong_method = "GET, DELETE" },
        };
    }
    if (std.mem.eql(u8, path, "/app/keys")) {
        return switch (method) {
            .get => .keys,
            .post => .keys_create,
            else => .{ .wrong_method = "GET, POST" },
        };
    }
    if (std.mem.startsWith(u8, path, keys_prefix)) {
        const id = path[keys_prefix.len..];
        // An empty id is `unrouted`, which is the **opposite** of how `/v1/entries/`
        // treats an empty name — deliberately, because the two are different kinds of
        // thing. A name is caller-supplied data, so an empty one is a caller mistake worth
        // reporting as `invalid_name`. A key id is an opaque handle *we* generated, so an
        // empty one cannot refer to anything and there is nothing to tell the caller
        // beyond "no such thing".
        if (id.len == 0) return .unrouted;
        return switch (method) {
            .delete => .{ .key_revoke = id },
            else => .{ .wrong_method = "DELETE" },
        };
    }
    if (std.mem.eql(u8, path, "/app/entries")) {
        return if (method == .get) .entries else .{ .wrong_method = "GET" };
    }
    if (std.mem.startsWith(u8, path, app_entries_prefix)) {
        const name = path[app_entries_prefix.len..];
        // Read-only, and that is a product boundary rather than an omission
        // (`00-vision.md`): a second write path would need its own validation, billing,
        // idempotency and audit story, and would diverge from `/v1` over time. So every
        // other method here is a `405`, not a `404`.
        return if (method == .get) .{ .entry = name } else .{ .wrong_method = "GET" };
    }
    return .unrouted;
}

/// `Allow` lists the methods that are implemented — which, as of the write path, is the
/// whole published surface.
const collection_allow = "GET, POST";
const entry_allow = "GET, PUT, DELETE";

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
            .post => .create,
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
            .put => .{ .write = name },
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

test "every endpoint in the surface table routes" {
    try testing.expectEqual(Route.healthz, route(.get, "/healthz"));
    try testing.expectEqual(Route.whoami, route(.get, "/v1/whoami"));
    try testing.expectEqual(Route.list, route(.get, "/v1/entries"));
    try testing.expectEqual(Route.create, route(.post, "/v1/entries"));

    try testing.expectEqualStrings("a", route(.get, "/v1/entries/a").read);
    try testing.expectEqualStrings("a", route(.put, "/v1/entries/a").write);
    try testing.expectEqualStrings("a", route(.delete, "/v1/entries/a").remove);
}

test "every method an Allow advertises is one that routes" {
    // The property that keeps `Allow` honest: it may not name a method the router would
    // answer with another `405`.
    inline for (.{
        .{ "/v1/entries", collection_allow },
        .{ "/v1/entries/a", entry_allow },
    }) |case| {
        var it = std.mem.splitSequence(u8, case[1], ", ");
        while (it.next()) |m| {
            const method = Method.fromToken(m);
            try testing.expect(method != .other);
            try testing.expect(route(method, case[0]) != .wrong_method);
        }
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
    try testing.expectEqualStrings("GET, POST", route(.delete, "/v1/entries").wrong_method);
    // An unknown method token routes to the same place.
    try testing.expectEqualStrings("GET, PUT, DELETE", route(.other, "/v1/entries/a").wrong_method);
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

// ---------------------------------------------------------------------------
// The control plane (D73)
// ---------------------------------------------------------------------------

test "the plane is decided by prefix, before any credential is read" {
    try testing.expectEqual(Plane.control, plane("/app/account"));
    try testing.expectEqual(Plane.control, plane("/app/auth/login"));
    try testing.expectEqual(Plane.control, plane("/app/"));

    try testing.expectEqual(Plane.data, plane("/v1/entries"));
    try testing.expectEqual(Plane.data, plane("/healthz"));
    try testing.expectEqual(Plane.data, plane("/"));
    // Exactly `/app` is not the control plane: there is no such endpoint, and treating it
    // as one would answer it in the control plane's error shape instead of the 404 every
    // other unknown path gets.
    try testing.expectEqual(Plane.data, plane("/app"));
    // Nor is a path that merely starts with the letters.
    try testing.expectEqual(Plane.data, plane("/application/x"));
}

test "every route in 06-auth.md's control-plane table exists" {
    try testing.expectEqual(AppRoute.signup, routeApp(.post, "/app/auth/signup"));
    try testing.expectEqual(AppRoute.verify, routeApp(.post, "/app/auth/verify"));
    try testing.expectEqual(AppRoute.login, routeApp(.post, "/app/auth/login"));
    try testing.expectEqual(AppRoute.logout, routeApp(.post, "/app/auth/logout"));
    try testing.expectEqual(AppRoute.password_reset, routeApp(.post, "/app/auth/password/reset"));
    try testing.expectEqual(AppRoute.password_confirm, routeApp(.post, "/app/auth/password/confirm"));
    try testing.expectEqual(AppRoute.account, routeApp(.get, "/app/account"));
    try testing.expectEqual(AppRoute.keys, routeApp(.get, "/app/keys"));
    try testing.expectEqual(AppRoute.keys_create, routeApp(.post, "/app/keys"));
    try testing.expectEqualStrings("key_0000003", routeApp(.delete, "/app/keys/key_0000003").key_revoke);
    try testing.expectEqual(AppRoute.entries, routeApp(.get, "/app/entries"));
    try testing.expectEqualStrings("ci/last-green", routeApp(.get, "/app/entries/ci/last-green").entry);
}

test "account deletion has a route, which the surface table had omitted" {
    // 06-auth.md specifies the whole deletion flow and listed no endpoint for it. A flow
    // with no route cannot be reached, so this is a gap being filled rather than a feature
    // being added.
    try testing.expectEqual(AppRoute.account_delete, routeApp(.delete, "/app/account"));
    try testing.expectEqualStrings("GET, DELETE", routeApp(.post, "/app/account").wrong_method);
}

test "the OAuth paths are unrouted until the exchange exists" {
    // Declared as variants, not yet reachable. When the flow lands, the callback must be
    // matched *before* the entry point -- `/app/auth/github` is a prefix of
    // `/app/auth/github/callback`, so matching the shorter one first makes the callback
    // unreachable and the whole flow fails at its last step.
    try testing.expectEqual(AppRoute.unrouted, routeApp(.get, "/app/auth/github"));
    try testing.expectEqual(AppRoute.unrouted, routeApp(.get, "/app/auth/github/callback"));
    try testing.expectEqual(AppRoute.unrouted, routeApp(.get, "/app/auth/githubx"));
}

test "the explorer is read-only, and says so with a 405 rather than a 404" {
    // A product boundary (00-vision.md), so the answer must be "that method is not
    // allowed here" and not "no such thing" -- the latter would read as a bug to anyone
    // building against it.
    try testing.expectEqualStrings("GET", routeApp(.put, "/app/entries/a").wrong_method);
    try testing.expectEqualStrings("GET", routeApp(.delete, "/app/entries/a").wrong_method);
    try testing.expectEqualStrings("GET", routeApp(.post, "/app/entries/a").wrong_method);
    try testing.expectEqualStrings("GET", routeApp(.post, "/app/entries").wrong_method);
}

test "an app name keeps its slashes, like a data-plane name" {
    try testing.expectEqualStrings(
        "tenant/42/session-state",
        routeApp(.get, "/app/entries/tenant/42/session-state").entry,
    );
    try testing.expectEqualStrings("a%2Fb", routeApp(.get, "/app/entries/a%2Fb").entry);
}

test "an auth endpoint refuses the wrong method with the right Allow" {
    try testing.expectEqualStrings("POST", routeApp(.get, "/app/auth/login").wrong_method);
    try testing.expectEqualStrings("POST", routeApp(.get, "/app/auth/signup").wrong_method);
    try testing.expectEqualStrings("DELETE", routeApp(.get, "/app/keys/key_1").wrong_method);
}

test "every Allow the control plane advertises is a method that routes" {
    // The same property the data plane asserts: `Allow` may not name a method that would
    // earn another 405.
    inline for (.{
        .{ "/app/auth/login", "POST" },
        .{ "/app/account", "GET, DELETE" },
        .{ "/app/keys", "GET, POST" },
        .{ "/app/keys/key_1", "DELETE" },
        .{ "/app/entries", "GET" },
        .{ "/app/entries/a", "GET" },
    }) |case| {
        var it = std.mem.splitSequence(u8, case[1], ", ");
        while (it.next()) |m| {
            const method = Method.fromToken(m);
            try testing.expect(method != .other);
            try testing.expect(routeApp(method, case[0]) != .wrong_method);
        }
    }
}

test "unknown control-plane paths are unrouted" {
    for ([_][]const u8{
        "/app/",
        "/app/nope",
        "/app/auth",
        "/app/auth/",
        "/app/auth/signupx",
        "/app/accountx",
        "/app/keys/",
        "/app/entriesx",
        "/app/streamx",
        // Absent until the live feed exists (D68).
        "/app/stream",
        "/app/account/extra",
    }) |path| {
        try testing.expectEqual(AppRoute.unrouted, routeApp(.get, path));
    }
}

test "an empty key id routes nowhere rather than to a revocation" {
    // `/app/keys/` with nothing after it would otherwise be a revocation of the empty id,
    // which is a request that cannot succeed and should not be dispatched.
    try testing.expectEqual(AppRoute.unrouted, routeApp(.delete, "/app/keys/"));
}

test "the synchroniser token covers exactly the state-changing routes" {
    // A property of the route, not of the method, so a handler cannot forget it.
    try testing.expect(needsSynchroniser(.logout));
    try testing.expect(needsSynchroniser(.account_delete));
    try testing.expect(needsSynchroniser(.keys_create));
    try testing.expect(needsSynchroniser(.{ .key_revoke = "key_1" }));

    // Not signup or login: a caller with no session has no token to send, so requiring one
    // would make the first request impossible. The per-address limiter covers them (D74).
    try testing.expect(!needsSynchroniser(.signup));
    try testing.expect(!needsSynchroniser(.login));
    try testing.expect(!needsSynchroniser(.password_reset));
    try testing.expect(!needsSynchroniser(.github_start));
    try testing.expect(!needsSynchroniser(.github_callback));
    // The OTP is the credential on these two, and the account is not yet active -- a session
    // could not authenticate it even if one existed.
    try testing.expect(!needsSynchroniser(.verify));
    try testing.expect(!needsSynchroniser(.password_confirm));

    // And nothing read-only needs it.
    try testing.expect(!needsSynchroniser(.account));
    try testing.expect(!needsSynchroniser(.keys));
    try testing.expect(!needsSynchroniser(.entries));
}

test "the two planes never answer for each other's paths" {
    // The separation 06-auth.md requires, asserted rather than assumed: a control-plane
    // path is not a data-plane route, and the reverse.
    try testing.expectEqual(Route.unrouted, route(.get, "/app/account"));
    try testing.expectEqual(Route.unrouted, route(.post, "/app/auth/login"));
    try testing.expectEqual(AppRoute.unrouted, routeApp(.get, "/v1/entries"));
    try testing.expectEqual(AppRoute.unrouted, routeApp(.get, "/healthz"));
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
