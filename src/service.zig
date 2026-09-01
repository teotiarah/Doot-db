//! Doot's data plane.
//!
//! The composition layer, and the only place that imports `storage`, `control`, `api` and
//! `server` together (D58). It is what knows both what an entry is and what an HTTP path
//! is; nothing below it may know both.
//!
//! **The division of labour is the important part.** Everything memory-only happens on
//! the event loop — routing, authenticating a key, taking a rate-limit token, decoding a
//! name, validating a cursor. Everything that can touch a disk is handed to an I/O worker
//! (D57). So a request is fully validated and fully authorised before a worker sees it,
//! and the worker does exactly one storage call.
//!
//! Validation runs in the order `03-data-model.md` gives, which is cheapest-rejection
//! first: credentials, then the rate limit, then the request's own fields. That ordering
//! is why an unknown `/v1` path with a bad key is a `401` and never reveals whether the
//! path existed.
//!
//! Specification: `docs/02-api.md`. Decisions: D6 (pooled rate limit), D46 (cursors),
//! D55 (`Date`), D56 (plan limits), D57 (storage off the loop), D58 (this module),
//! D59 (identifier format).

const std = @import("std");
const storage = @import("storage");
const control = @import("control");
const api = @import("api");
const server = @import("server");

pub const router = @import("service/router.zig");
pub const query = @import("service/query.zig");
pub const json = @import("service/json.zig");
pub const ids = @import("service/ids.zig");

const Incoming = server.handler.Incoming;
const Reply = server.handler.Reply;
const Disposition = server.handler.Disposition;
const Code = api.errors.Code;

pub const Options = struct {
    store: *storage.Store,
    control: *control.Control,
    clock: storage.clock.Clock,
    /// Signs pagination cursors (D46). From `DOOT_HMAC_SECRET`.
    cursor_secret: [32]u8,
    /// The engine's lifetime ceiling, which the paid plan's maximum derives from (D56).
    max_ttl_s: u32,
};

pub const Service = struct {
    store: *storage.Store,
    control: *control.Control,
    clock: storage.clock.Clock,
    cursor_secret: [32]u8,
    max_ttl_s: u32,

    pub fn init(options: Options) Service {
        return .{
            .store = options.store,
            .control = options.control,
            .clock = options.clock,
            .cursor_secret = options.cursor_secret,
            .max_ttl_s = options.max_ttl_s,
        };
    }

    pub fn handler(self: *Service) server.Handler {
        return .{ .ctx = self, .respondFn = respond };
    }

    // -----------------------------------------------------------------------
    // The request path
    // -----------------------------------------------------------------------

    fn respond(ctx: *anyopaque, in: Incoming, out: *Reply) Disposition {
        const self: *Service = @ptrCast(@alignCast(ctx));
        const path = in.path();

        // `/healthz` is outside authentication and outside the meter, and is the only
        // endpoint that is (`02-api.md`). Handled before anything else so a liveness
        // probe never depends on a key or a bucket.
        if (std.mem.eql(u8, path, "/healthz")) {
            if (in.method() != .get) return fail(out, .method_not_allowed, "GET");
            out.work = healthzWork;
            return .deferred;
        }

        // 1. Credentials.
        const token = api.parse.bearer(in.header("authorization")) orelse
            return failPlain(out, .missing_credentials);
        const auth = self.control.resolveKey(token) orelse
            return failPlain(out, .invalid_credentials);

        // 2. The rate limit, before any of the request's own fields are looked at.
        const decision = self.control.takeToken(auth.account_id) orelse
            return failPlain(out, .internal_error);
        attachRateHeaders(out, decision);
        if (!decision.allowed) {
            out.retry_after_s = decision.retry_after_s;
            return failPlain(out, .rate_limited);
        }

        // 3. Routing, which now cannot leak which paths exist to an unauthenticated peer.
        return switch (router.route(in.method(), path)) {
            .whoami => self.whoami(out, auth, decision),
            .list => self.beginList(in, out, auth),
            .read => |raw| self.beginEntry(out, auth, raw, .read),
            .remove => |raw| self.beginEntry(out, auth, raw, .remove),
            .wrong_method => |allow| fail(out, .method_not_allowed, allow),
            .unrouted => failPlain(out, .not_found),
            // Answered above, before authentication.
            .healthz => failPlain(out, .internal_error),
        };
    }

    // -----------------------------------------------------------------------
    // GET /healthz
    // -----------------------------------------------------------------------

    /// Both calls touch the engine, so this is the whole endpoint and it runs on a worker.
    fn healthzWork(ctx: *anyopaque, _: Incoming, out: *Reply) void {
        const self: *Service = @ptrCast(@alignCast(ctx));

        if (!self.store.acceptingWrites()) {
            // Reads, lists and deletes still work in this state, which is what the
            // catalogue's message says. `02-api.md` requires the uniform error body on
            // every non-2xx, so this is not a bespoke shape.
            out.fail(.capacity_exhausted);
            return;
        }

        var buf: [64]u8 = undefined;
        var w = json.Writer.init(&buf);
        w.beginObject() catch return out.fail(.internal_error);
        w.stringMember("status", "ok") catch return out.fail(.internal_error);
        w.numberMember("seq", self.store.lastSeq()) catch return out.fail(.internal_error);
        w.endObject() catch return out.fail(.internal_error);

        out.header("Content-Type", "application/json");
        out.body = out.dupe(w.done()) orelse return out.fail(.internal_error);
    }

    // -----------------------------------------------------------------------
    // GET /v1/whoami
    // -----------------------------------------------------------------------

    /// Entirely in-memory, so it never leaves the loop.
    ///
    /// Worth noting rather than assuming: `Control` holds the whole account image in RAM
    /// (D40), so answering "who am I and what am I allowed" costs no disk at all.
    fn whoami(
        self: *Service,
        out: *Reply,
        auth: control.Auth,
        decision: control.Control.RateDecision,
    ) Disposition {
        const account = self.control.account(auth.account_id) orelse
            return failPlain(out, .internal_error);
        const key = self.control.key(auth.key_id) orelse
            return failPlain(out, .internal_error);
        const limits = control.plan.limits(account.plan);

        var buf: [768]u8 = undefined;
        var w = json.Writer.init(&buf);
        var acct_id: [ids.len]u8 = undefined;
        var key_id: [ids.len]u8 = undefined;
        var created: [server.response.timestamp_len]u8 = undefined;

        self.writeWhoami(&w, .{
            .account = account,
            .key = key,
            .limits = limits,
            .decision = decision,
            .acct_buf = &acct_id,
            .key_buf = &key_id,
            .created_buf = &created,
        }) catch return failPlain(out, .internal_error);

        out.header("Content-Type", "application/json");
        out.body = out.dupe(w.done()) orelse return failPlain(out, .internal_error);
        return .complete;
    }

    const WhoamiParts = struct {
        account: control.Account,
        key: control.ApiKey,
        limits: control.plan.Limits,
        decision: control.Control.RateDecision,
        acct_buf: *[ids.len]u8,
        key_buf: *[ids.len]u8,
        created_buf: *[server.response.timestamp_len]u8,
    };

    fn writeWhoami(self: *Service, w: *json.Writer, p: WhoamiParts) json.Error!void {
        try w.beginObject();
        try w.stringMember("account_id", ids.render("acct", p.account.id, p.acct_buf));
        try w.stringMember("email", p.account.email);
        try w.stringMember("plan", @tagName(p.account.plan));

        try w.key("credits");
        try w.beginObject();
        try w.numberMember("remaining", p.account.credits_remaining);
        try w.numberMember("granted", p.account.credits_granted);
        try w.endObject();

        try w.key("rate_limit");
        try w.beginObject();
        try w.numberMember("limit", p.decision.limit);
        try w.stringMember("window", "1m");
        try w.numberMember("remaining", p.decision.remaining);
        try w.endObject();

        try w.key("limits");
        try w.beginObject();
        try w.numberMember("max_body_bytes", storage.config.max_body_bytes);
        try w.numberMember("max_tags", storage.config.max_tags);
        try w.numberMember("max_name_bytes", storage.config.max_name_bytes);
        try w.numberMember("default_ttl_seconds", storage.config.default_ttl_s);
        // The effective ceiling, which is the lower of the plan's and the engine's (D56).
        // Publishing the plan's alone would advertise a lifetime a write might refuse.
        try w.numberMember("max_ttl_seconds", control.plan.maxTtl(p.account.plan, self.max_ttl_s));
        try w.endObject();

        try w.key("key");
        try w.beginObject();
        try w.stringMember("id", ids.render("key", p.key.id, p.key_buf));
        try w.stringMember("created_at", server.response.timestamp(p.key.created_at, p.created_buf));
        try w.endObject();

        try w.endObject();
    }

    // -----------------------------------------------------------------------
    // GET and DELETE /v1/entries/{name}
    // -----------------------------------------------------------------------

    const EntryOp = enum { read, remove };

    /// What a read or a delete carries from the loop to its worker.
    const EntryWork = struct {
        op: EntryOp,
        account_id: u32,
        name_len: u16,
        name_buf: [storage.config.max_name_bytes]u8,

        fn name(e: *const EntryWork) []const u8 {
            return e.name_buf[0..e.name_len];
        }
    };

    /// Decodes and validates the name on the loop, then defers the storage call.
    fn beginEntry(_: *Service, out: *Reply, auth: control.Auth, raw: []const u8, op: EntryOp) Disposition {
        const work = out.workCtx(EntryWork);
        work.* = .{ .op = op, .account_id = auth.account_id, .name_len = 0, .name_buf = undefined };

        // Percent-decoded exactly once, before validation, so the length limit and the
        // character rules apply to the decoded bytes (`03-data-model.md`). `%2F` and a
        // literal `/` therefore address the same entry.
        const decoded = api.parse.decodeName(raw, &work.name_buf) catch
            return failPlain(out, .invalid_name);
        work.name_len = @intCast(decoded.len);

        out.work = entryWork;
        return .deferred;
    }

    fn entryWork(ctx: *anyopaque, _: Incoming, out: *Reply) void {
        const self: *Service = @ptrCast(@alignCast(ctx));
        const work = out.workCtx(EntryWork);
        switch (work.op) {
            .read => self.readWork(work, out),
            .remove => self.removeWork(work, out),
        }
    }

    fn readWork(self: *Service, work: *const EntryWork, out: *Reply) void {
        // `out.out` is the whole 260 KiB slot on a read, because a read has no request
        // body — which is exactly the contract `Store.get` needs (D51).
        const got = self.store.get(work.account_id, work.name(), out.out) catch |err| {
            out.fail(api.errors.fromStore(err));
            return;
        } orelse {
            // Absent and expired are the same answer, deliberately (`03-data-model.md`).
            out.fail(.not_found);
            return;
        };

        out.header("Content-Type", got.content_type);
        // The canonical name, which is the decoded form rather than however it was spelled.
        out.headerCopy("X-Doot-Name", work.name());

        if (got.tag_count > 0) {
            // Five tags at 64 bytes, plus the four commas between them.
            const max_tags_header = @as(usize, storage.config.max_tags) *
                (@as(usize, storage.config.max_tag_bytes) + 1);
            var buf: [max_tags_header]u8 = undefined;
            var len: usize = 0;
            for (got.tags(), 0..) |t, i| {
                if (i > 0) {
                    buf[len] = ',';
                    len += 1;
                }
                @memcpy(buf[len..][0..t.len], t);
                len += t.len;
            }
            out.headerCopy("X-Doot-Tags", buf[0..len]);
        }

        var created: [server.response.timestamp_len]u8 = undefined;
        var expires: [server.response.timestamp_len]u8 = undefined;
        out.headerCopy("X-Doot-Created-At", server.response.timestamp(got.created_at, &created));
        out.headerCopy("X-Doot-Expires-At", server.response.timestamp(got.expires_at, &expires));

        // The stored bytes, not a wrapper, so `curl -o file` gets what was written.
        out.body = got.body;
    }

    fn removeWork(self: *Service, work: *const EntryWork, out: *Reply) void {
        const deleted = self.store.delete(work.account_id, work.name()) catch |err| {
            out.fail(api.errors.fromStore(err));
            return;
        };
        if (!deleted) {
            out.fail(.not_found);
            return;
        }
        // Free, because charging for cleanup punishes the behaviour we want
        // (`01-product.md`). No body: the transport omits `Content-Length` on a 204.
        out.ok(204, "No Content");
    }

    // -----------------------------------------------------------------------
    // GET /v1/entries?tag=…
    // -----------------------------------------------------------------------

    const ListWork = struct {
        account_id: u32,
        limit: u32,
        cursor: storage.tagchain.Cursor,
        tag_len: u8,
        tag_buf: [storage.config.max_tag_bytes]u8,

        fn tag(l: *const ListWork) []const u8 {
            return l.tag_buf[0..l.tag_len];
        }
    };

    /// Validates the query on the loop, then defers the traversal.
    fn beginList(self: *Service, in: Incoming, out: *Reply, auth: control.Auth) Disposition {
        const q = in.query();

        const tag = query.get(q, "tag") orelse return failPlain(out, .missing_tag);
        if (tag.len == 0 or tag.len > storage.config.max_tag_bytes)
            return failPlain(out, .invalid_tag);

        const limit = api.parse.limit(query.get(q, "limit")) catch
            return failPlain(out, .invalid_limit);

        // A cursor is bound to the issuing account and expires, and every failure is the
        // same code so it cannot be used as an oracle (D46).
        const cursor: storage.tagchain.Cursor = if (query.get(q, "cursor")) |text|
            api.cursor.decode(self.cursor_secret, auth.account_id, self.clock.now(), text) catch
                return failPlain(out, .invalid_cursor)
        else
            .{};

        const work = out.workCtx(ListWork);
        work.* = .{
            .account_id = auth.account_id,
            .limit = limit,
            .cursor = cursor,
            .tag_len = @intCast(tag.len),
            .tag_buf = undefined,
        };
        @memcpy(work.tag_buf[0..tag.len], tag);

        out.work = listWork;
        return .deferred;
    }

    /// Writes one entry's metadata as it is walked.
    ///
    /// Straight into the JSON buffer rather than into a list first, because the record's
    /// slices borrow a scratch buffer the walk reuses on every hop — anything kept has to
    /// be copied before `emit` returns, and writing it out *is* the copy.
    const Collector = struct {
        w: *json.Writer,
        failed: bool = false,

        fn emit(self: *Collector, _: storage.Location, rec: storage.record.Record) storage.store.Error!void {
            self.write(rec) catch {
                self.failed = true;
            };
        }

        fn write(self: *Collector, rec: storage.record.Record) json.Error!void {
            try self.w.beginObject();
            try self.w.stringMember("name", rec.name);

            try self.w.key("tags");
            try self.w.beginArray();
            for (rec.tags) |t| try self.w.string(t.text);
            try self.w.endArray();

            try self.w.stringMember("content_type", rec.content_type);
            try self.w.numberMember("size", rec.body.len);

            var created: [server.response.timestamp_len]u8 = undefined;
            var expires: [server.response.timestamp_len]u8 = undefined;
            try self.w.stringMember("created_at", server.response.timestamp(rec.created_at, &created));
            try self.w.stringMember("expires_at", server.response.timestamp(rec.expires_at, &expires));
            try self.w.endObject();
        }
    };

    fn listWork(ctx: *anyopaque, _: Incoming, out: *Reply) void {
        const self: *Service = @ptrCast(@alignCast(ctx));
        const work = out.workCtx(ListWork);

        // Metadata only, so the page is bounded however large the entries are — which is
        // what makes a free list operation safe (D23).
        var w = json.Writer.init(out.out);
        var collector: Collector = .{ .w = &w };

        w.beginObject() catch return out.fail(.internal_error);
        w.key("entries") catch return out.fail(.internal_error);
        w.beginArray() catch return out.fail(.internal_error);

        const result = self.store.list(
            work.account_id,
            work.tag(),
            work.limit,
            work.cursor,
            &collector,
            Collector.emit,
        ) catch |err| {
            out.fail(api.errors.fromStore(err));
            return;
        };
        if (collector.failed) return out.fail(.internal_error);

        w.endArray() catch return out.fail(.internal_error);

        // Absent when the result set is exhausted. A page may be *short* and still carry
        // one, because traversal skips superseded entries and can run out of hop budget
        // first — which is why `02-api.md` tells clients to paginate until the cursor is
        // absent rather than until a page is short.
        if (!result.complete) {
            var text: [api.cursor.encoded_bytes]u8 = undefined;
            api.cursor.encode(
                self.cursor_secret,
                work.account_id,
                self.clock.now(),
                result.cursor,
                &text,
            );
            w.key("cursor") catch return out.fail(.internal_error);
            w.string(&text) catch return out.fail(.internal_error);
        }
        w.endObject() catch return out.fail(.internal_error);

        out.header("Content-Type", "application/json");
        out.body = w.done();
    }
};

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

fn failPlain(out: *Reply, code: Code) Disposition {
    out.fail(code);
    return .complete;
}

fn fail(out: *Reply, code: Code, allow: []const u8) Disposition {
    out.fail(code);
    out.allow = allow;
    return .complete;
}

/// The three headers `02-api.md` puts on every `/v1` response.
///
/// Attached before the reply is filled in — including before a deferral — so they are
/// present whether the request succeeded, was refused, or was rate limited.
fn attachRateHeaders(out: *Reply, d: control.Control.RateDecision) void {
    out.headerInt("RateLimit-Limit", d.limit);
    out.headerInt("RateLimit-Remaining", d.remaining);
    out.headerInt("RateLimit-Reset", d.reset_s);
}

test {
    _ = router;
    _ = query;
    _ = json;
    _ = ids;
}
