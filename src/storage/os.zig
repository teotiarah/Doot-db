//! Thin syscall layer.
//!
//! `std.posix` in Zig 0.16 no longer wraps most file operations, and a storage
//! engine wants exact control over offsets and flush points anyway. So these go
//! straight to `std.os.linux`, with errno turned into Zig errors.
//!
//! This is also the single choke point for the two testing seams in D33: every
//! `fsync` in the engine passes through `fsyncCounted`.

const std = @import("std");
const linux = std.os.linux;
const builtin = @import("builtin");

pub const Fd = i32;

pub const Error = error{
    AccessDenied,
    AlreadyExists,
    BadFileDescriptor,
    DeviceBusy,
    DiskQuota,
    FileNotFound,
    FileTooBig,
    InputOutput,
    IsDir,
    NameTooLong,
    NoSpaceLeft,
    NotDir,
    ProcessFdQuotaExceeded,
    ReadOnlyFileSystem,
    SymLinkLoop,
    SystemFdQuotaExceeded,
    SystemResources,
    Unexpected,
    WouldBlock,
};

fn errnoOf(rc: usize) linux.E {
    return linux.errno(rc);
}

fn failed(rc: usize) bool {
    return @as(isize, @bitCast(rc)) < 0;
}

fn toError(rc: usize) Error {
    return switch (errnoOf(rc)) {
        .ACCES, .PERM => error.AccessDenied,
        .EXIST => error.AlreadyExists,
        .BADF => error.BadFileDescriptor,
        .BUSY, .TXTBSY => error.DeviceBusy,
        .DQUOT => error.DiskQuota,
        .NOENT => error.FileNotFound,
        .FBIG => error.FileTooBig,
        .IO => error.InputOutput,
        .ISDIR => error.IsDir,
        .NAMETOOLONG => error.NameTooLong,
        .NOSPC => error.NoSpaceLeft,
        .NOTDIR => error.NotDir,
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        .ROFS => error.ReadOnlyFileSystem,
        .LOOP => error.SymLinkLoop,
        .NOMEM => error.SystemResources,
        .AGAIN => error.WouldBlock,
        else => error.Unexpected,
    };
}

// ---------------------------------------------------------------------------
// D33: the crash point is a parameter
// ---------------------------------------------------------------------------

/// Number of `fsync` calls completed by this process. Always compiled in: one
/// relaxed increment beside a syscall that already costs 50-200 us.
pub var fsync_count: std.atomic.Value(u64) = .init(0);

/// When non-zero, the process aborts immediately after this many fsyncs have
/// completed. Armed only by explicit configuration; never set in production.
///
/// Abort is via SIGKILL to self rather than `@panic`, so no deferred cleanup,
/// atexit handler or buffered write can run. A crash that politely tidies up is
/// not the crash worth testing against.
pub var crash_after_fsync: std.atomic.Value(u64) = .init(0);

fn maybeCrash(count_after: u64) void {
    const armed = crash_after_fsync.load(.monotonic);
    if (armed != 0 and count_after >= armed) {
        _ = linux.kill(linux.getpid(), linux.SIG.KILL);
        unreachable;
    }
}

/// The engine's only flush primitive. `fdatasync` is deliberately not used:
/// segment appends extend file length, and file size is metadata.
pub fn fsyncCounted(fd: Fd) Error!void {
    const rc = linux.fsync(fd);
    if (failed(rc)) return toError(rc);
    const n = fsync_count.fetchAdd(1, .monotonic) + 1;
    maybeCrash(n);
}

// ---------------------------------------------------------------------------
// Files
// ---------------------------------------------------------------------------

pub const OpenFlags = struct {
    write: bool = false,
    create: bool = false,
    /// Fail if the file already exists. Used for segments, whose ids are never
    /// reused, so an existing file means a bug rather than a race.
    exclusive: bool = false,
    truncate: bool = false,
};

pub fn open(dir: Fd, path: [:0]const u8, f: OpenFlags) Error!Fd {
    var flags: linux.O = .{
        .ACCMODE = if (f.write) .RDWR else .RDONLY,
        .CLOEXEC = true,
    };
    flags.CREAT = f.create;
    flags.EXCL = f.exclusive;
    flags.TRUNC = f.truncate;

    const rc = linux.openat(dir, path.ptr, flags, 0o644);
    if (failed(rc)) return toError(rc);
    return @intCast(rc);
}

pub fn openDir(dir: Fd, path: [:0]const u8) Error!Fd {
    const rc = linux.openat(dir, path.ptr, .{
        .ACCMODE = .RDONLY,
        .DIRECTORY = true,
        .CLOEXEC = true,
    }, 0);
    if (failed(rc)) return toError(rc);
    return @intCast(rc);
}

pub fn mkdir(dir: Fd, path: [:0]const u8) Error!void {
    const rc = linux.mkdirat(dir, path.ptr, 0o755);
    if (failed(rc) and errnoOf(rc) != .EXIST) return toError(rc);
}

pub fn close(fd: Fd) void {
    _ = linux.close(fd);
}

pub fn unlink(dir: Fd, path: [:0]const u8) Error!void {
    const rc = linux.unlinkat(dir, path.ptr, 0);
    if (failed(rc)) return toError(rc);
}

/// Writes all of `buf` at `offset`, looping on short writes.
pub fn pwriteAll(fd: Fd, buf: []const u8, offset: u64) Error!void {
    var done: usize = 0;
    while (done < buf.len) {
        const rc = linux.pwrite(fd, buf.ptr + done, buf.len - done, @intCast(offset + done));
        if (failed(rc)) {
            if (errnoOf(rc) == .INTR) continue;
            return toError(rc);
        }
        if (rc == 0) return error.Unexpected;
        done += rc;
    }
}

/// Reads exactly `buf.len` bytes at `offset`. A short read means the file ends
/// mid-record, which for a tail scan is a torn write.
pub fn preadAll(fd: Fd, buf: []u8, offset: u64) Error!usize {
    var done: usize = 0;
    while (done < buf.len) {
        const rc = linux.pread(fd, buf.ptr + done, buf.len - done, @intCast(offset + done));
        if (failed(rc)) {
            if (errnoOf(rc) == .INTR) continue;
            return toError(rc);
        }
        if (rc == 0) break; // EOF
        done += rc;
    }
    return done;
}

pub fn ftruncate(fd: Fd, len: u64) Error!void {
    const rc = linux.ftruncate(fd, @intCast(len));
    if (failed(rc)) return toError(rc);
}

pub fn fileSize(fd: Fd) Error!u64 {
    const rc = linux.lseek(fd, 0, linux.SEEK.END);
    if (failed(rc)) return toError(rc);
    return rc;
}

/// Directory fsync, needed after creating or unlinking a file so the directory
/// entry itself is durable. Counted like any other flush.
pub fn syncDir(dir_fd: Fd) Error!void {
    return fsyncCounted(dir_fd);
}

/// Atomically replaces `new_path` with `old_path`. The mechanism behind
/// write-to-temp-then-swap: a reader sees either the whole previous file or the
/// whole new one, never a half-written snapshot.
pub fn rename(dir_fd: Fd, old_path: [:0]const u8, new_path: [:0]const u8) Error!void {
    const rc = linux.renameat(dir_fd, old_path.ptr, dir_fd, new_path.ptr);
    if (failed(rc)) return toError(rc);
}

pub fn exists(dir_fd: Fd, path: [:0]const u8) bool {
    const fd = open(dir_fd, path, .{}) catch return false;
    close(fd);
    return true;
}

pub const cwd: Fd = linux.AT.FDCWD;

// ---------------------------------------------------------------------------
// Directory iteration
// ---------------------------------------------------------------------------

/// Iterates a directory via raw `getdents64`.
///
/// `std.Io.Dir` needs an `Io` to iterate, and the engine is `std.Io`-free (D27).
/// Segment discovery on startup needs the directory as ground truth — the
/// manifest can lag a crash, the filesystem cannot.
pub const DirIterator = struct {
    fd: Fd,
    buf: [8192]u8 align(@alignOf(linux.dirent64)) = undefined,
    len: usize = 0,
    pos: usize = 0,

    pub const Entry = struct {
        name: []const u8,
        is_file: bool,
    };

    /// Rewinds the descriptor first.
    ///
    /// `getdents64` advances the directory offset, so a second iteration of the
    /// same fd would otherwise start at EOF and report an empty directory. The
    /// engine keeps one long-lived data-directory fd and iterates it on every
    /// open, so without this the *second* startup discovers no segments at all
    /// and silently recovers an empty store.
    pub fn init(fd: Fd) DirIterator {
        _ = linux.lseek(fd, 0, linux.SEEK.SET);
        return .{ .fd = fd };
    }

    pub fn next(it: *DirIterator) Error!?Entry {
        while (true) {
            if (it.pos >= it.len) {
                const rc = linux.getdents64(it.fd, &it.buf, it.buf.len);
                if (failed(rc)) return toError(rc);
                if (rc == 0) return null;
                it.len = rc;
                it.pos = 0;
            }
            const d: *align(1) const linux.dirent64 = @ptrCast(&it.buf[it.pos]);
            const reclen = d.reclen;
            const name_ptr: [*:0]const u8 = @ptrCast(&it.buf[it.pos + @offsetOf(linux.dirent64, "name")]);
            const name = std.mem.sliceTo(name_ptr, 0);
            it.pos += reclen;

            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            return .{ .name = name, .is_file = d.type == linux.DT.REG or d.type == linux.DT.UNKNOWN };
        }
    }
};

// ---------------------------------------------------------------------------
// Futex
// ---------------------------------------------------------------------------

const futex_wait_op: linux.FUTEX_OP = .{ .cmd = .WAIT, .private = true };
const futex_wake_op: linux.FUTEX_OP = .{ .cmd = .WAKE, .private = true };

/// Blocks while `ptr` still holds `expect`. Spurious wakeups are possible, so
/// callers must re-check their condition in a loop.
pub fn futexWait(ptr: *const std.atomic.Value(u32), expect: u32) void {
    _ = linux.futex_4arg(&ptr.raw, futex_wait_op, expect, null);
}

pub fn futexWake(ptr: *const std.atomic.Value(u32), count: u32) void {
    _ = linux.futex_3arg(&ptr.raw, futex_wake_op, count);
}

pub const wake_all: u32 = std.math.maxInt(i32);

// ---------------------------------------------------------------------------
// Monotonic time
// ---------------------------------------------------------------------------

/// Milliseconds from a monotonic source, for measuring durations only.
///
/// Distinct from `clock.zig`, which supplies the *logical* time that expiry and
/// reclamation depend on and which tests drive by hand. This one measures how
/// long real work took — recovery duration, latencies — and is never used to
/// decide whether an entry has expired.
pub fn monotonicMillis() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(ts.nsec, 1_000_000);
}

// ---------------------------------------------------------------------------
// Mutex
// ---------------------------------------------------------------------------

/// A futex-backed mutex.
///
/// `std.Io.Mutex` requires an `Io` to lock, because it can park a fiber. The M1
/// engine is deliberately free of `std.Io` (D27), and `std.Thread` in Zig 0.16
/// no longer exposes a mutex, so this is the primitive the engine owns.
///
/// Uncontended lock and unlock are a single atomic each; contention falls back to
/// the kernel. Shard locks are held only for memory work, so contention is rare.
pub const Mutex = struct {
    state: std.atomic.Value(u32) = .init(unlocked),

    const unlocked: u32 = 0;
    const locked: u32 = 1;
    const contended: u32 = 2;

    const wait_op: linux.FUTEX_OP = .{ .cmd = .WAIT, .private = true };
    const wake_op: linux.FUTEX_OP = .{ .cmd = .WAKE, .private = true };

    pub fn tryLock(m: *Mutex) bool {
        return m.state.cmpxchgStrong(unlocked, locked, .acquire, .monotonic) == null;
    }

    pub fn lock(m: *Mutex) void {
        if (m.state.cmpxchgWeak(unlocked, locked, .acquire, .monotonic) == null) {
            @branchHint(.likely);
            return;
        }
        // Spin briefly: shard critical sections are a handful of memory writes,
        // so a contending thread usually wins before a syscall would pay off.
        var spins: u8 = 0;
        while (spins < 40) : (spins += 1) {
            if (m.state.load(.monotonic) == unlocked and
                m.state.cmpxchgWeak(unlocked, locked, .acquire, .monotonic) == null) return;
            std.atomic.spinLoopHint();
        }
        while (m.state.swap(contended, .acquire) != unlocked) {
            _ = linux.futex_4arg(&m.state.raw, wait_op, contended, null);
        }
    }

    pub fn unlock(m: *Mutex) void {
        if (m.state.swap(unlocked, .release) == contended) {
            _ = linux.futex_3arg(&m.state.raw, wake_op, 1);
        }
    }
};

test "mutex excludes concurrent writers" {
    const Shared = struct {
        m: Mutex = .{},
        counter: u64 = 0,

        fn bump(self: *@This(), n: u64) void {
            var i: u64 = 0;
            while (i < n) : (i += 1) {
                self.m.lock();
                defer self.m.unlock();
                // Non-atomic on purpose: only the mutex makes this sound.
                self.counter += 1;
            }
        }
    };

    var shared: Shared = .{};
    const per_thread = 20_000;
    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Shared.bump, .{ &shared, per_thread });
    for (&threads) |t| t.join();

    try std.testing.expectEqual(@as(u64, threads.len * per_thread), shared.counter);
}

test "tryLock reports contention without blocking" {
    var m: Mutex = .{};
    try std.testing.expect(m.tryLock());
    try std.testing.expect(!m.tryLock());
    m.unlock();
    try std.testing.expect(m.tryLock());
    m.unlock();
}

// ---------------------------------------------------------------------------

test "write, read back, and flush a temporary file" {
    const tmp_path: [:0]const u8 = "/tmp/doot_os_test.bin";
    defer unlink(cwd, tmp_path) catch {};

    const fd = try open(cwd, tmp_path, .{ .write = true, .create = true, .truncate = true });
    defer close(fd);

    try pwriteAll(fd, "hello doot", 0);
    try pwriteAll(fd, "TAIL", 100);

    var buf: [10]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 10), try preadAll(fd, &buf, 0));
    try std.testing.expectEqualStrings("hello doot", &buf);

    try std.testing.expectEqual(@as(u64, 104), try fileSize(fd));

    const before = fsync_count.load(.monotonic);
    try fsyncCounted(fd);
    try std.testing.expectEqual(before + 1, fsync_count.load(.monotonic));
}

test "a short read reports how little was available" {
    const tmp_path: [:0]const u8 = "/tmp/doot_os_short.bin";
    defer unlink(cwd, tmp_path) catch {};

    const fd = try open(cwd, tmp_path, .{ .write = true, .create = true, .truncate = true });
    defer close(fd);
    try pwriteAll(fd, "abc", 0);

    var buf: [16]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 3), try preadAll(fd, &buf, 0));
}

test "errno becomes a typed error" {
    try std.testing.expectError(
        error.FileNotFound,
        open(cwd, "/tmp/doot_definitely_absent_xyz", .{}),
    );
}
