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
pub const idempotency = @import("service/idempotency.zig");
pub const password = @import("service/password.zig");
pub const ratelimit = @import("service/ratelimit.zig");
pub const challenge = @import("service/challenge.zig");
pub const mail = @import("service/mail.zig");
pub const app = @import("service/app.zig");
pub const github = @import("service/github.zig");

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
    /// The idempotency table, owned by the caller so its ~56 MB is allocated once.
    idempotency: *IdempotencyTable,
    /// Where a replay re-reads the record it is reproducing (D67). Owned by the caller for
    /// the same reason the table is: ~2 MB has no business being copied into a vtable.
    replays: *ReplayBuffers,

    /// The control plane's state, or null for an instance that serves only `/v1` (D73).
    ///
    /// Null is a **capability boundary, not a degraded mode**: `/app/*` becomes `unrouted`
    /// and answers `404` like any other unknown path, which is exactly right for
    /// `tools/dataplane.zig` — a data-plane harness that has no business owning a mail queue
    /// or an OAuth secret. `main.zig` always supplies it, and `boot.Config` requires the five
    /// variables it needs, so a deployed binary cannot reach production without one.
    app: ?*app.State = null,
};

/// The production table size. 48 B a record at the cap `04-storage.md` records (D62).
pub const IdempotencyTable = idempotency.Table(idempotency.default_records);

/// One record-sized buffer per I/O worker, for replays to re-read into.
///
/// `Reply.out` cannot serve: it is the *tail* of the request slot, so it is only large
/// enough for a whole record while the request body is under about 3 KB — which silently
/// turned every larger replay into a re-execution that charged a credit and overwrote the
/// entry (D67). This is the buffer that makes "replays are free" true at every body size.
///
/// A worker runs one job at a time and there are exactly as many buffers as workers, so a
/// claim cannot fail. No lock, because a lock here would be held across a disk read, which
/// D35 and D57 both refuse.
pub const ReplayBuffers = struct {
    /// One bit per buffer. `fetchOr` claims, `fetchAnd` releases.
    claimed: std.atomic.Value(u32) = .init(0),
    buffers: [server.config.io_workers][storage.store.read_buffer_bytes]u8 = undefined,

    comptime {
        std.debug.assert(server.config.io_workers <= 32); // one bit each
    }

    pub fn init(self: *ReplayBuffers) void {
        // Only the bitmask needs initialising; the buffers are written before they are read.
        self.claimed = .init(0);
    }

    pub const Claim = struct { index: u5, buffer: []u8 };

    pub fn acquire(self: *ReplayBuffers) ?Claim {
        for (0..server.config.io_workers) |i| {
            const bit = @as(u32, 1) << @intCast(i);
            const prev = self.claimed.fetchOr(bit, .acquire);
            if (prev & bit == 0) {
                return .{ .index = @intCast(i), .buffer = &self.buffers[i] };
            }
        }
        return null;
    }

    pub fn release(self: *ReplayBuffers, index: u5) void {
        const bit = @as(u32, 1) << index;
        _ = self.claimed.fetchAnd(~bit, .release);
    }
};

pub const Service = struct {
    store: *storage.Store,
    control: *control.Control,
    clock: storage.clock.Clock,
    cursor_secret: [32]u8,
    max_ttl_s: u32,
    /// Borrowed rather than embedded: the table is ~56 MB and a `Service` is passed by
    /// value into a handler vtable.
    idempotency: *IdempotencyTable,
    /// Borrowed for the same reason (D67).
    replays: *ReplayBuffers,
    /// Null on a data-plane-only instance. See `Options.app`.
    app: ?*app.State = null,

    pub fn init(options: Options) Service {
        return .{
            .store = options.store,
            .control = options.control,
            .clock = options.clock,
            .cursor_secret = options.cursor_secret,
            .max_ttl_s = options.max_ttl_s,
            .idempotency = options.idempotency,
            .replays = options.replays,
            .app = options.app,
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

        // The plane split, before any credential is looked at (D73).
        //
        // It has to come first because the two planes authenticate differently and there is
        // nothing to check until the plane is known: `/v1` reads `Authorization` and never a
        // cookie, `/app` reads the session cookie and never a bearer token. That asymmetry
        // is what removes CSRF from the data plane entirely.
        if (router.plane(path) == .control) return self.respondControl(in, out);

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
            .write => |raw| self.beginWrite(in, out, auth, raw),
            .create => self.beginWrite(in, out, auth, null),
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
    // The control plane (D73)
    // -----------------------------------------------------------------------

    /// Session-authenticated state, resolved once per control-plane request.
    const Session = struct {
        auth: control.Control.SessionAuth,
        token_hash: [32]u8,
    };

    fn respondControl(self: *Service, in: Incoming, out: *Reply) Disposition {
        const st = self.app orelse return failPlain(out, .not_found);
        const route = router.routeApp(in.method(), in.path());

        // Before any credential, because neither depends on one.
        switch (route) {
            .unrouted => return failPlain(out, .not_found),
            .wrong_method => |allow| return fail(out, .method_not_allowed, allow),
            else => {},
        }

        // The unauthenticated half. Rate limited per address and under a global ceiling,
        // because there is no account to charge yet (D74).
        switch (route) {
            .signup, .login, .verify, .password_confirm, .password_reset, .github_start, .github_callback => {
                var key_buf: [server.net.client_key_bytes]u8 = undefined;
                const address = app.clientAddress(in, &key_buf);
                const d = st.unauth.take(address, self.clock.now());
                attachRateHeaders(out, d);
                if (!d.allowed) {
                    out.retry_after_s = d.retry_after_s;
                    return failPlain(out, .rate_limited);
                }
                return switch (route) {
                    .signup => self.beginSignup(in, out),
                    .login => self.beginLogin(in, out),
                    .verify => self.verifyChallenge(in, out),
                    .password_reset => self.requestReset(in, out),
                    .password_confirm => self.beginConfirmReset(in, out),
                    .github_start => self.githubStart(out),
                    .github_callback => self.beginGithubCallback(in, out),
                    else => unreachable,
                };
            },
            else => {},
        }

        // Everything else needs a session. **The cookie, and never a bearer token** — the
        // separation `06-auth.md` requires, enforced here and asserted by tests.
        // The same two codes the data plane uses, because they mean the same thing -- but with
        // control-plane messages. The catalogue's defaults tell the caller to send
        // `Authorization: Bearer`, which is precisely what this surface must never accept, so
        // the default message would be actively misleading here.
        const session = self.resolveSessionCookie(in) orelse {
            if (in.header("cookie") == null) {
                out.failWith(.missing_credentials, "Sign in first: this surface authenticates with a session cookie.");
            } else {
                out.failWith(.invalid_credentials, "The session has expired or is no longer valid. Sign in again.");
            }
            return .complete;
        };

        // The control plane's own bucket, so exploring data cannot exhaust the bucket a
        // production script depends on (D74, `01-product.md`).
        const d = self.control.takeControlToken(session.auth.account_id) orelse
            return failPlain(out, .internal_error);
        attachRateHeaders(out, d);
        if (!d.allowed) {
            out.retry_after_s = d.retry_after_s;
            return failPlain(out, .rate_limited);
        }

        // The synchroniser token, on exactly the routes that change state — decided by the
        // route rather than by each handler, so none can forget (`06-auth.md`).
        if (router.needsSynchroniser(route) and !self.synchroniserOk(in, session)) {
            return failPlain(out, .invalid_synchroniser);
        }

        return switch (route) {
            .logout => self.logout(out, session),
            .account => self.accountView(out, session),
            .account_delete => self.deleteAccount(out, session),
            .keys => self.listKeys(out, session),
            .keys_create => self.createKey(in, out, session),
            .key_revoke => |raw| self.revokeKey(out, session, raw),
            // The explorer goes through the **same** list and read path `/v1` uses. A second
            // implementation is the divergence `00-vision.md` made it read-only to prevent.
            .entries => self.beginList(in, out, self.sessionAsAuth(session)),
            .entry => |raw| self.beginEntry(out, self.sessionAsAuth(session), raw, .read),
            else => failPlain(out, .internal_error),
        };
    }

    /// A session, or null. Unknown, expired, deleted and unverified are one answer, so this
    /// is no more an oracle than `resolveKey` is.
    fn resolveSessionCookie(self: *Service, in: Incoming) ?Session {
        const token = api.cookie.get(in.header("cookie"), api.cookie.session_name) orelse
            return null;
        const auth = self.control.resolveSession(token) orelse return null;
        return .{ .auth = auth, .token_hash = control.hashKey(token) };
    }

    /// The explorer reads as the session's account, at the account's plan.
    ///
    /// A synthesised `Auth` rather than a second code path: `key_id` is zero because no key
    /// was presented, and nothing on the read path consults it — `whoami` is the only
    /// endpoint that does, and it is not reachable from here.
    fn sessionAsAuth(_: *Service, s: Session) control.Auth {
        return .{
            .account_id = s.auth.account_id,
            .key_id = 0,
            .plan = s.auth.plan,
            .credits_remaining = 0,
        };
    }

    fn synchroniserOk(self: *Service, in: Incoming, s: Session) bool {
        const expected = api.secret.csrfToken(self.cursor_secret, s.token_hash);
        const presented = in.header("x-doot-synchroniser") orelse return false;
        return api.secret.csrfMatches(expected, presented);
    }

    // ---- POST /app/auth/signup ----

    const SignupCtx = struct {
        anchor: [32]u8,
        email: [api.email.max_bytes]u8,
        email_len: u16,
        password: [app.max_password_bytes]u8,
        password_len: u16,
    };

    /// Validates on the loop and hands the hashing to a worker (D71).
    ///
    /// **Always answers `202`**, whether or not the address is already known — and the worker
    /// performs the same Argon2id hash either way (D75). Identical responses alone are not
    /// enough: the branch that decides whether to hash is itself the oracle.
    fn beginSignup(self: *Service, in: Incoming, out: *Reply) Disposition {
        _ = self;
        var email_buf: [api.email.max_bytes]u8 = undefined;
        var pw_buf: [app.max_password_bytes]u8 = undefined;

        const email = (api.form.field(in.body, "email", &email_buf) catch
            return failPlain(out, .invalid_request)) orelse
            return failPlain(out, .invalid_email);
        const pw = (api.form.field(in.body, "password", &pw_buf) catch
            return failPlain(out, .invalid_request)) orelse
            return failPlain(out, .password_too_short);

        api.email.check(email) catch return failPlain(out, .invalid_email);
        if (!app.passwordAcceptable(pw)) return failPlain(out, .password_too_short);
        const anchor = api.email.anchorHash(email) catch return failPlain(out, .invalid_email);

        const ctx = out.workCtx(SignupCtx);
        ctx.anchor = anchor;
        ctx.email_len = @intCast(email.len);
        @memcpy(ctx.email[0..email.len], email);
        ctx.password_len = @intCast(pw.len);
        @memcpy(ctx.password[0..pw.len], pw);

        out.work = signupWork;
        return .deferred;
    }

    fn signupWork(ctx_ptr: *anyopaque, _: Incoming, out: *Reply) void {
        const self: *Service = @ptrCast(@alignCast(ctx_ptr));
        const st = self.app.?;
        const c = out.workCtx(SignupCtx);
        const email = c.email[0..c.email_len];
        const pw = c.password[0..c.password_len];

        // Unconditional, and before the lookup: the cost must not depend on the answer.
        var phc_buf: [password.max_phc_bytes]u8 = undefined;
        const phc = password.hash(st.gpa, pw, &phc_buf) catch
            return out.fail(.internal_error);

        if (st.lookupAccount(c.anchor) == null) {
            const id = self.control.createAccount(email, .trial, .pending_verification, 0) catch
                return out.fail(.internal_error);
            self.control.setPassword(id, phc) catch return out.fail(.internal_error);
            st.indexAccount(c.anchor, id);
            self.issueChallenge(.verify, c.anchor, email);
        }
        // Nothing is created and no mail is sent for a known address — and the response is
        // the same one a new signup gets.
        self.acceptedPending(out);
    }

    fn acceptedPending(_: *Service, out: *Reply) void {
        out.ok(202, "Accepted");
        out.header("Content-Type", "application/json");
        out.body = "{\"status\":\"pending_verification\"}";
    }

    /// Issues an OTP and queues the mail. Failures are swallowed on purpose: a caller must
    /// not learn from the response whether a code was actually sent.
    fn issueChallenge(self: *Service, purpose: challenge.Purpose, anchor: [32]u8, email: []const u8) void {
        const st = self.app.?;
        const code = challenge.generateCode() catch return;
        if (st.challenges.issue(purpose, anchor, &code, self.clock.now()) != .ok) return;

        const kind: mail.Kind = switch (purpose) {
            .verify => .verify,
            .reset => .reset,
        };
        const msg = mail.Message.init(kind, email, &code) orelse return;
        _ = st.queue.push(msg);
    }

    // ---- POST /app/auth/verify ----

    /// Activates an account and issues its first API key, all in one response.
    ///
    /// `01-product.md`'s conversion moment: the key is shown once, here, and never again.
    fn verifyChallenge(self: *Service, in: Incoming, out: *Reply) Disposition {
        const st = self.app.?;
        var email_buf: [api.email.max_bytes]u8 = undefined;
        var code_buf: [16]u8 = undefined;

        const email = (api.form.field(in.body, "email", &email_buf) catch
            return failPlain(out, .invalid_request)) orelse
            return failPlain(out, .invalid_email);
        const code = (api.form.field(in.body, "code", &code_buf) catch
            return failPlain(out, .invalid_request)) orelse
            return failPlain(out, .invalid_challenge);
        const anchor = api.email.anchorHash(email) catch return failPlain(out, .invalid_email);

        if (st.challenges.present(.verify, anchor, code, self.clock.now()) != .ok) {
            return failPlain(out, .invalid_challenge);
        }

        const id = st.lookupAccount(anchor) orelse return failPlain(out, .invalid_challenge);

        // The grant is decided by the anchor, not by the plan table: a second account on the
        // same identity activates with zero (`06-auth.md`, D72). `claimAnchor` is idempotent,
        // so a retried activation cannot hand out a second grant.
        const owner = self.control.claimAnchor(.email, anchor, id) catch
            return failPlain(out, .internal_error);
        const granted: u32 = if (owner == id) control.plan.limits(.trial).granted_credits else 0;
        self.control.activateAccount(id, granted) catch return failPlain(out, .internal_error);

        // A session, and **no key** (D83). The dashboard's first-run screen calls
        // `POST /app/keys`, which is the one way a key is ever issued — so the email and OAuth
        // paths end identically even though only one of them can carry JSON back.
        self.startSession(out, id) catch return failPlain(out, .internal_error);
        out.ok(201, "Created");
        return .complete;
    }

    /// Generates a key, records its digest, and returns the plaintext exactly once.
    fn issueKeyResponse(
        self: *Service,
        out: *Reply,
        account_id: u32,
        status: u16,
        reason: []const u8,
        granted: ?u32,
    ) Disposition {
        const plaintext = api.secret.apiKey() catch return failPlain(out, .internal_error);
        const key_id = self.control.issueKey(account_id, "", &plaintext) catch |err| {
            return failPlain(out, switch (err) {
                error.KeyLimitReached => .key_limit_reached,
                else => .internal_error,
            });
        };

        var buf: [256]u8 = undefined;
        var w = json.Writer.init(&buf);
        var acct: [ids.len]u8 = undefined;
        var kid: [ids.len]u8 = undefined;
        blk: {
            w.beginObject() catch break :blk;
            w.stringMember("account_id", ids.render("acct", account_id, &acct)) catch break :blk;
            w.stringMember("key_id", ids.render("key", key_id, &kid)) catch break :blk;
            // The only time this value exists in a response. It is never stored and cannot be
            // retrieved again (`06-auth.md`, D76).
            w.stringMember("api_key", &plaintext) catch break :blk;
            if (granted) |g| w.numberMember("credits_granted", g) catch break :blk;
            w.endObject() catch break :blk;

            out.ok(status, reason);
            out.header("Content-Type", "application/json");
            out.body = out.dupe(w.done()) orelse return failPlain(out, .internal_error);
            return .complete;
        }
        return failPlain(out, .internal_error);
    }

    // ---- GET /app/auth/github and its callback ----

    /// Redirects to GitHub, binding a fresh `state` to a short-lived cookie.
    ///
    /// The binding is what makes the callback trustworthy: a callback presenting a `state` we
    /// never issued, or one issued to a different browser, is refused rather than acted on.
    /// **Both halves are required** — the server-side entry proves we issued it, and the cookie
    /// proves it was issued to *this* browser. Either alone is forgeable by someone who can
    /// make the victim's browser follow a link.
    fn githubStart(self: *Service, out: *Reply) Disposition {
        const st = self.app.?;

        const state = api.secret.sessionToken() catch return failPlain(out, .internal_error);
        st.challenges.beginOauth(control.hashKey(&state), self.clock.now());

        var cookie_buf: [api.cookie.max_set_cookie_bytes]u8 = undefined;
        // No `Max-Age`: a browser that abandons the flow forgets it when it closes, and the
        // server-side entry expires in ten minutes regardless.
        const set = api.cookie.set(&cookie_buf, api.cookie.oauth_name, &state, null) catch
            return failPlain(out, .internal_error);
        out.headerCopy("Set-Cookie", set);

        var url_buf: [640]u8 = undefined;
        const url = github.authorizeUrl(
            st.cfg.github_client_id,
            st.cfg.public_origin,
            &state,
            &url_buf,
        ) catch return failPlain(out, .internal_error);

        out.ok(302, "Found");
        out.headerCopy("Location", url);
        // Nothing may cache a redirect that carries a one-time state.
        out.header("Cache-Control", "no-store");
        out.body = &.{};
        return .complete;
    }

    const GithubCtx = struct {
        code: [512]u8,
        code_len: u16,
    };

    /// Validates the `state` on the loop, then hands the exchange to a worker.
    ///
    /// The state check happens here, before any outbound call: an unsolicited callback must
    /// cost us nothing, and a round trip to GitHub for a request we can already refuse is
    /// exactly what an attacker would use to make us do their network calls.
    fn beginGithubCallback(self: *Service, in: Incoming, out: *Reply) Disposition {
        const st = self.app.?;

        // Query values are percent-decoded before use: GitHub's own code is alphanumeric, but
        // the value on the wire is caller-supplied and decoding it once is what makes
        // "the bytes GitHub gave us" and "the bytes we send back" the same string.
        var code_buf: [512]u8 = undefined;
        var state_buf: [128]u8 = undefined;
        const raw_code = query.get(in.query(), "code") orelse
            return failPlain(out, .invalid_request);
        const raw_state = query.get(in.query(), "state") orelse
            return failPlain(out, .invalid_request);
        if (raw_code.len == 0 or raw_code.len > code_buf.len) return failPlain(out, .invalid_request);
        if (raw_state.len == 0 or raw_state.len > state_buf.len) return failPlain(out, .invalid_request);
        const code = api.form.decode(raw_code, &code_buf) catch
            return failPlain(out, .invalid_request);
        const state = api.form.decode(raw_state, &state_buf) catch
            return failPlain(out, .invalid_request);

        // The cookie half: was this state issued to this browser?
        const cookie_state = api.cookie.get(in.header("cookie"), api.cookie.oauth_name) orelse
            return failPlain(out, .invalid_request);
        if (!std.crypto.timing_safe.eql(
            [32]u8,
            control.hashKey(state),
            control.hashKey(cookie_state),
        )) return failPlain(out, .invalid_request);

        // The server-side half: did we issue it, and is this the first use? `takeOauth`
        // consumes, so a replayed callback finds nothing.
        if (!st.challenges.takeOauth(control.hashKey(state), self.clock.now())) {
            return failPlain(out, .invalid_request);
        }

        const ctx = out.workCtx(GithubCtx);
        ctx.code_len = @intCast(code.len);
        @memcpy(ctx.code[0..code.len], code);
        out.work = githubCallbackWork;
        return .deferred;
    }

    fn githubCallbackWork(ctx_ptr: *anyopaque, _: Incoming, out: *Reply) void {
        const self: *Service = @ptrCast(@alignCast(ctx_ptr));
        const st = self.app.?;
        const c = out.workCtx(GithubCtx);

        const identity = github.exchange(
            st.gpa,
            st.cfg.github_client_id,
            st.cfg.github_client_secret,
            st.cfg.public_origin,
            c.code[0..c.code_len],
        ) catch |err| return switch (err) {
            // The one failure a user can act on, so it is the one that is distinguishable.
            error.NoVerifiedEmail => out.failWith(
                .invalid_email,
                "Your GitHub account has no verified email address. Verify one and try again.",
            ),
            else => out.fail(.internal_error),
        };

        const address = identity.email();
        const anchor = api.email.anchorHash(address) catch return out.fail(.internal_error);

        // Match on the GitHub id first, then the verified email, else create — the order
        // `06-auth.md` specifies. The id leads because it is the anchor that cannot be
        // reassigned; a username can, and an email can change hands between providers.
        const account_id = self.control.githubOwner(identity.user_id) orelse
            st.lookupAccount(anchor) orelse
            blk: {
                // GitHub verified the address, so the account is `active` immediately — there
                // is nothing left for an OTP to prove.
                const id = self.control.createAccount(address, .trial, .active, 0) catch
                    return out.fail(.internal_error);
                st.indexAccount(anchor, id);
                break :blk id;
            };

        // Idempotent, so an existing account simply keeps its link.
        self.control.linkGithub(account_id, identity.user_id) catch
            return out.fail(.internal_error);

        // Both anchors, because the grant is bound to either (D72, `01-product.md`). The
        // *email* anchor decides the grant: it is the one an attacker would rotate, and
        // claiming the GitHub one too is what stops delete-and-resignup through this path.
        const email_owner = self.control.claimAnchor(.email, anchor, account_id) catch
            return out.fail(.internal_error);
        var gh_anchor: [32]u8 = @splat(0);
        std.mem.writeInt(u64, gh_anchor[0..8], identity.user_id, .little);
        _ = self.control.claimAnchor(.github, gh_anchor, account_id) catch
            return out.fail(.internal_error);

        // Activation is idempotent in effect: an account signing in again keeps the balance it
        // has, and only a first activation grants anything.
        const account = self.control.account(account_id) orelse return out.fail(.internal_error);
        if (account.state != .active or account.credits_granted == 0) {
            const granted: u32 = if (email_owner == account_id)
                control.plan.limits(.trial).granted_credits
            else
                0;
            self.control.activateAccount(account_id, granted) catch
                return out.fail(.internal_error);
        }

        self.startSession(out, account_id) catch return out.fail(.internal_error);

        // A browser navigation, so the answer is a redirect rather than the JSON `startSession`
        // wrote — and the key is **not** delivered here (D83): a credential in a redirect ends
        // up in history and in any referrer the landing page emits.
        out.body = &.{};
        out.ok(302, "Found");
        out.headerCopy("Location", st.cfg.public_origin);
        out.header("Cache-Control", "no-store");
    }

    // ---- POST /app/auth/login ----

    const LoginCtx = struct {
        anchor: [32]u8,
        password: [app.max_password_bytes]u8,
        password_len: u16,
    };

    fn beginLogin(self: *Service, in: Incoming, out: *Reply) Disposition {
        _ = self;
        var email_buf: [api.email.max_bytes]u8 = undefined;
        var pw_buf: [app.max_password_bytes]u8 = undefined;

        const email = (api.form.field(in.body, "email", &email_buf) catch
            return failPlain(out, .invalid_request)) orelse
            return failPlain(out, .invalid_credentials);
        const pw = (api.form.field(in.body, "password", &pw_buf) catch
            return failPlain(out, .invalid_request)) orelse
            return failPlain(out, .invalid_credentials);

        // A malformed address is `invalid_credentials`, not `invalid_email`: on login the two
        // must be indistinguishable, or the endpoint reports which addresses are well-formed
        // enough to exist.
        const anchor = api.email.anchorHash(email) catch
            return failPlain(out, .invalid_credentials);

        const ctx = out.workCtx(LoginCtx);
        ctx.anchor = anchor;
        ctx.password_len = @intCast(pw.len);
        @memcpy(ctx.password[0..pw.len], pw);

        out.work = loginWork;
        return .deferred;
    }

    fn loginWork(ctx_ptr: *anyopaque, _: Incoming, out: *Reply) void {
        const self: *Service = @ptrCast(@alignCast(ctx_ptr));
        const st = self.app.?;
        const c = out.workCtx(LoginCtx);
        const pw = c.password[0..c.password_len];

        // The stored hash is **copied** before the verification: `Control.password` borrows
        // the store's copy, a concurrent password change frees it, and a verification is
        // exactly long enough for that to matter.
        var phc_buf: [password.max_phc_bytes]u8 = undefined;
        var stored: ?[]const u8 = null;
        if (st.lookupAccount(c.anchor)) |id| {
            if (self.control.password(id)) |p| {
                @memcpy(phc_buf[0..p.phc.len], p.phc);
                stored = phc_buf[0..p.phc.len];
            }
        }

        // Runs a full verification either way, so an unknown address costs what a known one
        // costs (D75).
        if (!password.verifyOrEqualise(st.gpa, stored, st.dummy, pw)) {
            return out.fail(.invalid_credentials);
        }

        const id = st.lookupAccount(c.anchor) orelse return out.fail(.invalid_credentials);
        const account = self.control.account(id) orelse return out.fail(.invalid_credentials);
        // An unverified account cannot sign in, and says so with the same answer a wrong
        // password gets.
        if (account.state != .active) return out.fail(.invalid_credentials);

        self.startSession(out, id) catch out.fail(.internal_error);
    }

    /// Creates a session, sets the cookie, and returns the synchroniser token.
    ///
    /// The token is derived rather than stored (D76), so it needs no storage and survives a
    /// restart; the browser reads it here and sends it back on state-changing requests.
    fn startSession(self: *Service, out: *Reply, account_id: u32) !void {
        const token = try api.secret.sessionToken();
        _ = try self.control.createSession(account_id, &token);

        var cookie_buf: [api.cookie.max_set_cookie_bytes]u8 = undefined;
        const set = try api.cookie.set(
            &cookie_buf,
            api.cookie.session_name,
            &token,
            control.store.session_lifetime_s,
        );
        out.headerCopy("Set-Cookie", set);

        const csrf = api.secret.csrfToken(self.cursor_secret, control.hashKey(&token));
        var buf: [192]u8 = undefined;
        var w = json.Writer.init(&buf);
        var acct: [ids.len]u8 = undefined;
        try w.beginObject();
        try w.stringMember("account_id", ids.render("acct", account_id, &acct));
        try w.stringMember("synchroniser", &csrf);
        try w.endObject();

        out.header("Content-Type", "application/json");
        out.body = out.dupe(w.done()) orelse return error.NoSpace;
    }

    // ---- POST /app/auth/logout ----

    fn logout(self: *Service, out: *Reply, s: Session) Disposition {
        _ = self.control.revokeSession(s.auth.session_id) catch
            return failPlain(out, .internal_error);
        return self.clearedSession(out, 204, "No Content");
    }

    fn clearedSession(_: *Service, out: *Reply, status: u16, reason: []const u8) Disposition {
        var cookie_buf: [api.cookie.max_set_cookie_bytes]u8 = undefined;
        const cleared = api.cookie.clear(&cookie_buf, api.cookie.session_name) catch
            return failPlain(out, .internal_error);
        out.headerCopy("Set-Cookie", cleared);
        out.ok(status, reason);
        out.body = &.{};
        return .complete;
    }

    // ---- POST /app/auth/password/reset and /confirm ----

    /// Always `202`, whether or not the address is known (`06-auth.md`, D75).
    fn requestReset(self: *Service, in: Incoming, out: *Reply) Disposition {
        const st = self.app.?;
        var email_buf: [api.email.max_bytes]u8 = undefined;
        const email = (api.form.field(in.body, "email", &email_buf) catch
            return failPlain(out, .invalid_request)) orelse
            return failPlain(out, .invalid_email);

        // A well-formed address that does not exist reaches exactly the same code as one that
        // does, right up to the enqueue.
        if (api.email.anchorHash(email)) |anchor| {
            if (st.lookupAccount(anchor) != null) self.issueChallenge(.reset, anchor, email);
        } else |_| {}

        out.ok(202, "Accepted");
        out.header("Content-Type", "application/json");
        out.body = "{\"status\":\"sent\"}";
        return .complete;
    }

    const ConfirmCtx = struct {
        anchor: [32]u8,
        account_id: u32,
        password: [app.max_password_bytes]u8,
        password_len: u16,
    };

    fn beginConfirmReset(self: *Service, in: Incoming, out: *Reply) Disposition {
        const st = self.app.?;
        var email_buf: [api.email.max_bytes]u8 = undefined;
        var code_buf: [16]u8 = undefined;
        var pw_buf: [app.max_password_bytes]u8 = undefined;

        const email = (api.form.field(in.body, "email", &email_buf) catch
            return failPlain(out, .invalid_request)) orelse
            return failPlain(out, .invalid_email);
        const code = (api.form.field(in.body, "code", &code_buf) catch
            return failPlain(out, .invalid_request)) orelse
            return failPlain(out, .invalid_challenge);
        const pw = (api.form.field(in.body, "password", &pw_buf) catch
            return failPlain(out, .invalid_request)) orelse
            return failPlain(out, .password_too_short);

        if (!app.passwordAcceptable(pw)) return failPlain(out, .password_too_short);
        const anchor = api.email.anchorHash(email) catch return failPlain(out, .invalid_email);

        if (st.challenges.present(.reset, anchor, code, self.clock.now()) != .ok) {
            return failPlain(out, .invalid_challenge);
        }
        const id = st.lookupAccount(anchor) orelse return failPlain(out, .invalid_challenge);

        const ctx = out.workCtx(ConfirmCtx);
        ctx.anchor = anchor;
        ctx.account_id = id;
        ctx.password_len = @intCast(pw.len);
        @memcpy(ctx.password[0..pw.len], pw);

        out.work = confirmResetWork;
        return .deferred;
    }

    fn confirmResetWork(ctx_ptr: *anyopaque, _: Incoming, out: *Reply) void {
        const self: *Service = @ptrCast(@alignCast(ctx_ptr));
        const st = self.app.?;
        const c = out.workCtx(ConfirmCtx);

        var phc_buf: [password.max_phc_bytes]u8 = undefined;
        const phc = password.hash(st.gpa, c.password[0..c.password_len], &phc_buf) catch
            return out.fail(.internal_error);
        self.control.setPassword(c.account_id, phc) catch return out.fail(.internal_error);

        // Every session for the account goes (`06-auth.md`). A reset is what someone does
        // when they think a credential is compromised, so leaving a session alive would
        // defeat the point of it.
        _ = self.control.revokeSessionsFor(c.account_id) catch {};

        out.ok(200, "OK");
        out.header("Content-Type", "application/json");
        out.body = "{\"status\":\"reset\"}";
    }

    // ---- GET and DELETE /app/account ----

    fn accountView(self: *Service, out: *Reply, s: Session) Disposition {
        const account = self.control.account(s.auth.account_id) orelse
            return failPlain(out, .internal_error);
        const limits = control.plan.limits(account.plan);

        var buf: [512]u8 = undefined;
        var w = json.Writer.init(&buf);
        var acct: [ids.len]u8 = undefined;
        var created: [server.response.timestamp_len]u8 = undefined;
        blk: {
            w.beginObject() catch break :blk;
            w.stringMember("account_id", ids.render("acct", account.id, &acct)) catch break :blk;
            // The delivery address, exactly as supplied — never the anchor (D72).
            w.stringMember("email", account.email) catch break :blk;
            w.stringMember("plan", @tagName(account.plan)) catch break :blk;
            w.stringMember("state", @tagName(account.state)) catch break :blk;
            w.stringMember(
                "created_at",
                server.response.timestamp(account.created_at, &created),
            ) catch break :blk;
            w.key("credits") catch break :blk;
            w.beginObject() catch break :blk;
            w.numberMember("remaining", account.credits_remaining) catch break :blk;
            w.numberMember("granted", account.credits_granted) catch break :blk;
            w.endObject() catch break :blk;
            w.numberMember("max_ttl_seconds", control.plan.maxTtl(account.plan, self.max_ttl_s)) catch break :blk;
            w.numberMember("rate_limit", limits.rate_per_min) catch break :blk;
            // Re-derived per response rather than stored, so a browser that reloads always
            // has a usable one (D76).
            w.stringMember(
                "synchroniser",
                &api.secret.csrfToken(self.cursor_secret, s.token_hash),
            ) catch break :blk;
            w.endObject() catch break :blk;

            out.header("Content-Type", "application/json");
            out.body = out.dupe(w.done()) orelse return failPlain(out, .internal_error);
            return .complete;
        }
        return failPlain(out, .internal_error);
    }

    /// Self-service deletion (D77).
    ///
    /// Entries are **not** deleted, and cannot be: the index holds no names, so nothing can
    /// enumerate an account's entries. Access ends here and the bytes leave with their
    /// expiry, bounded by the plan's maximum lifetime.
    fn deleteAccount(self: *Service, out: *Reply, s: Session) Disposition {
        const st = self.app.?;
        const account = self.control.account(s.auth.account_id) orelse
            return failPlain(out, .internal_error);

        // Unindexed first: after the account is gone its address is no longer available to
        // compute an anchor from, and a stale index entry would point at nothing.
        if (api.email.anchorHash(account.email)) |anchor| {
            st.unindexAccount(anchor);
        } else |_| {}

        _ = self.control.deleteAccount(s.auth.account_id) catch
            return failPlain(out, .internal_error);
        return self.clearedSession(out, 204, "No Content");
    }

    // ---- /app/keys ----

    fn listKeys(self: *Service, out: *Reply, s: Session) Disposition {
        var buf: [640]u8 = undefined;
        const KeyCollector = struct {
            w: *json.Writer,
            failed: bool = false,
            fn visit(c: *@This(), k: control.ApiKey) void {
                if (c.failed) return;
                var kid: [ids.len]u8 = undefined;
                var created: [server.response.timestamp_len]u8 = undefined;
                c.emit(k, &kid, &created) catch {
                    c.failed = true;
                };
            }
            fn emit(
                c: *@This(),
                k: control.ApiKey,
                kid: *[ids.len]u8,
                created: *[server.response.timestamp_len]u8,
            ) !void {
                try c.w.beginObject();
                try c.w.stringMember("id", ids.render("key", k.id, kid));
                try c.w.stringMember("label", k.label);
                try c.w.stringMember("created_at", server.response.timestamp(k.created_at, created));
                try c.w.endObject();
            }
        };

        var w = json.Writer.init(&buf);
        var collector: KeyCollector = .{ .w = &w };
        blk: {
            w.beginObject() catch break :blk;
            w.key("keys") catch break :blk;
            w.beginArray() catch break :blk;
            self.control.forEachKey(s.auth.account_id, &collector, KeyCollector.visit);
            if (collector.failed) break :blk;
            w.endArray() catch break :blk;
            w.numberMember("maximum", control.store.max_keys_per_account) catch break :blk;
            w.endObject() catch break :blk;

            out.header("Content-Type", "application/json");
            out.body = out.dupe(w.done()) orelse return failPlain(out, .internal_error);
            return .complete;
        }
        return failPlain(out, .internal_error);
    }

    fn createKey(self: *Service, in: Incoming, out: *Reply, s: Session) Disposition {
        _ = in;
        return self.issueKeyResponse(out, s.auth.account_id, 201, "Created", null);
    }

    fn revokeKey(self: *Service, out: *Reply, s: Session, raw: []const u8) Disposition {
        const key_id = ids.parse("key", raw) orelse return failPlain(out, .not_found);
        // Ownership is checked inside `Control`, not here: a check the caller performs is a
        // check the caller can forget, and forgetting it would let one session revoke another
        // account's key.
        const revoked = self.control.revokeOwnedKey(s.auth.account_id, key_id) catch
            return failPlain(out, .internal_error);
        if (!revoked) return failPlain(out, .not_found);
        out.ok(204, "No Content");
        return .complete;
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
    // PUT /v1/entries/{name} and POST /v1/entries
    // -----------------------------------------------------------------------

    /// Everything the write needs, validated on the loop and carried to the worker.
    ///
    /// It carries the *whole* write context even when a replay is expected, and that is
    /// deliberate. A recorded outcome can turn out to be unreadable — an entry with a
    /// lifetime under 24 hours can expire and be reclaimed while its record is still live —
    /// and D61 settles that case as "the record is treated as absent and the request
    /// executes normally". The worker can only do that if it still has everything the
    /// write needs, so nothing is discarded on the way in.
    const WriteWork = struct {
        account_id: u32,
        /// `POST`, so the reply carries `Location`.
        assigned: bool,
        ttl_s: u32,
        name_len: u16,
        name_buf: [storage.config.max_name_bytes]u8,
        /// Borrowed from the request head, which outlives the write.
        content_type: []const u8,
        tags: api.parse.TagSet,
        /// Null when no `Idempotency-Key` was presented.
        key: ?idempotency.Hash,

        /// A recorded outcome to try to replay before writing anything.
        replay: ?idempotency.Replay,
        /// Whether a credit has already been deducted. False on the replay path, because a
        /// replay is free — and it is what tells the worker it must pay before falling back
        /// to a real write.
        credit_taken: bool,
        /// For the header on a replay, where no deduction moves the balance.
        credits_remaining: u32,

        fn name(x: *const WriteWork) []const u8 {
            return x.name_buf[0..x.name_len];
        }
    };

    /// Validates a write and reserves everything it needs, in `03-data-model.md`'s order.
    ///
    /// Steps 1 and 2 — credentials and the rate limit — already ran. Step 3, the body
    /// ceiling, was enforced by the transport from `Content-Length` before a byte was read.
    /// This is steps 4 through 8: name, tags, lifetime, idempotency, credit. Step 9,
    /// capacity, is the engine's own admission check and surfaces from `put` as a `503`.
    ///
    /// All of it is memory-only, which is why it belongs here and not on the worker (D57).
    fn beginWrite(
        self: *Service,
        in: Incoming,
        out: *Reply,
        auth: control.Auth,
        raw_name: ?[]const u8,
    ) Disposition {
        const work = out.workCtx(WriteWork);
        work.* = .{
            .account_id = auth.account_id,
            .assigned = raw_name == null,
            .ttl_s = 0,
            .name_len = 0,
            .name_buf = undefined,
            .content_type = "application/octet-stream",
            .tags = .{},
            .key = null,
            .replay = null,
            .credit_taken = false,
            .credits_remaining = auth.credits_remaining,
        };

        // 4. The name. Supplied and percent-decoded for a `PUT`; assigned for a `POST`,
        //    where a ULID gives a caller with no natural name chronological ordering for
        //    free (`03-data-model.md`).
        if (raw_name) |raw| {
            const decoded = api.parse.decodeName(raw, &work.name_buf) catch
                return failPlain(out, .invalid_name);
            work.name_len = @intCast(decoded.len);
        } else {
            // Milliseconds, because D47 specifies the ordering to that resolution and the
            // injected clock only carries seconds (`storage.os.realtimeMillis`).
            const ms: u48 = @truncate(storage.os.realtimeMillis());
            const assigned = api.ulid.generate(ms) catch return failPlain(out, .internal_error);
            @memcpy(work.name_buf[0..api.ulid.len], &assigned);
            work.name_len = api.ulid.len;
        }

        // 5. Tags: split, trimmed, emptied elements dropped, lowercased, de-duplicated,
        //    and only then counted — so six copies of one tag is one tag (D47).
        if (in.header("x-doot-tags")) |raw| {
            api.parse.tags(raw, &work.tags) catch |err| return failPlain(out, switch (err) {
                error.TooManyTags => .too_many_tags,
                else => .invalid_tag,
            });
        }

        // 6. Lifetime. Unparseable and out-of-range are different answers, which keeps
        //    "I typed it wrong" apart from "my plan will not allow it" (`02-api.md`).
        const ceiling = control.plan.maxTtl(auth.plan, self.max_ttl_s);
        if (in.header("x-doot-ttl")) |raw| {
            work.ttl_s = api.parse.ttl(raw) catch return failPlain(out, .invalid_ttl);
        } else {
            work.ttl_s = storage.config.default_ttl_s;
        }
        if (work.ttl_s < storage.config.min_ttl_s) return failPlain(out, .ttl_too_short);
        if (work.ttl_s > ceiling) return failPlain(out, .ttl_too_long);

        // 7. The content type is stored verbatim and echoed on read; the server never acts
        // on it. Borrowed rather than copied, because the request head outlives the write.
        if (in.header("content-type")) |ct| {
            if (ct.len > storage.config.max_content_type_bytes)
                return failPlain(out, .content_type_too_long);
            // Because it is echoed into a response header, it has to be something a header
            // can carry (D64). Without this a `NUL` or `CR` is stored happily and then
            // fails `response.headerSafe` on every subsequent read — a write that succeeds,
            // charges a credit, and leaves an entry nobody can ever get. Printable ASCII
            // rather than just the three bytes the writer rejects, so the rule survives the
            // writer's prohibitions being tightened.
            if (!api.parse.printableAscii(ct)) return failPlain(out, .invalid_content_type);
            if (ct.len > 0) work.content_type = ct;
        }

        // 8. Idempotency.
        if (in.header("idempotency-key")) |raw| {
            // "Any string, 1-255 bytes" (`02-api.md`). A header that cannot be used as a
            // key is a malformed request rather than a validation failure on an entry
            // field, which is what `invalid_request` is for.
            if (raw.len == 0 or raw.len > 255) return failPlain(out, .invalid_request);

            const key = idempotency.keyHash(auth.account_id, raw);
            switch (self.idempotency.begin(key, idempotency.bodyHash(in.body), self.clock.now())) {
                .proceed => work.key = key,
                .conflict => return failPlain(out, .idempotency_key_reused),
                .in_progress => return failPlain(out, .idempotency_in_progress),
                // Free, and not merely uncharged: a misconfigured automation retrying in a
                // loop must not generate a bill (D20). No credit is taken, and the worker
                // pays only if the recorded outcome turns out to be unreadable.
                .replay => |r| {
                    work.key = key;
                    work.replay = r;
                    out.work = writeWork;
                    return .deferred;
                },
            }
        }

        // 8. The credit, which is the last thing before the write itself. Deducted here and
        //    refunded by the worker if the write fails, so a failed write costs nothing
        //    (`03-data-model.md`).
        switch (self.control.spendCredit(auth.account_id)) {
            .spent => work.credit_taken = true,
            .exhausted => {
                // The reservation goes back: an in-progress marker with no request behind
                // it would 409 for a full window (D62).
                if (work.key) |k| self.idempotency.abandon(k);
                return failPlain(out, .credits_exhausted);
            },
            .no_account => {
                if (work.key) |k| self.idempotency.abandon(k);
                return failPlain(out, .internal_error);
            },
        }

        out.work = writeWork;
        return .deferred;
    }

    fn writeWork(ctx: *anyopaque, in: Incoming, out: *Reply) void {
        const self: *Service = @ptrCast(@alignCast(ctx));
        const work = out.workCtx(WriteWork);

        // The replay path first. It ends here when the recorded outcome can still be read,
        // and falls through to a real write when it cannot.
        if (work.replay) |r| {
            if (self.replayInto(out, work, r)) return;

            // Unreadable, so there is no outcome to reproduce and the record is treated as
            // absent (D61). Executing normally means paying for it, which the replay path
            // deliberately had not done.
            switch (self.control.spendCredit(work.account_id)) {
                .spent => work.credit_taken = true,
                .exhausted => return out.fail(.credits_exhausted),
                .no_account => return out.fail(.internal_error),
            }
        }

        var tag_slices: [storage.config.max_tags][]const u8 = undefined;
        const tags = work.tags.slices(&tag_slices);

        const put = self.store.put(
            work.account_id,
            work.name(),
            in.body,
            work.content_type,
            tags,
            work.ttl_s,
        ) catch |err| {
            // A failed write costs nothing, and leaves no reservation behind to 409 against.
            if (work.credit_taken) self.control.refundCredit(work.account_id);
            if (work.key) |k| self.idempotency.abandon(k);
            out.fail(api.errors.fromStore(err));
            return;
        };

        // The outcome becomes replayable only now that it is durable — `put` returns after
        // the record is flushed, so a replay can never describe a write that did not land.
        const status: u16 = if (put.created) 201 else 200;
        if (work.key) |k| self.idempotency.complete(k, put.loc, status);

        self.finishWrite(out, .{
            .assigned = work.assigned,
            .status = status,
            .name = work.name(),
            .tags = tags,
            .content_type = work.content_type,
            .size = in.body.len,
            .created_at = put.expires_at -| work.ttl_s,
            .expires_at = put.expires_at,
            .credits_remaining = self.control.creditsRemaining(work.account_id),
            .replayed = false,
        });
    }

    const Written = struct {
        assigned: bool,
        status: u16,
        name: []const u8,
        tags: []const []const u8,
        content_type: []const u8,
        size: u64,
        created_at: u32,
        expires_at: u32,
        credits_remaining: u32,
        replayed: bool,
    };

    /// The response shared by a write and a replay of one.
    fn finishWrite(_: *Service, out: *Reply, w: Written) void {
        var body = json.Writer.init(out.out);
        writeMetadata(&body, .{
            .name = w.name,
            .tags = w.tags,
            .content_type = w.content_type,
            .size = w.size,
            .created_at = w.created_at,
            .expires_at = w.expires_at,
        }) catch return out.fail(.internal_error);

        out.ok(w.status, if (w.status == 201) "Created" else "OK");
        out.header("Content-Type", "application/json");

        if (w.assigned) {
            // The assigned name, so a caller who did not choose one can find it without
            // parsing the body.
            var location: [16 + api.ulid.len]u8 = undefined;
            const text = std.fmt.bufPrint(&location, "/v1/entries/{s}", .{w.name}) catch
                return out.fail(.internal_error);
            out.headerCopy("Location", text);
        }
        // Writes are the billable event, so the wall is never a surprise (`01-product.md`).
        out.headerInt("X-Doot-Credits-Remaining", w.credits_remaining);
        if (w.replayed) out.header("Idempotency-Replayed", "true");

        out.body = body.done();
    }

    /// Fills `out` from a recorded outcome. Returns false when it can no longer be read.
    ///
    /// The metadata comes from the record the original write produced, read at the location
    /// the idempotency table kept (D61) — so it is what the first response said, not what
    /// the entry has since become.
    fn replayInto(self: *Service, out: *Reply, work: *const WriteWork, r: idempotency.Replay) bool {
        // A buffer of our own, not `out.out` (D67). `out.out` is the slot's tail, which only
        // holds a whole record while the request body is under ~3 KB — so using it made
        // every larger replay re-execute, charge a credit, and overwrite the entry, which is
        // the opposite of what an idempotency key is for. A claim cannot fail: one job per
        // worker, one buffer per worker.
        const claim = self.replays.acquire() orelse return false;
        defer self.replays.release(claim.index);
        const buf = claim.buffer;

        const found = self.store.readAt(work.account_id, r.location, buf) catch return false;
        const got = found orelse return false;

        // Rendered into scratch rather than the read buffer, which is currently holding the
        // record the metadata is being read out of.
        var scratch: [1024]u8 = undefined;
        var body = json.Writer.init(&scratch);
        writeMetadataOf(&body, got) catch return false;
        const rendered = out.dupe(body.done()) orelse return false;

        out.ok(r.status, if (r.status == 201) "Created" else "OK");
        out.header("Content-Type", "application/json");
        if (work.assigned) {
            // Whether to emit `Location` follows the request being made rather than the one
            // recorded: a `POST` caller has no other way to learn the name.
            var location: [16 + storage.config.max_name_bytes]u8 = undefined;
            const text = std.fmt.bufPrint(&location, "/v1/entries/{s}", .{got.name}) catch
                return false;
            out.headerCopy("Location", text);
        }
        out.headerInt("X-Doot-Credits-Remaining", work.credits_remaining);
        out.header("Idempotency-Replayed", "true");
        out.body = rendered;
        return true;
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
            var tags: [storage.config.max_tags][]const u8 = undefined;
            for (rec.tags, 0..) |t, i| tags[i] = t.text;
            try writeMetadata(self.w, .{
                .name = rec.name,
                .tags = tags[0..rec.tags.len],
                .content_type = rec.content_type,
                .size = rec.body.len,
                .created_at = rec.created_at,
                .expires_at = rec.expires_at,
            });
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
// The metadata document (D60)
// ---------------------------------------------------------------------------

/// One entry, described. The body of a write and one element of a listing.
pub const Metadata = struct {
    name: []const u8,
    tags: []const []const u8,
    content_type: []const u8,
    size: u64,
    created_at: u32,
    expires_at: u32,
};

/// The single renderer for `02-api.md`'s Metadata shape.
///
/// One function on purpose. D60's whole point is that a write and a listing describe an
/// entry identically, and two renderers would be two places for that to stop being true.
fn writeMetadata(w: *json.Writer, m: Metadata) json.Error!void {
    var created: [server.response.timestamp_len]u8 = undefined;
    var expires: [server.response.timestamp_len]u8 = undefined;

    try w.beginObject();
    try w.stringMember("name", m.name);
    try w.key("tags");
    try w.beginArray();
    for (m.tags) |t| try w.string(t);
    try w.endArray();
    try w.stringMember("content_type", m.content_type);
    try w.numberMember("size", m.size);
    try w.stringMember("created_at", server.response.timestamp(m.created_at, &created));
    try w.stringMember("expires_at", server.response.timestamp(m.expires_at, &expires));
    try w.endObject();
}

/// The same document, from a record read back off disk.
fn writeMetadataOf(w: *json.Writer, got: storage.store.Got) json.Error!void {
    return writeMetadata(w, .{
        .name = got.name,
        .tags = got.tags(),
        .content_type = got.content_type,
        .size = got.body.len,
        .created_at = got.created_at,
        .expires_at = got.expires_at,
    });
}

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
    // Forces semantic analysis of every declaration reachable from `Service`, and it is here
    // for a specific reason rather than as tidiness.
    //
    // Zig analyses lazily: a function nothing references is never type-checked. No unit test
    // drives `Service.respond` — the endpoints are exercised over HTTP by the `curl` harnesses
    // instead — so **the handler bodies were invisible to `zig build test` entirely.** A
    // three-argument call to a two-argument function sat in the control plane and the whole
    // test suite passed; only `zig build`, which reaches `respond` through `main.zig`, caught
    // it. Referencing them here means the test binary type-checks them too, so a mistake
    // surfaces in the fast check rather than the slow one.
    // Not the recursive form: that walks every declaration of `storage`, `control`, `api` and
    // `server` too, and the analysis does not finish in any useful time. The non-recursive one
    // reaches `handler`, which references `respond`, which reaches every handler — which is
    // exactly the surface that was going unchecked.
    std.testing.refAllDecls(Service);

    _ = router;
    _ = query;
    _ = json;
    _ = ids;
    _ = idempotency;
    _ = password;
    _ = ratelimit;
    _ = challenge;
    _ = mail;
    _ = github;
}


// ---------------------------------------------------------------------------
// Replay buffers (D67)
// ---------------------------------------------------------------------------

const testing = std.testing;

test "a replay buffer is large enough for the largest record that can exist" {
    // The whole point of D67: `Reply.out` is the slot's *tail*, which is only this large
    // while the request body is under about 3 KB. These are not.
    try testing.expect(storage.store.read_buffer_bytes >= storage.config.max_body_bytes);
    const one = @sizeOf(@TypeOf(@as(ReplayBuffers, undefined).buffers[0]));
    try testing.expectEqual(@as(usize, storage.store.read_buffer_bytes), one);
}

test "there is one buffer per I/O worker, so a claim can never fail" {
    const buffers = try testing.allocator.create(ReplayBuffers);
    defer testing.allocator.destroy(buffers);
    buffers.init();

    var claims: [server.config.io_workers]ReplayBuffers.Claim = undefined;
    for (&claims) |*c| {
        c.* = buffers.acquire() orelse return error.ClaimFailed;
    }

    // Every worker holding one at once is the worst case, and it is exactly covered.
    try testing.expectEqual(@as(usize, server.config.io_workers), claims.len);

    // One more than there are workers cannot be satisfied — which is fine, because no
    // ninth job can exist, and the caller degrades to re-executing rather than misbehaving.
    try testing.expect(buffers.acquire() == null);

    for (claims) |c| buffers.release(c.index);
    // All released, so the pool is whole again.
    const again = buffers.acquire() orelse return error.ClaimFailed;
    try testing.expectEqual(@as(u5, 0), again.index);
    buffers.release(again.index);
}

test "claims are exclusive: no two hold the same bytes" {
    const buffers = try testing.allocator.create(ReplayBuffers);
    defer testing.allocator.destroy(buffers);
    buffers.init();

    const a = buffers.acquire() orelse return error.ClaimFailed;
    const b = buffers.acquire() orelse return error.ClaimFailed;
    try testing.expect(a.index != b.index);
    try testing.expect(a.buffer.ptr != b.buffer.ptr);
    // Non-overlapping, not merely different: a replay writes a whole record into this.
    const a_end = @intFromPtr(a.buffer.ptr) + a.buffer.len;
    const b_start = @intFromPtr(b.buffer.ptr);
    try testing.expect(a_end <= b_start or @intFromPtr(b.buffer.ptr) + b.buffer.len <= @intFromPtr(a.buffer.ptr));

    buffers.release(a.index);
    buffers.release(b.index);
}

test "a released buffer is reused rather than leaked" {
    const buffers = try testing.allocator.create(ReplayBuffers);
    defer testing.allocator.destroy(buffers);
    buffers.init();

    // Many more acquire/release cycles than there are buffers, which is what a long-lived
    // process does. A leak would exhaust the pool and start returning null.
    for (0..1000) |_| {
        const c = buffers.acquire() orelse return error.ClaimFailed;
        buffers.release(c.index);
    }
    try testing.expect(buffers.acquire() != null);
}

test "concurrent claims never hand out the same buffer" {
    const buffers = try testing.allocator.create(ReplayBuffers);
    defer testing.allocator.destroy(buffers);
    buffers.init();

    // The property that matters on the I/O worker pool: two threads claiming at once must
    // not both be given the same bytes to read a record into.
    const Worker = struct {
        buffers: *ReplayBuffers,
        seen: [server.config.io_workers]std.atomic.Value(u32),
        collisions: std.atomic.Value(u32) = .init(0),

        fn run(self: *@This()) void {
            for (0..2000) |_| {
                const c = self.buffers.acquire() orelse continue;
                // While held, mark it. Anyone else marking the same slot is a collision.
                const before = self.seen[c.index].fetchAdd(1, .acq_rel);
                if (before != 0) _ = self.collisions.fetchAdd(1, .monotonic);
                std.atomic.spinLoopHint();
                _ = self.seen[c.index].fetchSub(1, .acq_rel);
                self.buffers.release(c.index);
            }
        }
    };

    const w = try testing.allocator.create(Worker);
    defer testing.allocator.destroy(w);
    w.* = .{ .buffers = buffers, .seen = undefined };
    for (&w.seen) |*s| s.* = .init(0);

    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Worker.run, .{w});
    for (threads) |t| t.join();

    try testing.expectEqual(@as(u32, 0), w.collisions.load(.monotonic));
    // And the pool is not left claimed by a thread that exited.
    try testing.expectEqual(@as(u32, 0), buffers.claimed.load(.acquire));
}
