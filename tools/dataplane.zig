//! Data-plane harness (M2 Pass 2).
//!
//! The real `Service` behind the real event loop, over a real `Store` and `Control`, so an
//! HTTP client we did not write can exercise all seven endpoints end to end.
//!
//! Fixtures are still seeded through `Store.put` rather than over HTTP, and now for a better
//! reason than the write path not existing: it keeps the read, list, delete and isolation
//! checks independent of whether the write path is correct. A write bug should fail the
//! write checks, not make every read check fail for the wrong reason. It also places another
//! account's entries without authenticating as that account.
//!
//! **This is a fixture, not a server.** It hardcodes its API keys and prints them to stdout.
//! The deployable binary is `src/main.zig` (D63).
//!
//!   dataplane [listen-addr] [workdir]
//!
//! Prints the bound address and the API key it issued, so a caller can find both. The
//! workdir is created if absent and is left in place, so a run can be inspected afterwards.

const std = @import("std");
const storage = @import("storage");
const control = @import("control");
const service = @import("service");
const server = @import("server");

const os = storage.os;

/// Fixed so the check script can hardcode it. A real key is 190 bits from the CSPRNG
/// (`06-auth.md`); this one is a fixture and is labelled as such.
const trial_key = "doot_live_harness_trial_0000000000";
const paid_key = "doot_live_harness_paid_00000000000";
/// A second account, so cross-account isolation can actually be tested.
const other_key = "doot_live_harness_other_0000000000";
/// A third, used only for exhausting a bucket — so the rate-limit check starts from a full
/// one and does not have to reason about what the checks before it already spent.
const rate_key = "doot_live_harness_rate_00000000000";
/// A fourth with no credits at all, so `402` is reachable without spending ten thousand.
const broke_key = "doot_live_harness_broke_0000000000";
/// A fifth with a *small* balance, so the exhaustion boundary is reachable under concurrency
/// without draining a ten-thousand-credit account one write at a time (D66).
const scarce_key = "doot_live_harness_scarce_000000000";

/// What `scarce_key` starts with. Small enough to exhaust concurrently, large enough that
/// "exactly this many succeeded" is a real partition rather than a coin toss.
const scarce_credits: u32 = 8;

/// Deterministic, so a cursor issued by one run is rejected by the next only because of
/// its account binding and age rather than because the secret moved.
const cursor_secret: [32]u8 = @splat(0x5A);

/// Where `--frozen-clock` stops time. A fixed instant, so `Date` and every timestamp the
/// harness emits are reproducible run to run.
///
/// There is deliberately no way to *advance* it. The obvious design — wrapping
/// `Service.handler()` with one that recognises an extra path — cannot work: the transport
/// hands a deferred job the **registered** handler's context (`runDeferred` in
/// `server/loop.zig`), so a decorating handler makes every deferred reply reinterpret the
/// wrong pointer. See the amendment on D66. Refill over the wire is not worth a second
/// listener in the harness to reach, and the refill arithmetic is already asserted
/// deterministically against a manual clock in `control/store.zig`'s own tests.
const frozen_instant: u32 = 1_788_134_400; // Mon, 31 Aug 2026 00:00:00 GMT

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    var args = init.minimal.args.iterate();
    _ = args.next();
    const addr = args.next() orelse "127.0.0.1:0";
    const workdir = args.next() orelse "/tmp/doot_dataplane";

    // Three levers the exactness checks need (D65, D66). Flags rather than positional
    // arguments, because they are rarely used and each one changes what the harness *is*.
    var index_bytes: u64 = 0;
    var frozen = false;
    var seed_fixtures = true;
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--index-bytes=")) {
            index_bytes = std.fmt.parseInt(u64, arg["--index-bytes=".len..], 10) catch {
                std.debug.print("dataplane: --index-bytes needs a number\n", .{});
                return 2;
            };
        } else if (std.mem.eql(u8, arg, "--frozen-clock")) {
            frozen = true;
        } else if (std.mem.eql(u8, arg, "--no-seed")) {
            seed_fixtures = false;
        } else {
            std.debug.print("dataplane: unknown argument '{s}'\n", .{arg});
            return 2;
        }
    }

    var wd_buf: [512]u8 = undefined;
    const wd = try std.fmt.bufPrintZ(&wd_buf, "{s}", .{workdir});
    os.mkdir(os.cwd, wd) catch {};
    const dir_fd = try os.openDir(os.cwd, wd);
    defer os.close(dir_fd);

    // A stopped clock is what makes the rate limit exactly assertable: refill is
    // `elapsed * rate` in whole seconds, so with `elapsed` pinned at zero no token can
    // ever accrue and a full bucket admits exactly `burst` requests (D66). The instant is
    // fixed so `Date` is reproducible too. `/frozen/advance?s=` moves it on demand, which
    // is how the refill *rate* becomes assertable without sleeping.
    var real = storage.clock.Real{};
    var manual: storage.clock.Manual = .init(frozen_instant);
    const clk = if (frozen) manual.clock() else real.clock();

    const store = try storage.Store.open(gpa, dir_fd, clk, .{ .max_index_bytes = index_bytes });
    defer store.close();

    const ctl = try control.Control.open(gpa, dir_fd, clk);
    defer ctl.close();

    // Idempotent across runs: a reopened CONTROL already has these, and issuing a
    // duplicate key would fail rather than silently shadow the first.
    const trial = ctl.resolveKey(trial_key) orelse blk: {
        const id = try ctl.createAccount("trial@example.com", .trial, .active, 10_000);
        _ = try ctl.issueKey(id, "harness-trial", trial_key);
        break :blk ctl.resolveKey(trial_key).?;
    };
    if (ctl.resolveKey(paid_key) == null) {
        const id = try ctl.createAccount("paid@example.com", .paid, .active, 50_000);
        _ = try ctl.issueKey(id, "harness-paid", paid_key);
    }
    const other = ctl.resolveKey(other_key) orelse blk: {
        const id = try ctl.createAccount("other@example.com", .trial, .active, 10_000);
        _ = try ctl.issueKey(id, "harness-other", other_key);
        break :blk ctl.resolveKey(other_key).?;
    };
    if (ctl.resolveKey(rate_key) == null) {
        const id = try ctl.createAccount("rate@example.com", .trial, .active, 10_000);
        _ = try ctl.issueKey(id, "harness-rate", rate_key);
    }
    if (ctl.resolveKey(broke_key) == null) {
        // Zero credits: writes are refused, and reads, lists and deletes keep working
        // (`01-product.md`).
        const id = try ctl.createAccount("broke@example.com", .trial, .active, 0);
        _ = try ctl.issueKey(id, "harness-broke", broke_key);
    }
    if (ctl.resolveKey(scarce_key) == null) {
        const id = try ctl.createAccount("scarce@example.com", .trial, .active, scarce_credits);
        _ = try ctl.issueKey(id, "harness-scarce", scarce_key);
    }

    // Skipped when the index budget is deliberately tiny: `seed` writes through
    // `Store.put`, which is exactly what a closed admission window refuses, so seeding
    // would fail before the harness could serve the `503` it was started to serve (D65).
    if (seed_fixtures) try seed(store, trial.account_id, other.account_id);

    // ~56 MB, so it is allocated once and borrowed rather than embedded (D62).
    const idem = try gpa.create(service.IdempotencyTable);
    defer gpa.destroy(idem);
    idem.init();

    // ~2 MB, one per I/O worker, so a replay of a large body has room to re-read its own
    // record (D67).
    const replays = try gpa.create(service.ReplayBuffers);
    defer gpa.destroy(replays);
    replays.init();

    var svc = service.Service.init(.{
        .store = store,
        .control = ctl,
        .clock = clk,
        .cursor_secret = cursor_secret,
        .max_ttl_s = (storage.config.Options{}).max_ttl_s,
        .idempotency = idem,
        .replays = replays,
    });

    const loop = server.Loop.init(gpa, .{
        .address = addr,
        .handler = svc.handler(),
        .clock = clk,
    }) catch |err| {
        std.debug.print("dataplane: cannot listen on {s}: {s}\n", .{ addr, @errorName(err) });
        return 1;
    };
    defer loop.deinit(gpa);

    std.debug.print("dataplane: listening 127.0.0.1:{d}\n", .{try loop.port()});
    std.debug.print("dataplane: trial_key {s}\n", .{trial_key});
    std.debug.print("dataplane: paid_key {s}\n", .{paid_key});
    std.debug.print("dataplane: other_key {s}\n", .{other_key});
    std.debug.print("dataplane: rate_key {s}\n", .{rate_key});
    std.debug.print("dataplane: broke_key {s}\n", .{broke_key});
    std.debug.print("dataplane: scarce_key {s} ({d} credits)\n", .{ scarce_key, scarce_credits });

    try loop.run();
    return 0;
}

/// Fixture entries, written through the engine so that the read, list, delete and isolation
/// checks do not depend on the write path being correct.
fn seed(store: *storage.Store, account_id: u32, other_id: u32) !void {
    const day = 24 * 60 * 60;

    // A plain entry with tags, for read and for list.
    _ = try store.put(account_id, "ci/last-green-sha", "deadbeefcafe\n", "text/plain", &.{ "ci", "main" }, 7 * day);
    // JSON, so content-type passthrough is visible.
    _ = try store.put(account_id, "agent/scratch/step-3", "{\"observation\":\"tool returned 404\"}", "application/json", &.{ "agent", "scratch" }, 2 * day);
    // An empty body is a valid entry — a lock or a flag (`03-data-model.md`).
    _ = try store.put(account_id, "locks/deploy", "", "application/octet-stream", &.{"ci"}, day);
    // A name with characters that must survive JSON escaping and header emission.
    _ = try store.put(account_id, "odd/name\"with'quotes", "quoted\n", "text/plain", &.{"odd"}, day);
    // No tags at all, which must not produce an `X-Doot-Tags` header.
    _ = try store.put(account_id, "untagged", "no tags here\n", "text/plain", &.{}, day);
    // A target for DELETE, so the other fixtures survive a check run.
    _ = try store.put(account_id, "doomed", "delete me\n", "text/plain", &.{"ci"}, day);

    // Enough on one tag to page over, with a limit below the count.
    var name_buf: [64]u8 = undefined;
    for (0..12) |i| {
        const name = try std.fmt.bufPrint(&name_buf, "page/{d:0>3}", .{i});
        _ = try store.put(account_id, name, "paged\n", "text/plain", &.{"paged"}, day);
    }

    // Another account's entry, under the same name and the same tag as one of ours. If
    // isolation is broken, these are what show up where they should not.
    _ = try store.put(other_id, "ci/last-green-sha", "NOT YOURS\n", "text/plain", &.{ "ci", "main" }, day);
    _ = try store.put(other_id, "secret", "NOT YOURS\n", "text/plain", &.{"ci"}, day);
}
