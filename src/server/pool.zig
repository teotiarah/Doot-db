//! The I/O worker pool.
//!
//! Every `Store` call runs here rather than on the event loop (D57). The loop does
//! sockets, parsing, routing and authentication — all memory-only — and hands anything
//! that can touch a disk to one of these threads.
//!
//! The reason is not only tail latency. `Store.delete` waits on an `fsync`, and leader
//! commit (D34) only amortises a flush when a second writer is already waiting for one.
//! A single-threaded request path never has a second writer, so an inline delete would
//! pay a full flush every time — the ~200/s D48 measured on a persistent volume, against
//! ~41,000/s on tmpfs. The pool is what supplies the concurrency that makes D34 work as
//! designed, so it is load-bearing for durability throughput rather than a nicety.
//!
//! Deliberately generic: it runs opaque jobs and knows nothing about entries, accounts
//! or HTTP. What a job *does* is the service layer's business, and the loop's only role
//! is to notice when one has finished.

const std = @import("std");
const storage = @import("storage");

const os = storage.os;

/// One unit of work. Embedded in whatever owns it, so submitting allocates nothing.
pub const Job = struct {
    /// Runs on a worker thread.
    run: *const fn (*Job) void,
    /// Runs on the same worker thread immediately after `run`, to hand the result back
    /// to whoever is waiting for it.
    complete: *const fn (*Job) void,
    /// Queue linkage, owned by the pool between `submit` and `run`.
    next: ?*Job = null,
};

pub const Stats = struct {
    /// Jobs submitted and not yet run.
    depth: u32,
    /// High-water mark of `depth`.
    ///
    /// The number that matters operationally: the pool is a queue, and a full one is
    /// backpressure rather than a fault, so it has to be visible instead of inferred
    /// from latency (D57).
    peak_depth: u32,
    ran: u64,
    workers: u32,
};

pub const Pool = struct {
    threads: []std.Thread,

    mutex: os.Mutex = .{},
    head: ?*Job = null,
    tail: ?*Job = null,
    depth: u32 = 0,
    peak_depth: u32 = 0,
    ran: u64 = 0,

    /// Bumped on every submission and on shutdown. Workers park on it when they find
    /// the queue empty.
    ///
    /// A counter rather than a flag, because the value a worker observed *before*
    /// looking at the queue is what makes the park safe: if a submission lands in
    /// between, the counter no longer matches and `futexWait` returns at once instead of
    /// sleeping through work that is already there.
    signal: std.atomic.Value(u32) = .init(0),
    stopping: std.atomic.Value(bool) = .init(false),

    pub fn start(gpa: std.mem.Allocator, workers: u16) !*Pool {
        std.debug.assert(workers > 0);
        const self = try gpa.create(Pool);
        errdefer gpa.destroy(self);
        self.* = .{ .threads = try gpa.alloc(std.Thread, workers) };
        errdefer gpa.free(self.threads);

        var started: usize = 0;
        errdefer {
            // Unwind cleanly if a later thread fails to spawn, or the ones already
            // running would outlive the allocation they are reading.
            self.stopping.store(true, .release);
            _ = self.signal.fetchAdd(1, .release);
            os.futexWake(&self.signal, os.wake_all);
            for (self.threads[0..started]) |t| t.join();
        }
        while (started < workers) : (started += 1) {
            self.threads[started] = try std.Thread.spawn(.{}, worker, .{self});
        }
        return self;
    }

    /// Drains nothing: a job already submitted still runs. Only waits for the workers to
    /// notice there is no more coming.
    pub fn stop(self: *Pool, gpa: std.mem.Allocator) void {
        self.stopping.store(true, .release);
        _ = self.signal.fetchAdd(1, .release);
        os.futexWake(&self.signal, os.wake_all);
        for (self.threads) |t| t.join();
        gpa.free(self.threads);
        gpa.destroy(self);
    }

    pub fn submit(self: *Pool, job: *Job) void {
        job.next = null;

        self.mutex.lock();
        if (self.tail) |t| {
            t.next = job;
        } else {
            self.head = job;
        }
        self.tail = job;
        self.depth += 1;
        if (self.depth > self.peak_depth) self.peak_depth = self.depth;
        self.mutex.unlock();

        _ = self.signal.fetchAdd(1, .release);
        os.futexWake(&self.signal, 1);
    }

    pub fn stats(self: *Pool) Stats {
        self.mutex.lock();
        defer self.mutex.unlock();
        return .{
            .depth = self.depth,
            .peak_depth = self.peak_depth,
            .ran = self.ran,
            .workers = @intCast(self.threads.len),
        };
    }

    fn pop(self: *Pool) ?*Job {
        self.mutex.lock();
        defer self.mutex.unlock();
        const job = self.head orelse return null;
        self.head = job.next;
        if (self.head == null) self.tail = null;
        self.depth -= 1;
        self.ran += 1;
        job.next = null;
        return job;
    }

    fn worker(self: *Pool) void {
        while (true) {
            // Read the counter *before* inspecting the queue. A submission that lands
            // after this load but before the park will have moved the counter, so the
            // wait returns immediately rather than missing the work.
            const seen = self.signal.load(.acquire);

            if (self.pop()) |job| {
                job.run(job);
                job.complete(job);
                continue;
            }
            if (self.stopping.load(.acquire)) return;
            os.futexWait(&self.signal, seen);
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const Counter = struct {
    job: Job = undefined,
    ran: std.atomic.Value(u32) = .init(0),
    completed: std.atomic.Value(u32) = .init(0),
    /// Observed inside `complete`, to prove ordering rather than assume it.
    ran_before_complete: bool = false,

    fn run(job: *Job) void {
        const self: *Counter = @fieldParentPtr("job", job);
        _ = self.ran.fetchAdd(1, .monotonic);
    }
    fn done(job: *Job) void {
        const self: *Counter = @fieldParentPtr("job", job);
        self.ran_before_complete = self.ran.load(.monotonic) > 0;
        _ = self.completed.fetchAdd(1, .monotonic);
    }
    fn arm(self: *Counter) *Job {
        self.job = .{ .run = run, .complete = done };
        return &self.job;
    }
};

test "a submitted job runs, and completes after it has run" {
    const gpa = testing.allocator;
    const p = try Pool.start(gpa, 2);
    defer p.stop(gpa);

    var c: Counter = .{};
    p.submit(c.arm());

    while (c.completed.load(.monotonic) == 0) std.atomic.spinLoopHint();
    try testing.expectEqual(@as(u32, 1), c.ran.load(.monotonic));
    try testing.expect(c.ran_before_complete);
}

test "every job in a burst runs exactly once" {
    const gpa = testing.allocator;
    const p = try Pool.start(gpa, 4);
    defer p.stop(gpa);

    const count = 512;
    const jobs = try gpa.alloc(Counter, count);
    defer gpa.free(jobs);
    for (jobs) |*j| j.* = .{};
    for (jobs) |*j| p.submit(j.arm());

    for (jobs) |*j| while (j.completed.load(.monotonic) == 0) std.atomic.spinLoopHint();
    for (jobs) |*j| {
        try testing.expectEqual(@as(u32, 1), j.ran.load(.monotonic));
        try testing.expectEqual(@as(u32, 1), j.completed.load(.monotonic));
    }

    const s = p.stats();
    try testing.expectEqual(@as(u64, count), s.ran);
    try testing.expectEqual(@as(u32, 0), s.depth);
    try testing.expect(s.peak_depth > 0);
    try testing.expectEqual(@as(u32, 4), s.workers);
}

test "work submitted while every worker is parked still gets picked up" {
    // The race the signal counter exists for. A worker that parked on a stale value
    // would sleep through this and the test would hang rather than fail, which is why
    // the loop below is bounded.
    const gpa = testing.allocator;
    const p = try Pool.start(gpa, 2);
    defer p.stop(gpa);

    for (0..64) |_| {
        var c: Counter = .{};
        // Long enough for both workers to have found nothing and parked.
        std.atomic.spinLoopHint();
        p.submit(c.arm());
        var spins: usize = 0;
        while (c.completed.load(.monotonic) == 0) : (spins += 1) {
            if (spins > 100_000_000) return error.WorkerNeverWoke;
            std.atomic.spinLoopHint();
        }
    }
}

test "a single worker serialises, and the queue drains in order" {
    const gpa = testing.allocator;
    const p = try Pool.start(gpa, 1);
    defer p.stop(gpa);

    const Ordered = struct {
        job: Job = undefined,
        seen: *std.ArrayList(u32),
        gpa: std.mem.Allocator,
        id: u32 = 0,
        done: std.atomic.Value(bool) = .init(false),

        fn run(job: *Job) void {
            const self: *@This() = @fieldParentPtr("job", job);
            self.seen.append(self.gpa, self.id) catch {};
        }
        fn fin(job: *Job) void {
            const self: *@This() = @fieldParentPtr("job", job);
            self.done.store(true, .release);
        }
    };

    var seen: std.ArrayList(u32) = .empty;
    defer seen.deinit(gpa);

    const jobs = try gpa.alloc(Ordered, 32);
    defer gpa.free(jobs);
    for (jobs, 0..) |*j, i| {
        j.* = .{ .seen = &seen, .gpa = gpa, .id = @intCast(i) };
        j.job = .{ .run = Ordered.run, .complete = Ordered.fin };
    }
    // Submitted before any can be observed finishing, so the queue really is a queue.
    for (jobs) |*j| p.submit(&j.job);
    for (jobs) |*j| while (!j.done.load(.acquire)) std.atomic.spinLoopHint();

    try testing.expectEqual(@as(usize, 32), seen.items.len);
    for (seen.items, 0..) |id, i| try testing.expectEqual(@as(u32, @intCast(i)), id);
}

test "stopping an idle pool joins every worker" {
    // Nothing to assert beyond termination: if `stop` failed to wake a parked worker,
    // the join would never return and the suite would hang here.
    const gpa = testing.allocator;
    const p = try Pool.start(gpa, 8);
    p.stop(gpa);
}

test "a pool that never receives work still reports itself honestly" {
    const gpa = testing.allocator;
    const p = try Pool.start(gpa, 3);
    defer p.stop(gpa);
    const s = p.stats();
    try testing.expectEqual(@as(u32, 0), s.depth);
    try testing.expectEqual(@as(u32, 0), s.peak_depth);
    try testing.expectEqual(@as(u64, 0), s.ran);
    try testing.expectEqual(@as(u32, 3), s.workers);
}
