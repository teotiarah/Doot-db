//! Doot's origin binary.
//!
//! A composition root and nothing else (D63). It reads configuration, opens the control log
//! and the store, allocates the idempotency table, constructs the service, starts the
//! maintenance thread, runs the event loop, and takes it all down in reverse order.
//!
//! **There is deliberately no logic here.** Every decision this file appears to make lives
//! in `src/boot.zig`, which has tests, because this file cannot have any: it is one function
//! whose behaviour is the composition itself. If logic starts to accumulate here, that is
//! the signal a module is missing — not that the binary needs a test.
//!
//! What it deliberately does not do:
//!
//!   - **Create accounts directly.** Signup does it, over HTTP, which is what closed D63's
//!     one recorded open question. There is still no operator subcommand, because there is
//!     no longer anything for one to do.
//!   - **Log requests.** Boot and lifecycle diagnostics only; the structured per-request log
//!     carries a redaction contract and belongs to M5.
//!   - **Serve TLS.** The origin sits behind Cloudflare and the edge half of M2 is what
//!     stands that up.
//!
//! Specification: `docs/05-architecture.md`. Decisions: `docs/07-decisions.md` D63.

const std = @import("std");
const storage = @import("storage");
const control = @import("control");
const server = @import("server");
const service = @import("service");
const boot = @import("boot");

const os = storage.os;

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;

    // ---- configuration, before anything is opened or created ----
    //
    // First, so that a typo costs nothing. Nothing below this point is cheap to undo.
    const cfg = boot.Config.fromEnv(init.environ_map) catch |err| {
        boot.fatal("configuration", boot.describe(err));
        return 1;
    };

    // ---- signals, before any thread exists ----
    //
    // Blocked here so that the worker pool `Loop.init` starts, and the maintenance thread,
    // both inherit the mask. Only the thread that unblocks — this one — can then receive a
    // shutdown signal, so one cannot land on a worker mid-`fsync` (D63).
    boot.blockShutdownSignals();

    var wall: storage.clock.Real = .{};
    const clk = wall.clock();

    // ---- the data directory, and the two logs inside it ----

    os.mkdir(os.cwd, cfg.dataDir()) catch |err| {
        boot.fatalError("data directory", err);
        return 1;
    };
    const dir_fd = os.openDir(os.cwd, cfg.dataDir()) catch |err| {
        boot.fatalError("data directory", err);
        return 1;
    };
    // Every `defer` from here down runs in reverse order of registration, which *is* the
    // shutdown order D63 specifies. The sequence is load-bearing, not incidental:
    // maintenance stops, the loop stops its workers, then the control log and the store
    // close, then the directory. Reordering these declarations reorders the shutdown.
    defer os.close(dir_fd);

    const store = storage.Store.open(gpa, dir_fd, clk, cfg.options) catch |err| {
        boot.fatalError("store", err);
        return 1;
    };
    // Closing the store is what writes its final snapshot.
    defer store.close();

    const ctl = control.Control.open(gpa, dir_fd, clk) catch |err| {
        boot.fatalError("control log", err);
        return 1;
    };
    // Closing the control log is what checkpoints credit balances, which is the whole
    // reason a graceful shutdown has to exist rather than being a nicety (D41).
    defer ctl.close();

    // ---- the service ----

    // ~56 MB, so it is allocated once and borrowed rather than embedded (D62).
    const idem = gpa.create(service.IdempotencyTable) catch |err| {
        boot.fatalError("idempotency table", err);
        return 1;
    };
    defer gpa.destroy(idem);
    // Not field-by-field: the embedded mutex would be left holding garbage.
    idem.init();

    // ~2 MB, one record-sized buffer per I/O worker, so a replay has somewhere to re-read
    // the record it is reproducing (D67).
    const replays = gpa.create(service.ReplayBuffers) catch |err| {
        boot.fatalError("replay buffers", err);
        return 1;
    };
    defer gpa.destroy(replays);
    replays.init();

    // ---- the control plane (M3) ----
    //
    // Heap-allocated for the same reason the idempotency table is: a `Service` is copied by
    // value into a handler vtable, and none of these belong in it.

    const challenges = gpa.create(service.challenge.Table) catch |err| {
        boot.fatalError("challenge table", err);
        return 1;
    };
    defer gpa.destroy(challenges);
    challenges.* = service.challenge.Table.init() catch |err| {
        boot.fatalError("challenge table", err);
        return 1;
    };

    const unauth = gpa.create(service.ratelimit.Unauthenticated) catch |err| {
        boot.fatalError("rate limiter", err);
        return 1;
    };
    defer gpa.destroy(unauth);
    unauth.* = service.ratelimit.Unauthenticated.init() catch |err| {
        boot.fatalError("rate limiter", err);
        return 1;
    };

    // Generated, never hardcoded: a constant in our source is a constant an attacker
    // recognises, which is the reasoning D63 applied to a default signing secret (D75).
    const dummy = gpa.create(service.password.Dummy) catch |err| {
        boot.fatalError("password hasher", err);
        return 1;
    };
    defer gpa.destroy(dummy);
    dummy.* = service.password.Dummy.init(gpa) catch |err| {
        boot.fatalError("password hasher", err);
        return 1;
    };

    const queue = gpa.create(service.mail.Queue) catch |err| {
        boot.fatalError("mail queue", err);
        return 1;
    };
    defer gpa.destroy(queue);
    queue.* = .{};

    // Derived state, rebuilt from the control log rather than stored in it: the normalisation
    // login needs lives in `api`, which `control` may not import (D72).
    const emails = gpa.create(service.app.EmailIndex) catch |err| {
        boot.fatalError("email index", err);
        return 1;
    };
    defer gpa.destroy(emails);
    emails.* = service.app.EmailIndex.init(gpa);
    defer emails.deinit();
    emails.rebuild(ctl);

    // Tens of kilobytes, and the frame buffers cost nothing: a parked stream builds frames in
    // the idle read buffer it already has (D86).
    const subs = gpa.create(service.app.Subscribers) catch |err| {
        boot.fatalError("subscriber table", err);
        return 1;
    };
    defer gpa.destroy(subs);
    subs.* = .{};

    var app_state: service.app.State = .{
        .gpa = gpa,
        .cfg = .{
            .public_origin = cfg.app.public_origin,
            .support_email = cfg.app.support_email,
            .github_client_id = cfg.app.github_client_id,
            .github_client_secret = cfg.app.github_client_secret,
            .zeptomail_token = cfg.app.zeptomail_token,
        },
        .challenges = challenges,
        .unauth = unauth,
        .dummy = dummy,
        .queue = queue,
        .emails = emails,
        .subscribers = subs,
    };

    var svc = service.Service.init(.{
        .store = store,
        .control = ctl,
        .clock = clk,
        .cursor_secret = cfg.hmac_secret,
        // The engine ceiling every plan maximum is clamped against (D56).
        .max_ttl_s = cfg.options.max_ttl_s,
        .idempotency = idem,
        .replays = replays,
        .app = &app_state,
    });

    // ---- maintenance, and the loop that wakes it ----

    // Its own thread, not maintenance's: maintenance blocks on local disk for a bounded time
    // and this blocks on a third party for an unbounded one, so sharing would let a slow mail
    // provider stop snapshots (D78).
    var sender: service.mail.Sender = .{
        .gpa = gpa,
        .queue = queue,
        .cfg = app_state.cfg.mailConfig(),
        .clock = clk,
    };

    var maint: boot.Maintenance = .{ .store = store, .ctl = ctl, .clock = clk };

    const loop = server.Loop.init(gpa, .{
        .address = cfg.listen_addr,
        .handler = svc.handler(),
        .stream = svc.streamSeam(),
        .clock = clk,
        .tick = maint.tick(),
    }) catch |err| {
        boot.fatalError("listener", err);
        return 1;
    };
    defer loop.deinit(gpa);

    maint.start() catch |err| {
        boot.fatalError("maintenance thread", err);
        return 1;
    };
    defer maint.stop();

    // Started after the loop so it inherits the blocked signal mask, exactly as the
    // maintenance thread does: a thread mid-TLS-handshake is no better a place to take a
    // SIGTERM than one mid-fsync (D63).
    sender.start() catch |err| {
        boot.fatalError("mail thread", err);
        return 1;
    };
    defer sender.stop();

    // ---- run ----

    const st = store.stats();
    boot.info("listening on {s}", .{cfg.listen_addr});
    boot.info("data directory {s}", .{cfg.dataDir()});
    boot.info(
        "recovered {d} record(s) in {d} ms, seq {d}",
        .{ st.recovery_records, st.recovery_ms, store.lastSeq() },
    );
    if (st.corruptions > 0) {
        boot.info("WARNING: {d} record(s) failed checksum during recovery", .{st.corruptions});
    }

    // Installed last, so a signal arriving during startup cannot find a half-built process,
    // and unblocked only now that every other thread exists.
    boot.armShutdown(loop);

    loop.run() catch |err| {
        boot.fatalError("event loop", err);
        return 1;
    };

    boot.info("stopping", .{});
    return 0;
}
