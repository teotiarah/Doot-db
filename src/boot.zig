//! Doot's process layer.
//!
//! What turns an environment and a signal into a running, stoppable Doot. Everything about
//! being a long-lived Unix process that the layers below deliberately know nothing about:
//! configuration read from the environment (D24), the maintenance thread D45 locked, the
//! shutdown signals, and the reporting a process does before it has a request to log.
//!
//! `src/main.zig` is a composition root and holds no logic (D63). This module is where the
//! logic went instead, for one reason: it can be tested, and a `main.zig` cannot. If
//! something here stops being testable it is a sign it belongs in a layer below.
//!
//! It is **not** a constants file. Every limit it applies comes from `storage.config` or
//! `server.config`, which are the two mirrors working rule 2 allows.
//!
//! Specification: `docs/05-architecture.md` (process model, configuration, deployment).
//! Decisions: `docs/07-decisions.md` D63 (this module, and the binary's scope), D24
//! (environment only), D45 (maintenance is a thread), D41 (a clean close is what makes
//! credit balances exact), D47 (the lifetime grammar `DOOT_MAX_TTL` reuses), D43 (the index
//! hash key is the store's, never the environment's).

const std = @import("std");
const storage = @import("storage");
const control = @import("control");
const api = @import("api");
const server = @import("server");

const os = storage.os;

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

/// Why every one of these is distinct rather than a single `error.BadConfig`: the whole
/// point of failing at boot is telling the operator which line of the unit file is wrong.
pub const Error = error{
    ListenAddrMissing,
    ListenAddrInvalid,
    DataDirMissing,
    DataDirTooLong,
    MaxIndexBytesMissing,
    MaxIndexBytesInvalid,
    HmacSecretMissing,
    HmacSecretInvalid,
    MaxTtlInvalid,
    MaxTtlTooShort,
    SegmentBytesInvalid,
    SnapshotIntervalInvalid,
};

/// `DOOT_HMAC_SECRET` is exactly this many characters, and they are lowercase hex (D63).
///
/// Fixed length and one encoding, so a truncated paste is refused rather than silently
/// becoming a shorter secret — which is the failure a "whatever bytes you typed" reading
/// would hide.
pub const hmac_secret_hex_len: usize = 64;

pub const Config = struct {
    /// Borrowed from the environment, which outlives the process's run: `std.process.Init`
    /// owns the map and frees it at exit. Not copied, because `server.Loop` only needs to
    /// read it and a second buffer would be a second thing to size.
    listen_addr: []const u8,

    /// Copied, because `os.openDir` needs a NUL terminator that an environment string does
    /// not promise. `dataDir()` is computed from the buffer rather than stored as a slice,
    /// so a copy of a `Config` is still valid — the self-referential-pointer bug M1 found
    /// the hard way is not available here.
    data_dir_buf: [std.fs.max_path_bytes]u8,
    data_dir_len: u16,

    /// Signs pagination cursors (D46).
    hmac_secret: [32]u8,

    /// Everything the engine is configured with. Defaults are `04-storage.md`'s, mirrored
    /// in `storage.config.Options` — this fills in only what the environment overrides.
    ///
    /// `index_hash_key` is deliberately left at its default: `Store.open` replaces it with
    /// the key from the `STORE` file, and D43 is the decision that it must never come from
    /// the environment at all.
    options: storage.config.Options,

    pub fn dataDir(self: *const Config) [:0]const u8 {
        return self.data_dir_buf[0..self.data_dir_len :0];
    }

    /// Reads and validates the whole environment, or fails naming the variable at fault.
    ///
    /// A variable is required by the milestone that gains the code reading it (D63), so the
    /// R2, GitHub, mail and admin variables `05-architecture.md` lists are absent here on
    /// purpose: requiring them now would refuse to start over subsystems that do not exist.
    pub fn fromEnv(env: *const std.process.Environ.Map) Error!Config {
        var self: Config = .{
            .listen_addr = "",
            .data_dir_buf = undefined,
            .data_dir_len = 0,
            .hmac_secret = @splat(0),
            .options = .{},
        };

        // -- required --

        const addr = env.get("DOOT_LISTEN_ADDR") orelse return error.ListenAddrMissing;
        if (addr.len == 0) return error.ListenAddrMissing;
        // Parsed here so a typo is a boot failure rather than an error out of `Loop.init`
        // after the store has already been opened and recovered.
        _ = server.net.parseAddress(addr) catch return error.ListenAddrInvalid;
        self.listen_addr = addr;

        const dir = env.get("DOOT_DATA_DIR") orelse return error.DataDirMissing;
        if (dir.len == 0) return error.DataDirMissing;
        if (dir.len >= self.data_dir_buf.len) return error.DataDirTooLong;
        @memcpy(self.data_dir_buf[0..dir.len], dir);
        self.data_dir_buf[dir.len] = 0;
        self.data_dir_len = @intCast(dir.len);

        // Required rather than defaulted: without a ceiling the index has no admission
        // control, and a store that silently never refuses a write is D43's hazard in a
        // different costume.
        const idx = env.get("DOOT_MAX_INDEX_BYTES") orelse return error.MaxIndexBytesMissing;
        self.options.max_index_bytes = std.fmt.parseInt(u64, idx, 10) catch
            return error.MaxIndexBytesInvalid;
        if (self.options.max_index_bytes == 0) return error.MaxIndexBytesInvalid;

        const secret = env.get("DOOT_HMAC_SECRET") orelse return error.HmacSecretMissing;
        self.hmac_secret = try parseHmacSecret(secret);

        // -- optional, defaulting to the engine's own constants --

        if (env.get("DOOT_MAX_TTL")) |text| {
            // The same grammar as `X-Doot-TTL` (D47), through the same parser. Two lifetime
            // grammars in one product is a trap, and the operator-facing one should be the
            // one already documented.
            self.options.max_ttl_s = api.parse.ttl(text) catch return error.MaxTtlInvalid;
        }

        if (env.get("DOOT_SEGMENT_BYTES")) |text| {
            self.options.segment_bytes = std.fmt.parseInt(u32, text, 10) catch
                return error.SegmentBytesInvalid;
        }

        if (env.get("DOOT_SNAPSHOT_INTERVAL_S")) |text| {
            self.options.snapshot_interval_s = std.fmt.parseInt(u32, text, 10) catch
                return error.SnapshotIntervalInvalid;
            // Zero would make every `maintain()` write a snapshot, which is a busy loop
            // against the disk rather than a configuration.
            if (self.options.snapshot_interval_s == 0) return error.SnapshotIntervalInvalid;
        }

        // The engine's own invariants, applied here so that a bad combination is a named
        // boot failure instead of an error surfacing from `Store.open`. D47 deliberately
        // range-checks nothing, so the lifetime floor is enforced at this point.
        self.options.validate() catch |err| return switch (err) {
            error.SegmentTooLarge, error.SegmentTooSmall => error.SegmentBytesInvalid,
            error.MaxTtlTooSmall => error.MaxTtlTooShort,
        };

        return self;
    }
};

fn parseHmacSecret(text: []const u8) Error![32]u8 {
    if (text.len != hmac_secret_hex_len) return error.HmacSecretInvalid;
    var out: [32]u8 = undefined;
    for (&out, 0..) |*b, i| {
        const hi = hexDigit(text[i * 2]) orelse return error.HmacSecretInvalid;
        const lo = hexDigit(text[i * 2 + 1]) orelse return error.HmacSecretInvalid;
        b.* = (hi << 4) | lo;
    }
    return out;
}

/// Lowercase only, deliberately. One spelling of a secret means an operator who copies it
/// between two places cannot end up with two different secrets that both look right.
fn hexDigit(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        else => null,
    };
}

/// The operator-facing text for a configuration failure.
///
/// Here rather than in `main.zig` so that the messages are covered by the same tests as the
/// parsing, and so `main.zig` stays a composition root (D63).
pub fn describe(err: Error) []const u8 {
    return switch (err) {
        error.ListenAddrMissing => "DOOT_LISTEN_ADDR is required, for example 0.0.0.0:8080",
        error.ListenAddrInvalid => "DOOT_LISTEN_ADDR is not an address:port",
        error.DataDirMissing => "DOOT_DATA_DIR is required",
        error.DataDirTooLong => "DOOT_DATA_DIR is longer than the platform's path limit",
        error.MaxIndexBytesMissing => "DOOT_MAX_INDEX_BYTES is required and has no default: without it the index has no ceiling and admission control never engages",
        error.MaxIndexBytesInvalid => "DOOT_MAX_INDEX_BYTES must be a positive number of bytes",
        error.HmacSecretMissing => "DOOT_HMAC_SECRET is required and is never defaulted",
        error.HmacSecretInvalid => "DOOT_HMAC_SECRET must be exactly 64 lowercase hex characters, as produced by: openssl rand -hex 32",
        error.MaxTtlInvalid => "DOOT_MAX_TTL must be digits with an optional s, m, h or d suffix, for example 30d",
        error.MaxTtlTooShort => "DOOT_MAX_TTL is below the minimum lifetime an entry may be given",
        error.SegmentBytesInvalid => "DOOT_SEGMENT_BYTES is outside the range the storage layout allows",
        error.SnapshotIntervalInvalid => "DOOT_SNAPSHOT_INTERVAL_S must be a positive number of seconds",
    };
}

// ---------------------------------------------------------------------------
// The maintenance thread (D45)
// ---------------------------------------------------------------------------

/// Runs `Store.maintain()` and `Control.maintain()` off the request path.
///
/// This exists because without it nothing sweeps expired index slots, nothing reclaims
/// segments, and — most consequentially — **nothing ever snapshots**, because `maintain()`
/// is the only production path to `Store.snapshot()`. A process with no maintenance thread
/// grows without bound and makes recovery replay the entire log, which is exactly the bound
/// D38 says recovery has. D45 locked the thread; D63 is where it acquired a caller.
///
/// It does not own a timer. The event loop's tick wakes it once a second and it decides
/// whether the interval has elapsed (D45), which means the same wake-up serves shutdown and
/// no timed wait is needed anywhere.
pub const Maintenance = struct {
    store: *storage.Store,
    ctl: *control.Control,
    clock: storage.clock.Clock,

    /// `server.config`'s constant, overridable only so a test does not have to wait a
    /// minute to observe one pass.
    interval_s: u32 = server.config.maintenance_interval_s,
    /// Silenced by tests, which would otherwise print on every pass.
    log: bool = true,

    thread: ?std.Thread = null,

    /// A counter rather than a flag, for the reason `server/pool.zig` explains: the value a
    /// thread observed *before* checking whether work is due is what makes parking safe. A
    /// wake landing in between moves the counter, so `futexWait` returns at once instead of
    /// sleeping through a shutdown.
    signal: std.atomic.Value(u32) = .init(0),
    stopping: std.atomic.Value(bool) = .init(false),

    /// Touched only by the maintenance thread, or by a test calling `runDue` directly.
    last_run_s: u32 = 0,

    runs: std.atomic.Value(u32) = .init(0),
    store_failures: std.atomic.Value(u32) = .init(0),
    control_failures: std.atomic.Value(u32) = .init(0),

    pub fn start(self: *Maintenance) std.Thread.SpawnError!void {
        std.debug.assert(self.thread == null);
        // Measured from now, so the first pass is one interval away rather than immediate.
        // A sweep and a snapshot the instant recovery finishes is work nobody asked for.
        self.last_run_s = self.clock.now();
        self.stopping.store(false, .release);
        self.thread = try std.Thread.spawn(.{}, threadMain, .{self});
    }

    /// Asks the thread to finish and waits for it.
    ///
    /// Must happen before the store or the control log is closed, because a pass in flight
    /// is holding both.
    pub fn stop(self: *Maintenance) void {
        const t = self.thread orelse return;
        self.stopping.store(true, .release);
        self.wake();
        t.join();
        self.thread = null;
    }

    /// Wakes the thread. Cheap enough to call from the loop's tick: one atomic add and one
    /// futex wake, no allocation, no syscall that can block.
    pub fn wake(self: *Maintenance) void {
        _ = self.signal.fetchAdd(1, .release);
        os.futexWake(&self.signal, os.wake_all);
    }

    /// The seam the event loop calls once a second (D45).
    pub fn tick(self: *Maintenance) server.Tick {
        return .{ .ctx = self, .tickFn = onTick };
    }

    fn onTick(ctx: *anyopaque) void {
        const self: *Maintenance = @ptrCast(@alignCast(ctx));
        self.wake();
    }

    fn threadMain(self: *Maintenance) void {
        while (true) {
            const seen = self.signal.load(.acquire);
            if (self.stopping.load(.acquire)) return;
            self.runDue();
            os.futexWait(&self.signal, seen);
        }
    }

    /// Runs a pass if the interval has elapsed.
    ///
    /// Split out from the thread so a test can drive it with a manual clock and no thread at
    /// all, which is the only way the cadence itself is testable.
    pub fn runDue(self: *Maintenance) void {
        const now = self.clock.now();
        // Saturating, so a clock that moves backwards delays a pass rather than causing one
        // every tick — the same defence `Control.takeToken` applies to the rate bucket.
        if (now -| self.last_run_s < self.interval_s) return;
        self.last_run_s = now;
        self.runNow();
    }

    /// One pass over both maintainers.
    ///
    /// **A failure is counted and logged, never fatal** (D63). Expiry is authoritative at
    /// the index and evaluated lazily on every read, so a failed sweep is a deferred sweep
    /// that no caller can observe; a failed snapshot lengthens the next recovery, which D38
    /// already treats as an observable bound rather than a correctness property. Exiting
    /// would turn a recoverable and invisible condition into a total outage.
    pub fn runNow(self: *Maintenance) void {
        _ = self.runs.fetchAdd(1, .monotonic);

        if (self.store.maintain()) |m| {
            if (self.log and (m.snapshotted or m.segments_reclaimed > 0 or m.swept > 0)) {
                std.debug.print(
                    "doot: maintenance: swept {d}, segments reclaimed {d}, shards rebuilt {d}, snapshot {}\n",
                    .{ m.swept, m.segments_reclaimed, m.shards_rebuilt, m.snapshotted },
                );
            }
        } else |err| {
            _ = self.store_failures.fetchAdd(1, .monotonic);
            if (self.log) std.debug.print(
                "doot: maintenance: store.maintain failed: {s} (continuing)\n",
                .{@errorName(err)},
            );
        }

        if (self.ctl.maintain()) |m| {
            if (self.log and m.rewritten) {
                std.debug.print(
                    "doot: maintenance: control log rewritten, {d} balance(s) checkpointed\n",
                    .{m.checkpointed},
                );
            }
        } else |err| {
            _ = self.control_failures.fetchAdd(1, .monotonic);
            if (self.log) std.debug.print(
                "doot: maintenance: control.maintain failed: {s} (continuing)\n",
                .{@errorName(err)},
            );
        }
    }
};

// ---------------------------------------------------------------------------
// Shutdown signals
// ---------------------------------------------------------------------------

/// The loop a signal should stop, held as an integer because a signal handler takes no
/// context of its own.
///
/// Written once before the handler is installed and only read inside it, so the atomic is
/// about visibility across threads rather than contention.
var shutdown_target: std.atomic.Value(usize) = .init(0);

/// `SIGINT` as well as `SIGTERM`, so a foreground run stops the same way `systemd` stops it
/// — including the credits checkpoint. A shutdown path that only the service manager
/// exercises is a shutdown path nobody tests.
pub const shutdown_signals = [_]std.posix.SIG{ .TERM, .INT };

/// Blocks the shutdown signals in the calling thread.
///
/// **Must be called before any thread is created.** Signal *disposition* is per-process but
/// *delivery* is per-thread, and threads inherit the mask of their creator — so blocking
/// here and unblocking only in `armShutdown` is what guarantees a `SIGTERM` cannot land on
/// an I/O worker and return `EINTR` from the `fsync` it was inside (D63).
pub fn blockShutdownSignals() void {
    var set = std.os.linux.sigemptyset();
    for (shutdown_signals) |sig| std.os.linux.sigaddset(&set, sig);
    std.posix.sigprocmask(std.posix.SIG.BLOCK, &set, null);
}

/// Installs the handler, then unblocks the shutdown signals in the calling thread.
///
/// Call after every thread exists, so the loop's thread is the only one that can receive
/// one.
pub fn armShutdown(l: *server.Loop) void {
    shutdown_target.store(@intFromPtr(l), .release);

    var act: std.posix.Sigaction = .{
        .handler = .{ .handler = onShutdownSignal },
        .mask = std.os.linux.sigemptyset(),
        // No `SA_RESTART`, deliberately. The `EINTR` is the useful part: it breaks the loop
        // out of `submit_and_wait` at once rather than up to a tick later, and
        // `Loop.iterate` already treats `error.SignalInterrupt` as benign and returns.
        .flags = 0,
    };
    for (shutdown_signals) |sig| std.posix.sigaction(sig, &act, null);

    var set = std.os.linux.sigemptyset();
    for (shutdown_signals) |sig| std.os.linux.sigaddset(&set, sig);
    std.posix.sigprocmask(std.posix.SIG.UNBLOCK, &set, null);
}

/// Everything a handler is allowed to do, and all this one needs to: one atomic store,
/// inside `Loop.stop`, which is documented safe from exactly here.
fn onShutdownSignal(_: std.posix.SIG) callconv(.c) void {
    const addr = shutdown_target.load(.acquire);
    if (addr == 0) return;
    const l: *server.Loop = @ptrFromInt(addr);
    l.stop();
}

// ---------------------------------------------------------------------------
// Reporting
// ---------------------------------------------------------------------------

/// Boot and lifecycle diagnostics only.
///
/// The structured per-request JSON log `05-architecture.md` describes is M5's, because it
/// carries a redaction contract — no bodies, names, API keys or codes — that deserves its
/// own pass rather than riding along inside a lifecycle decision (D63).
pub fn fatal(stage: []const u8, detail: []const u8) void {
    std.debug.print("doot: cannot start: {s}: {s}\n", .{ stage, detail });
}

pub fn fatalError(stage: []const u8, err: anyerror) void {
    std.debug.print("doot: cannot start: {s}: {s}\n", .{ stage, @errorName(err) });
}

pub fn info(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("doot: " ++ fmt ++ "\n", args);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// The four M2 variables, as a starting point a test can then break one field of.
fn validEnv(gpa: std.mem.Allocator) !std.process.Environ.Map {
    var m: std.process.Environ.Map = .init(gpa);
    errdefer m.deinit();
    try m.put("DOOT_LISTEN_ADDR", "127.0.0.1:8080");
    try m.put("DOOT_DATA_DIR", "/var/lib/doot");
    try m.put("DOOT_MAX_INDEX_BYTES", "300000000");
    try m.put("DOOT_HMAC_SECRET", "0123456789abcdef" ** 4);
    return m;
}

test "a complete environment produces a usable configuration" {
    var m = try validEnv(testing.allocator);
    defer m.deinit();

    const cfg = try Config.fromEnv(&m);
    try testing.expectEqualStrings("127.0.0.1:8080", cfg.listen_addr);
    try testing.expectEqualStrings("/var/lib/doot", cfg.dataDir());
    try testing.expectEqual(@as(u64, 300_000_000), cfg.options.max_index_bytes);
    // Untouched, so the engine's defaults survive an environment that says nothing.
    try testing.expectEqual((storage.config.Options{}).max_ttl_s, cfg.options.max_ttl_s);
    try testing.expectEqual((storage.config.Options{}).segment_bytes, cfg.options.segment_bytes);
}

test "the data directory is NUL-terminated for openDir" {
    var m = try validEnv(testing.allocator);
    defer m.deinit();
    const cfg = try Config.fromEnv(&m);
    const dir = cfg.dataDir();
    try testing.expectEqual(@as(u8, 0), dir.ptr[dir.len]);
}

test "a Config survives being copied, because the accessor is computed" {
    var m = try validEnv(testing.allocator);
    defer m.deinit();
    const original = try Config.fromEnv(&m);
    const copy = original;
    try testing.expectEqualStrings("/var/lib/doot", copy.dataDir());
}

test "each required variable is required, and says which one it is" {
    inline for (.{
        .{ "DOOT_LISTEN_ADDR", Error.ListenAddrMissing },
        .{ "DOOT_DATA_DIR", Error.DataDirMissing },
        .{ "DOOT_MAX_INDEX_BYTES", Error.MaxIndexBytesMissing },
        .{ "DOOT_HMAC_SECRET", Error.HmacSecretMissing },
    }) |case| {
        var m = try validEnv(testing.allocator);
        defer m.deinit();
        try testing.expect(m.swapRemove(case[0]));
        try testing.expectError(case[1], Config.fromEnv(&m));
    }
}

test "an empty required variable is missing rather than valid" {
    inline for (.{
        .{ "DOOT_LISTEN_ADDR", Error.ListenAddrMissing },
        .{ "DOOT_DATA_DIR", Error.DataDirMissing },
    }) |case| {
        var m = try validEnv(testing.allocator);
        defer m.deinit();
        try m.put(case[0], "");
        try testing.expectError(case[1], Config.fromEnv(&m));
    }
}

test "the listen address is parsed at boot, not at Loop.init" {
    var m = try validEnv(testing.allocator);
    defer m.deinit();
    try m.put("DOOT_LISTEN_ADDR", "not-an-address");
    try testing.expectError(error.ListenAddrInvalid, Config.fromEnv(&m));
}

test "the index ceiling is required and may not be zero" {
    var m = try validEnv(testing.allocator);
    defer m.deinit();
    try m.put("DOOT_MAX_INDEX_BYTES", "0");
    try testing.expectError(error.MaxIndexBytesInvalid, Config.fromEnv(&m));
    try m.put("DOOT_MAX_INDEX_BYTES", "three hundred million");
    try testing.expectError(error.MaxIndexBytesInvalid, Config.fromEnv(&m));
}

test "the signing secret is 64 lowercase hex characters, and nothing else" {
    const cases = [_][]const u8{
        "0123456789abcdef" ** 3, // 48: too short
        "0123456789abcdef" ** 5, // 80: too long
        "0123456789ABCDEF" ** 4, // uppercase, deliberately refused
        ("0123456789abcde" ** 4) ++ "zzzz", // not hex
        "",
    };
    for (cases) |bad| {
        var m = try validEnv(testing.allocator);
        defer m.deinit();
        try m.put("DOOT_HMAC_SECRET", bad);
        try testing.expectError(error.HmacSecretInvalid, Config.fromEnv(&m));
    }
}

test "the signing secret decodes to the bytes it spells" {
    var m = try validEnv(testing.allocator);
    defer m.deinit();
    try m.put("DOOT_HMAC_SECRET", "00112233445566778899aabbccddeeff" ** 2);
    const cfg = try Config.fromEnv(&m);
    try testing.expectEqual(@as(u8, 0x00), cfg.hmac_secret[0]);
    try testing.expectEqual(@as(u8, 0x11), cfg.hmac_secret[1]);
    try testing.expectEqual(@as(u8, 0xff), cfg.hmac_secret[15]);
    try testing.expectEqual(@as(u8, 0x00), cfg.hmac_secret[16]);
    try testing.expectEqual(@as(u8, 0xff), cfg.hmac_secret[31]);
}

test "DOOT_MAX_TTL takes the X-Doot-TTL grammar D47 settled" {
    inline for (.{
        .{ "30d", 30 * 24 * 60 * 60 },
        .{ "14d", 14 * 24 * 60 * 60 },
        .{ "12h", 12 * 60 * 60 },
        .{ "90m", 90 * 60 },
        .{ "2592000", 2_592_000 },
    }) |case| {
        var m = try validEnv(testing.allocator);
        defer m.deinit();
        try m.put("DOOT_MAX_TTL", case[0]);
        const cfg = try Config.fromEnv(&m);
        try testing.expectEqual(@as(u32, case[1]), cfg.options.max_ttl_s);
    }
}

test "DOOT_MAX_TTL refuses what X-Doot-TTL refuses" {
    // Compound and fractional forms are D47's rejections, inherited rather than restated.
    for ([_][]const u8{ "1h30m", "1.5h", "-5", "abc", "d", "30D" }) |bad| {
        var m = try validEnv(testing.allocator);
        defer m.deinit();
        try m.put("DOOT_MAX_TTL", bad);
        try testing.expectError(error.MaxTtlInvalid, Config.fromEnv(&m));
    }
}

test "a lifetime ceiling below the minimum lifetime is refused at boot" {
    for ([_][]const u8{ "0", "1", "59s" }) |bad| {
        var m = try validEnv(testing.allocator);
        defer m.deinit();
        try m.put("DOOT_MAX_TTL", bad);
        try testing.expectError(error.MaxTtlTooShort, Config.fromEnv(&m));
    }
}

test "the minimum lifetime itself is accepted" {
    var m = try validEnv(testing.allocator);
    defer m.deinit();
    try m.put("DOOT_MAX_TTL", "60s");
    const cfg = try Config.fromEnv(&m);
    try testing.expectEqual(storage.config.min_ttl_s, cfg.options.max_ttl_s);
}

test "segment size is bounded by what the storage layout allows" {
    var m = try validEnv(testing.allocator);
    defer m.deinit();
    // Above `max_segment_bytes`.
    try m.put("DOOT_SEGMENT_BYTES", "134217728");
    try testing.expectError(error.SegmentBytesInvalid, Config.fromEnv(&m));
    // Below the floor.
    try m.put("DOOT_SEGMENT_BYTES", "4096");
    try testing.expectError(error.SegmentBytesInvalid, Config.fromEnv(&m));
    // Not a number at all.
    try m.put("DOOT_SEGMENT_BYTES", "64MiB");
    try testing.expectError(error.SegmentBytesInvalid, Config.fromEnv(&m));
}

test "a zero snapshot interval is refused rather than becoming a busy loop" {
    var m = try validEnv(testing.allocator);
    defer m.deinit();
    try m.put("DOOT_SNAPSHOT_INTERVAL_S", "0");
    try testing.expectError(error.SnapshotIntervalInvalid, Config.fromEnv(&m));
}

test "the index hash key is never taken from the environment (D43)" {
    var m = try validEnv(testing.allocator);
    defer m.deinit();
    // The variable D43 removed. Setting it must change nothing.
    try m.put("DOOT_INDEX_HASH_SECRET", "ff" ** 16);
    const cfg = try Config.fromEnv(&m);
    try testing.expectEqual((storage.config.Options{}).index_hash_key, cfg.options.index_hash_key);
}

test "every configuration error has an operator-facing message" {
    inline for (@typeInfo(Error).error_set.?) |e| {
        const err = @field(Error, e.name);
        const text = describe(err);
        try testing.expect(text.len > 0);
        // A message that is merely the error name is not a message.
        try testing.expect(!std.mem.eql(u8, text, e.name));
    }
}


// ---------------------------------------------------------------------------
// Tests — the maintenance thread
// ---------------------------------------------------------------------------

/// A store and a control log in a directory of their own, for the tests below.
///
/// Deliberately a real `Store` and a real `Control` rather than fakes: what is being tested
/// is that maintenance actually reaches the engine, and a fake would agree with a mistake.
const Fixture = struct {
    path_buf: [64]u8 = undefined,
    path_len: usize = 0,
    dir_fd: os.Fd,
    store: *storage.Store,
    ctl: *control.Control,

    fn open(gpa: std.mem.Allocator, tag: []const u8, clk: storage.clock.Clock) !*Fixture {
        const self = try gpa.create(Fixture);
        errdefer gpa.destroy(self);

        const path = try std.fmt.bufPrintZ(&self.path_buf, "/tmp/doot_boot_{s}", .{tag});
        self.path_len = path.len;

        // Start from nothing, so a previous run cannot make a test pass or fail.
        removeTree(path);
        try os.mkdir(os.cwd, path);

        self.dir_fd = try os.openDir(os.cwd, path);
        errdefer os.close(self.dir_fd);

        self.store = try storage.Store.open(gpa, self.dir_fd, clk, .{});
        errdefer self.store.abandon();
        self.ctl = try control.Control.open(gpa, self.dir_fd, clk);
        return self;
    }

    fn close(self: *Fixture, gpa: std.mem.Allocator) void {
        self.ctl.abandon();
        self.store.abandon();
        os.close(self.dir_fd);
        removeTree(self.path_buf[0..self.path_len :0]);
        gpa.destroy(self);
    }

    fn has(self: *Fixture, name: [:0]const u8) bool {
        return os.exists(self.dir_fd, name);
    }
};

fn removeTree(path: [:0]const u8) void {
    const dir_fd = os.openDir(os.cwd, path) catch return;
    var it = os.DirIterator.init(dir_fd);
    while (it.next() catch null) |entry| {
        var buf: [256]u8 = undefined;
        const z = std.fmt.bufPrintZ(&buf, "{s}", .{entry.name}) catch continue;
        os.unlink(dir_fd, z) catch {};
    }
    os.close(dir_fd);
    os.unlink(os.cwd, path) catch {};
}

/// `std.Thread.sleep` no longer exists in Zig 0.16. Same wrapper `server/loop.zig`'s tests
/// carry, for the same reason.
fn sleepMs(ms: u64) void {
    const req = std.os.linux.timespec{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
    _ = std.os.linux.nanosleep(&req, null);
}

test "the interval is a threshold the thread checks, not a sleep it performs" {
    var mclock: storage.clock.Manual = .init(1_700_000_000);
    const fx = try Fixture.open(testing.allocator, "interval", mclock.clock());
    defer fx.close(testing.allocator);

    var maint: Maintenance = .{
        .store = fx.store,
        .ctl = fx.ctl,
        .clock = mclock.clock(),
        .log = false,
        .last_run_s = mclock.clock().now(),
    };

    // Woken repeatedly with no time passing: a wake is not a reason to do work.
    for (0..5) |_| maint.runDue();
    try testing.expectEqual(@as(u32, 0), maint.runs.load(.monotonic));

    // One second short.
    mclock.advance(server.config.maintenance_interval_s - 1);
    maint.runDue();
    try testing.expectEqual(@as(u32, 0), maint.runs.load(.monotonic));

    // And on the interval itself.
    mclock.advance(1);
    maint.runDue();
    try testing.expectEqual(@as(u32, 1), maint.runs.load(.monotonic));

    // Having run, it waits another full interval.
    maint.runDue();
    try testing.expectEqual(@as(u32, 1), maint.runs.load(.monotonic));
}

test "a clock that moves backwards delays a pass rather than causing one every tick" {
    var mclock: storage.clock.Manual = .init(1_700_000_000);
    const fx = try Fixture.open(testing.allocator, "backwards", mclock.clock());
    defer fx.close(testing.allocator);

    var maint: Maintenance = .{
        .store = fx.store,
        .ctl = fx.ctl,
        .clock = mclock.clock(),
        .log = false,
        .last_run_s = mclock.clock().now(),
    };

    // The saturating subtraction is the defence: an earlier `now` must not read as a huge
    // elapsed time. Same protection `Control.takeToken` gives the rate bucket.
    mclock.set(1_600_000_000);
    for (0..5) |_| maint.runDue();
    try testing.expectEqual(@as(u32, 0), maint.runs.load(.monotonic));
}

test "maintenance is what snapshots, and nothing else does" {
    var mclock: storage.clock.Manual = .init(1_700_000_000);
    const fx = try Fixture.open(testing.allocator, "snapshot", mclock.clock());
    defer fx.close(testing.allocator);

    _ = try fx.store.put(1, "ci/last-green-sha", "deadbeef\n", "text/plain", &.{"ci"}, 24 * 60 * 60);

    // The defect D63 exists to fix: writing does not snapshot, so a process with no
    // maintenance thread never produces one — and recovery then replays the whole log,
    // which is precisely the bound D38 says recovery has.
    try testing.expect(!fx.has("SNAPSHOT"));

    var maint: Maintenance = .{
        .store = fx.store,
        .ctl = fx.ctl,
        .clock = mclock.clock(),
        .log = false,
        .last_run_s = mclock.clock().now(),
    };

    // A pass before the snapshot interval sweeps but does not snapshot.
    mclock.advance(server.config.maintenance_interval_s);
    maint.runDue();
    try testing.expectEqual(@as(u32, 1), maint.runs.load(.monotonic));
    try testing.expect(!fx.has("SNAPSHOT"));

    // Past `snapshot_interval_s`, the pass writes one.
    mclock.advance((storage.config.Options{}).snapshot_interval_s);
    maint.runDue();
    try testing.expect(fx.has("SNAPSHOT"));
    try testing.expectEqual(@as(u32, 0), maint.store_failures.load(.monotonic));
    try testing.expectEqual(@as(u32, 0), maint.control_failures.load(.monotonic));
}

test "a pass sweeps entries that have expired" {
    var mclock: storage.clock.Manual = .init(1_700_000_000);
    const fx = try Fixture.open(testing.allocator, "sweep", mclock.clock());
    defer fx.close(testing.allocator);

    for (0..16) |i| {
        var name: [32]u8 = undefined;
        const n = try std.fmt.bufPrint(&name, "short/{d}", .{i});
        _ = try fx.store.put(1, n, "x", "text/plain", &.{}, storage.config.min_ttl_s);
    }
    const before = fx.store.stats().index.live;
    try testing.expectEqual(@as(u64, 16), before);

    var maint: Maintenance = .{
        .store = fx.store,
        .ctl = fx.ctl,
        .clock = mclock.clock(),
        .log = false,
        .last_run_s = mclock.clock().now(),
    };

    // Past their lifetime, so the sweep has something to reclaim.
    mclock.advance(storage.config.min_ttl_s + server.config.maintenance_interval_s);
    maint.runDue();
    try testing.expectEqual(@as(u64, 0), fx.store.stats().index.live);
}

test "the thread starts, is woken by the tick seam, and stops when asked" {
    var mclock: storage.clock.Manual = .init(1_700_000_000);
    const fx = try Fixture.open(testing.allocator, "thread", mclock.clock());
    defer fx.close(testing.allocator);

    var maint: Maintenance = .{
        .store = fx.store,
        .ctl = fx.ctl,
        .clock = mclock.clock(),
        .log = false,
        // Zero, so every wake is due — the cadence is tested above with no thread at all,
        // and what is being tested here is the wake path itself.
        .interval_s = 0,
    };

    try maint.start();
    try testing.expect(maint.thread != null);

    // Exactly what the event loop does once a second, through exactly the same seam.
    const seam = maint.tick();
    var waited: u32 = 0;
    while (maint.runs.load(.monotonic) == 0 and waited < 2_000) : (waited += 1) {
        seam.call();
        sleepMs(1);
    }
    try testing.expect(maint.runs.load(.monotonic) > 0);

    // Returns rather than hanging, which is the property that keeps a deploy from waiting
    // out an interval.
    maint.stop();
    try testing.expect(maint.thread == null);

    // Idempotent, so a shutdown path that runs it twice is not a bug.
    maint.stop();
}

test "stopping a thread that never started is a no-op" {
    var mclock: storage.clock.Manual = .init(1_700_000_000);
    const fx = try Fixture.open(testing.allocator, "nostart", mclock.clock());
    defer fx.close(testing.allocator);

    var maint: Maintenance = .{
        .store = fx.store,
        .ctl = fx.ctl,
        .clock = mclock.clock(),
        .log = false,
    };
    maint.stop();
    try testing.expectEqual(@as(u32, 0), maint.runs.load(.monotonic));
}
