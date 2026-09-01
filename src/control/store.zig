//! Control-plane state: accounts, API keys and credit balances (D40, D41).
//!
//! ## Why this is not in the entry store
//!
//! Every entry must expire, segment reclamation `unlink`s whole files once their
//! maximum expiry passes, and a dead index slot *is* one whose `expires_at` has
//! gone by (D32). "Never expires" is not representable there. The entry store is
//! built for data that dies; account state is data that must not.
//!
//! ## The shape
//!
//! An append-only log, `CONTROL`, with the entire state held as an in-RAM image. At
//! ten thousand accounts that image is single-digit megabytes against a budget with
//! ~15 GB left to page cache, so there is no index, no segments, no partial loading
//! and no incremental compaction. Disk exists only to rebuild the maps at boot.
//!
//! - A mutation appends one checksummed event and `fsync`s before the caller
//!   returns. Signup, key creation and revocation are rare; one flush each is
//!   invisible.
//!  - Recovery replays from the start into empty maps. A torn tail is truncated,
//!   exactly as `segment.resolveUnsealed` treats one.
//! - The log is **rewritten wholesale** once it outgrows its own image by 8x:
//!   serialise to `CONTROL.tmp`, `fsync`, `rename`, `syncDir`. The same atomic
//!   replace `snapshot.zig` performs. Reclamation by rewrite, not compaction.
//!
//! `CONTROL` lives beside the segments in the data directory, which is safe because
//! `SegmentSet.discover` skips any filename it does not recognise rather than
//! unlinking it — already how `MANIFEST`, `SNAPSHOT` and `STORE` coexist there.
//!
//! ## Locking
//!
//! One mutex, and reads take it too. This mirrors D35's argument rather than
//! inventing a new one: control-plane mutations are rare, the critical section is a
//! hash lookup, and the alternative — lock-free reads over a mutating map — is the
//! hardest concurrency in the system for no measured gain. A mutation does hold the
//! lock across its `fsync`, which briefly blocks key lookups; at signup frequency
//! that is not worth engineering away.
//!
//! ## What M3 adds
//!
//! Sessions, OTP challenges, identity anchors and password hashes. They arrive as
//! new event types taking unused numbers, which is what the per-event `version` and
//! append-only numbering in `event.zig` exist for. Nothing here changes to
//! accommodate them, and nothing here is a stub standing in for them.

const std = @import("std");
const storage = @import("storage");
const event = @import("event.zig");
const plan_mod = @import("plan.zig");

const os = storage.os;
const clock_mod = storage.clock;

pub const file_name = "CONTROL";
const temp_name = "CONTROL.tmp";

/// 06-auth.md: five keys per account. Per-key rate buckets would let anyone
/// multiply their limit fivefold, so keys are credentials, not namespaces.
pub const max_keys_per_account: usize = 5;

/// A log below this never triggers a rewrite. Expressed as one page rather than a
/// new tunable: without a floor, a store holding a single account would rewrite on
/// almost every mutation.
const rewrite_floor_bytes: u64 = 4096;

/// How many times its own image the log may reach before being rewritten.
const rewrite_multiple: u64 = 8;

pub const Error = error{
    AccountNotFound,
    EmailInvalid,
    LabelTooLong,
    KeyLimitReached,
    KeyAlreadyExists,
    IdSpaceExhausted,
} || event.Error || os.Error || std.mem.Allocator.Error;

pub const Plan = event.Plan;
pub const AccountState = event.AccountState;

pub const Account = struct {
    id: u32,
    created_at: u32,
    credits_granted: u32,
    credits_remaining: u32,
    plan: Plan,
    state: AccountState,
    /// Owned by the store.
    email: []const u8,

    /// Rate-limit bucket, in tokens. Bookkeeping rather than user-facing state —
    /// callers read a `RateDecision` from `takeToken` and never touch this.
    ///
    /// Starts at zero with `tokens_at` at zero, so the first request sees an elapsed
    /// time of the whole unix epoch and fills the bucket. That is deliberate: it means
    /// there is no initialisation to forget at either of the two places an account is
    /// built, and a replayed account behaves exactly like a fresh one.
    tokens: f64 = 0,
    /// When `tokens` was last brought up to date.
    tokens_at: u32 = 0,
};

pub const ApiKey = struct {
    id: u32,
    account_id: u32,
    created_at: u32,
    /// SHA-256 of the plaintext. The plaintext is shown once and never stored.
    hash: [32]u8,
    /// Owned by the store.
    label: []const u8,
    revoked: bool,
};

/// What the request path needs from a presented key, in one lookup.
pub const Auth = struct {
    account_id: u32,
    key_id: u32,
    plan: Plan,
    credits_remaining: u32,
};

pub const Spend = enum { spent, exhausted, no_account };

pub const Stats = struct {
    accounts: u64,
    keys_live: u64,
    keys_revoked: u64,
    log_bytes: u64,
    image_bytes: u64,
    rewrites: u64,
    credits_checkpointed: u64,
};

/// Buckets the map on the digest's leading bytes — already uniform — and compares
/// in constant time, which is what 06-auth.md requires of a credential comparison.
const KeyContext = struct {
    pub fn hash(_: KeyContext, k: [32]u8) u64 {
        return std.mem.readInt(u64, k[0..8], .little);
    }
    pub fn eql(_: KeyContext, a: [32]u8, b: [32]u8) bool {
        return std.crypto.timing_safe.eql([32]u8, a, b);
    }
};

const Accounts = std.AutoHashMapUnmanaged(u32, Account);
const Keys = std.HashMapUnmanaged([32]u8, ApiKey, KeyContext, 80);

pub fn hashKey(plaintext: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(plaintext, &out, .{});
    return out;
}

pub const Control = struct {
    gpa: std.mem.Allocator,
    dir_fd: os.Fd,
    clock: clock_mod.Clock,
    mutex: os.Mutex = .{},

    log_fd: os.Fd = -1,
    log_bytes: u64 = 0,

    accounts: Accounts = .empty,
    keys: Keys = .empty,
    next_account_id: u32 = 1,
    next_key_id: u32 = 1,

    rewrites: u64 = 0,
    credits_checkpointed: u64 = 0,

    pub fn open(gpa: std.mem.Allocator, dir_fd: os.Fd, clk: clock_mod.Clock) Error!*Control {
        const self = try gpa.create(Control);
        errdefer gpa.destroy(self);

        self.* = .{ .gpa = gpa, .dir_fd = dir_fd, .clock = clk };
        errdefer self.releaseMaps();

        self.log_fd = try os.open(dir_fd, file_name, .{ .write = true, .create = true });
        errdefer os.close(self.log_fd);

        try self.replay();
        return self;
    }

    /// Checkpoints balances, then releases everything.
    ///
    /// Best effort, and the same posture as `Store.close`: a clean shutdown makes
    /// balances exact, and a failure here costs only the rewind D41 already permits.
    /// D41's stated consequence is about an *unclean* restart, which is what
    /// `abandon` reproduces.
    pub fn close(self: *Control) void {
        self.mutex.lock();
        _ = self.checkpointCreditsLocked() catch {};
        self.mutex.unlock();
        self.abandon();
    }

    /// Releases everything **without** checkpointing, which is how a crash looks.
    pub fn abandon(self: *Control) void {
        os.close(self.log_fd);
        self.releaseMaps();
        self.gpa.destroy(self);
    }

    fn releaseMaps(self: *Control) void {
        var ait = self.accounts.valueIterator();
        while (ait.next()) |a| self.gpa.free(a.email);
        self.accounts.deinit(self.gpa);

        var kit = self.keys.valueIterator();
        while (kit.next()) |k| self.gpa.free(k.label);
        self.keys.deinit(self.gpa);
    }

    // -----------------------------------------------------------------------
    // Accounts and keys
    // -----------------------------------------------------------------------

    /// Creates an account and grants its credits in one event.
    ///
    /// M2 needs this so a key can resolve to an account at all. M3's signup flows —
    /// GitHub OAuth and email plus OTP — call it after they have a verified
    /// identity, and add their own events for the anchors that stop the trial grant
    /// being farmed (D25).
    pub fn createAccount(
        self: *Control,
        email: []const u8,
        plan: Plan,
        state: AccountState,
        credits_granted: u32,
    ) Error!u32 {
        if (email.len == 0 or email.len > event.max_email_bytes) return error.EmailInvalid;

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.next_account_id == std.math.maxInt(u32)) return error.IdSpaceExhausted;
        const id = self.next_account_id;
        const now = self.clock.now();

        // Every fallible step happens before anything is committed: duplicate the
        // string, reserve the slot, make the event durable, and only then insert —
        // which cannot fail. A half-applied mutation would leave RAM disagreeing
        // with the log.
        const owned = try self.gpa.dupe(u8, email);
        errdefer self.gpa.free(owned);
        try self.accounts.ensureUnusedCapacity(self.gpa, 1);

        try self.appendLocked(.{ .account_created = .{
            .account_id = id,
            .created_at = now,
            .credits_granted = credits_granted,
            .plan = plan,
            .state = state,
            .email = email,
        } });

        self.accounts.putAssumeCapacity(id, .{
            .id = id,
            .created_at = now,
            .credits_granted = credits_granted,
            .credits_remaining = credits_granted,
            .plan = plan,
            .state = state,
            .email = owned,
        });
        self.next_account_id = id + 1;
        return id;
    }

    /// Records a key whose plaintext the caller generated. Only the digest is kept.
    pub fn issueKey(self: *Control, account_id: u32, label: []const u8, plaintext: []const u8) Error!u32 {
        if (label.len > event.max_label_bytes) return error.LabelTooLong;

        self.mutex.lock();
        defer self.mutex.unlock();

        if (!self.accounts.contains(account_id)) return error.AccountNotFound;
        if (self.liveKeyCountLocked(account_id) >= max_keys_per_account) return error.KeyLimitReached;
        if (self.next_key_id == std.math.maxInt(u32)) return error.IdSpaceExhausted;

        const hash = hashKey(plaintext);
        if (self.keys.contains(hash)) return error.KeyAlreadyExists;

        const id = self.next_key_id;
        const now = self.clock.now();

        const owned = try self.gpa.dupe(u8, label);
        errdefer self.gpa.free(owned);
        try self.keys.ensureUnusedCapacity(self.gpa, 1);

        try self.appendLocked(.{ .key_created = .{
            .key_id = id,
            .account_id = account_id,
            .created_at = now,
            .hash = hash,
            .label = label,
        } });

        self.keys.putAssumeCapacity(hash, .{
            .id = id,
            .account_id = account_id,
            .created_at = now,
            .hash = hash,
            .label = owned,
            .revoked = false,
        });
        self.next_key_id = id + 1;
        return id;
    }

    /// Immediate and irreversible (06-auth.md). Returns false when the key is
    /// unknown or already revoked, so revoking twice is not an error.
    ///
    /// The entry stays in the map, flagged, rather than being deleted: that keeps
    /// revocation idempotent without a second id-to-digest index, and the next
    /// wholesale rewrite drops it for good.
    pub fn revokeKey(self: *Control, key_id: u32) Error!bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        var it = self.keys.valueIterator();
        const target: *ApiKey = while (it.next()) |k| {
            if (k.id == key_id and !k.revoked) break k;
        } else return false;

        try self.appendLocked(.{ .key_revoked = .{ .key_id = key_id } });
        target.revoked = true;
        return true;
    }

    /// The data plane's authentication step. Unknown, revoked and
    /// not-yet-verified all return null, so nothing here is an enumeration oracle.
    pub fn resolveKey(self: *Control, plaintext: []const u8) ?Auth {
        const hash = hashKey(plaintext);

        self.mutex.lock();
        defer self.mutex.unlock();

        const k = self.keys.get(hash) orelse return null;
        if (k.revoked) return null;
        const a = self.accounts.get(k.account_id) orelse return null;
        if (a.state != .active) return null;

        return .{
            .account_id = a.id,
            .key_id = k.id,
            .plan = a.plan,
            .credits_remaining = a.credits_remaining,
        };
    }

    /// A snapshot for `/v1/whoami`. The email borrows the store's copy, which lives
    /// as long as the account does.
    pub fn account(self: *Control, account_id: u32) ?Account {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.accounts.get(account_id);
    }

    fn liveKeyCountLocked(self: *Control, account_id: u32) usize {
        var n: usize = 0;
        var it = self.keys.valueIterator();
        while (it.next()) |k| {
            if (k.account_id == account_id and !k.revoked) n += 1;
        }
        return n;
    }

    // -----------------------------------------------------------------------
    // Credits (D41)
    // -----------------------------------------------------------------------

    /// Spends one credit, in memory only.
    ///
    /// Deliberately not logged per write. One invariant governs this, and getting it
    /// backwards would charge for writes that never landed:
    ///
    /// > A deduction must never be durable unless the write it paid for is durable.
    ///
    /// A deduction lost to a crash gives the caller a free write — bounded,
    /// invisible, in their favour. The reverse would take money for nothing. So the
    /// balance is authoritative here, and persisted only as an absolute value at
    /// checkpoint time.
    pub fn spendCredit(self: *Control, account_id: u32) Spend {
        self.mutex.lock();
        defer self.mutex.unlock();

        const a = self.accounts.getPtr(account_id) orelse return .no_account;
        if (a.credits_remaining == 0) return .exhausted;
        a.credits_remaining -= 1;
        return .spent;
    }

    /// Returns a credit spent for a write that then failed, so a failed write costs
    /// nothing (`03-data-model.md`). Never exceeds what was granted.
    pub fn refundCredit(self: *Control, account_id: u32) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const a = self.accounts.getPtr(account_id) orelse return;
        if (a.credits_remaining < a.credits_granted) a.credits_remaining += 1;
    }

    /// What the caller learns from asking for a token.
    ///
    /// Every field maps onto a header `02-api.md` puts on every `/v1` response, so a
    /// handler never computes any of this itself.
    pub const RateDecision = struct {
        allowed: bool,
        /// Sustained operations per minute — `RateLimit-Limit`.
        limit: u32,
        /// Whole tokens left after this call — `RateLimit-Remaining`.
        remaining: u32,
        /// Seconds until the bucket is full again — `RateLimit-Reset`.
        reset_s: u32,
        /// Seconds until one token exists. Zero when allowed — `Retry-After` on a `429`.
        retry_after_s: u32,
    };

    /// Takes one token from the account's pooled bucket.
    ///
    /// **One bucket per account, covering reads, writes, lists and deletes** (D6). Not
    /// per key: five keys sharing one bucket is the whole point, because a bucket per
    /// key would let anyone multiply their limit fivefold. Not per connection or per
    /// worker either, for the same reason (D58).
    ///
    /// The dashboard draws on a separate bucket and does not come through here
    /// (`06-auth.md`); that arrives with the control-plane surface in M3.
    ///
    /// Returns `null` only when the account is gone, which a resolved key makes
    /// impossible in practice.
    ///
    /// Time comes from the injected clock, in seconds, for the same reason the engine's
    /// expiry does (D33): a rate limit whose tests need real elapsed time is a rate
    /// limit nobody tests. One-second granularity is the right resolution for a
    /// per-minute quota, and both directions of clock movement are safe — a backwards
    /// step saturates to no refill, and a forwards jump only ever refills a bucket,
    /// which errs toward letting the caller through.
    pub fn takeToken(self: *Control, account_id: u32) ?RateDecision {
        self.mutex.lock();
        defer self.mutex.unlock();

        const a = self.accounts.getPtr(account_id) orelse return null;
        const lim = plan_mod.limits(a.plan);
        const burst: f64 = @floatFromInt(lim.burst);
        const per_second = lim.refillPerSecond();
        const now = self.clock.now();

        const elapsed: f64 = @floatFromInt(now -| a.tokens_at);
        a.tokens = @min(burst, a.tokens + elapsed * per_second);
        a.tokens_at = now;

        const allowed = a.tokens >= 1.0;
        if (allowed) a.tokens -= 1.0;

        return .{
            .allowed = allowed,
            .limit = lim.rate_per_min,
            .remaining = @intFromFloat(@floor(a.tokens)),
            .reset_s = secondsToAccrue(burst - a.tokens, per_second),
            .retry_after_s = if (allowed) 0 else secondsToAccrue(1.0 - a.tokens, per_second),
        };
    }

    /// Whole seconds until `wanted` tokens have accrued, rounded up.
    ///
    /// Rounded up because rounding down would advertise a retry that is still too
    /// early, and a client honouring `Retry-After` would earn a second `429`.
    fn secondsToAccrue(wanted: f64, per_second: f64) u32 {
        if (wanted <= 0) return 0;
        return @intFromFloat(@ceil(wanted / per_second));
    }

    /// Operator grant. Logged, because a purchase must survive a restart even
    /// though a deduction need not.
    pub fn grantCredits(self: *Control, account_id: u32, additional: u32) Error!u32 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const a = self.accounts.getPtr(account_id) orelse return error.AccountNotFound;
        a.credits_granted +|= additional;
        a.credits_remaining +|= additional;

        try self.appendLocked(.{ .credits_checkpoint = .{
            .account_id = account_id,
            .credits_remaining = a.credits_remaining,
        } });
        return a.credits_remaining;
    }

    pub const Maintenance = struct {
        checkpointed: usize,
        rewritten: bool,
    };

    /// Persists balances and reclaims the log. Called from the maintenance thread,
    /// on the same cadence as the storage engine's own housekeeping (D45).
    ///
    /// One flush covers every balance, so the cost does not scale with how many
    /// accounts moved.
    pub fn maintain(self: *Control) Error!Maintenance {
        self.mutex.lock();
        defer self.mutex.unlock();

        const checkpointed = try self.checkpointCreditsLocked();

        var rewritten = false;
        const image = self.imageBytesLocked();
        if (self.log_bytes > rewrite_multiple * @max(image, rewrite_floor_bytes)) {
            try self.rewriteLocked();
            rewritten = true;
        }
        return .{ .checkpointed = checkpointed, .rewritten = rewritten };
    }

    pub fn stats(self: *Control) Stats {
        self.mutex.lock();
        defer self.mutex.unlock();

        var live: u64 = 0;
        var revoked: u64 = 0;
        var it = self.keys.valueIterator();
        while (it.next()) |k| {
            if (k.revoked) revoked += 1 else live += 1;
        }
        return .{
            .accounts = self.accounts.count(),
            .keys_live = live,
            .keys_revoked = revoked,
            .log_bytes = self.log_bytes,
            .image_bytes = self.imageBytesLocked(),
            .rewrites = self.rewrites,
            .credits_checkpointed = self.credits_checkpointed,
        };
    }

    // -----------------------------------------------------------------------
    // The log
    // -----------------------------------------------------------------------

    /// One absolute balance per account, then a single flush — so the cost does not
    /// scale with how many accounts moved.
    fn checkpointCreditsLocked(self: *Control) Error!usize {
        var n: usize = 0;
        var it = self.accounts.valueIterator();
        while (it.next()) |a| {
            try self.writeLocked(.{ .credits_checkpoint = .{
                .account_id = a.id,
                .credits_remaining = a.credits_remaining,
            } });
            n += 1;
        }
        if (n > 0) {
            try self.flushLocked();
            self.credits_checkpointed += n;
        }
        return n;
    }

    fn writeLocked(self: *Control, p: event.Payload) Error!void {
        var buf: [event.max_event_bytes]u8 = undefined;
        const bytes = try event.encode(p, &buf);
        try os.pwriteAll(self.log_fd, bytes, self.log_bytes);
        self.log_bytes += bytes.len;
    }

    fn flushLocked(self: *Control) Error!void {
        try os.fsyncCounted(self.log_fd);
    }

    fn appendLocked(self: *Control, p: event.Payload) Error!void {
        const before = self.log_bytes;
        errdefer self.log_bytes = before;
        try self.writeLocked(p);
        try self.flushLocked();
    }

    /// What a rewrite would produce: exactly the live image, nothing historical.
    fn imageBytesLocked(self: *Control) u64 {
        var total: u64 = 0;
        var ait = self.accounts.valueIterator();
        while (ait.next()) |a| {
            total += (event.Payload{ .account_created = .{
                .account_id = a.id,
                .created_at = a.created_at,
                .credits_granted = a.credits_granted,
                .plan = a.plan,
                .state = a.state,
                .email = a.email,
            } }).encodedLen();
            total += (event.Payload{ .credits_checkpoint = .{
                .account_id = a.id,
                .credits_remaining = a.credits_remaining,
            } }).encodedLen();
        }
        var kit = self.keys.valueIterator();
        while (kit.next()) |k| {
            if (k.revoked) continue;
            total += (event.Payload{ .key_created = .{
                .key_id = k.id,
                .account_id = k.account_id,
                .created_at = k.created_at,
                .hash = k.hash,
                .label = k.label,
            } }).encodedLen();
        }
        return total;
    }

    /// Replaces the log with the live image.
    ///
    /// Possible only because the image fits in RAM, which is what removes the
    /// incremental-compaction problem entirely. Revoked keys are simply not written,
    /// so this is where they finally disappear.
    fn rewriteLocked(self: *Control) Error!void {
        const fd = try os.open(self.dir_fd, temp_name, .{
            .write = true,
            .create = true,
            .truncate = true,
        });
        errdefer os.close(fd);

        var offset: u64 = 0;
        var buf: [event.max_event_bytes]u8 = undefined;

        var ait = self.accounts.valueIterator();
        while (ait.next()) |a| {
            offset += (try writeAt(fd, offset, &buf, .{ .account_created = .{
                .account_id = a.id,
                .created_at = a.created_at,
                .credits_granted = a.credits_granted,
                .plan = a.plan,
                .state = a.state,
                .email = a.email,
            } }));
            offset += (try writeAt(fd, offset, &buf, .{ .credits_checkpoint = .{
                .account_id = a.id,
                .credits_remaining = a.credits_remaining,
            } }));
        }
        var kit = self.keys.valueIterator();
        while (kit.next()) |k| {
            if (k.revoked) continue;
            offset += (try writeAt(fd, offset, &buf, .{ .key_created = .{
                .key_id = k.id,
                .account_id = k.account_id,
                .created_at = k.created_at,
                .hash = k.hash,
                .label = k.label,
            } }));
        }

        // Durable before visible, visible atomically, then the directory entry made
        // durable. A reader sees the whole old log or the whole new one.
        try os.fsyncCounted(fd);
        try os.rename(self.dir_fd, temp_name, file_name);
        try os.syncDir(self.dir_fd);
        os.close(fd);

        // The old descriptor still refers to the replaced inode.
        os.close(self.log_fd);
        self.log_fd = try os.open(self.dir_fd, file_name, .{ .write = true });
        self.log_bytes = offset;
        self.rewrites += 1;

        // Revoked keys are gone from the log, so drop them from the image too.
        var doomed: [max_keys_per_account * 8][32]u8 = undefined;
        while (true) {
            var n: usize = 0;
            var it = self.keys.iterator();
            while (it.next()) |e| {
                if (!e.value_ptr.revoked) continue;
                if (n == doomed.len) break;
                doomed[n] = e.key_ptr.*;
                n += 1;
            }
            if (n == 0) break;
            for (doomed[0..n]) |hash| {
                if (self.keys.fetchRemove(hash)) |removed| self.gpa.free(removed.value.label);
            }
        }
    }

    fn writeAt(fd: os.Fd, offset: u64, buf: []u8, p: event.Payload) Error!u64 {
        const bytes = try event.encode(p, buf);
        try os.pwriteAll(fd, bytes, offset);
        return bytes.len;
    }

    /// Rebuilds the image from the log.
    ///
    /// A torn tail is truncated away rather than tolerated, so the next append
    /// starts clean — the same treatment `segment.resolveUnsealed` gives a segment
    /// whose last record was cut short by a crash.
    fn replay(self: *Control) Error!void {
        const size = try os.fileSize(self.log_fd);
        if (size == 0) return;

        const buf = try self.gpa.alloc(u8, size);
        defer self.gpa.free(buf);
        const got = try os.preadAll(self.log_fd, buf, 0);

        var offset: usize = 0;
        while (offset < got) {
            const remaining = buf[offset..got];
            const len = event.peekLength(remaining) catch break;
            if (remaining.len < len) break;
            const p = event.decode(remaining[0..len]) catch break;
            try self.applyLocked(p);
            offset += len;
        }

        self.log_bytes = offset;
        if (offset < size) try os.ftruncate(self.log_fd, offset);
    }

    /// Applies one replayed event. Called with no concurrent access, during `open`.
    fn applyLocked(self: *Control, p: event.Payload) Error!void {
        switch (p) {
            .account_created => |e| {
                const owned = try self.gpa.dupe(u8, e.email);
                errdefer self.gpa.free(owned);
                try self.accounts.ensureUnusedCapacity(self.gpa, 1);
                if (self.accounts.fetchRemove(e.account_id)) |old| self.gpa.free(old.value.email);
                self.accounts.putAssumeCapacity(e.account_id, .{
                    .id = e.account_id,
                    .created_at = e.created_at,
                    .credits_granted = e.credits_granted,
                    .credits_remaining = e.credits_granted,
                    .plan = e.plan,
                    .state = e.state,
                    .email = owned,
                });
                if (e.account_id >= self.next_account_id) self.next_account_id = e.account_id + 1;
            },
            // Absolute, so the last one seen wins and nothing compounds (D41).
            .credits_checkpoint => |e| {
                if (self.accounts.getPtr(e.account_id)) |a| {
                    a.credits_remaining = e.credits_remaining;
                    if (a.credits_remaining > a.credits_granted) a.credits_granted = a.credits_remaining;
                }
            },
            .key_created => |e| {
                const owned = try self.gpa.dupe(u8, e.label);
                errdefer self.gpa.free(owned);
                try self.keys.ensureUnusedCapacity(self.gpa, 1);
                if (self.keys.fetchRemove(e.hash)) |old| self.gpa.free(old.value.label);
                self.keys.putAssumeCapacity(e.hash, .{
                    .id = e.key_id,
                    .account_id = e.account_id,
                    .created_at = e.created_at,
                    .hash = e.hash,
                    .label = owned,
                    .revoked = false,
                });
                if (e.key_id >= self.next_key_id) self.next_key_id = e.key_id + 1;
            },
            .key_revoked => |e| {
                var it = self.keys.valueIterator();
                while (it.next()) |k| {
                    if (k.id == e.key_id) k.revoked = true;
                }
            },
        }
    }
};


// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const H = struct {
    tmp: [64]u8 = undefined,
    path: [:0]u8 = undefined,
    dir_fd: os.Fd = -1,
    mclock: clock_mod.Manual = undefined,

    pub const start_time: u32 = 1_700_000_000;

    fn init(seed: u64) !H {
        var h: H = .{};
        h.mclock = .init(start_time);
        h.path = try std.fmt.bufPrintZ(&h.tmp, "/tmp/doot_control_{d}", .{seed});
        removeTree(h.path);
        try os.mkdir(os.cwd, h.path);
        h.dir_fd = try os.openDir(os.cwd, h.path);
        return h;
    }
    fn deinit(h: *H) void {
        os.close(h.dir_fd);
        removeTree(h.path);
    }
    fn removeTree(path: [:0]const u8) void {
        const d = os.openDir(os.cwd, path) catch return;
        var it = os.DirIterator.init(d);
        var nb: [256]u8 = undefined;
        while (it.next() catch null) |e| {
            const n = std.fmt.bufPrintZ(&nb, "{s}", .{e.name}) catch continue;
            os.unlink(d, n) catch {};
        }
        os.close(d);
        _ = std.os.linux.unlinkat(os.cwd, path.ptr, std.os.linux.AT.REMOVEDIR);
    }
    fn reopen(h: *H) !*Control {
        return Control.open(testing.allocator, h.dir_fd, h.mclock.clock());
    }
};

test "an account and its key survive a reopen" {
    var h = try H.init(1);
    defer h.deinit();

    var account_id: u32 = 0;
    {
        const c = try h.reopen();
        defer c.close();
        account_id = try c.createAccount("someone@example.com", .trial, .active, 10_000);
        _ = try c.issueKey(account_id, "ci-runner", "doot_live_abc123");
    }
    {
        const c = try h.reopen();
        defer c.close();
        const auth = c.resolveKey("doot_live_abc123").?;
        try testing.expectEqual(account_id, auth.account_id);
        try testing.expectEqual(@as(u32, 10_000), auth.credits_remaining);
        try testing.expectEqual(Plan.trial, auth.plan);

        const a = c.account(account_id).?;
        try testing.expectEqualStrings("someone@example.com", a.email);
    }
}

test "an unknown key resolves to nothing" {
    var h = try H.init(2);
    defer h.deinit();
    const c = try h.reopen();
    defer c.close();

    const id = try c.createAccount("a@b.co", .trial, .active, 10);
    _ = try c.issueKey(id, "", "doot_live_real");

    try testing.expectEqual(@as(?Auth, null), c.resolveKey("doot_live_wrong"));
    try testing.expectEqual(@as(?Auth, null), c.resolveKey(""));
}

test "revocation takes effect immediately and survives a reopen" {
    var h = try H.init(3);
    defer h.deinit();

    var key_id: u32 = 0;
    {
        const c = try h.reopen();
        defer c.close();
        const id = try c.createAccount("a@b.co", .trial, .active, 10);
        key_id = try c.issueKey(id, "leaked", "doot_live_leaked");

        try testing.expect(c.resolveKey("doot_live_leaked") != null);
        try testing.expect(try c.revokeKey(key_id));
        // 06-auth.md: the table is authoritative and in memory, so there is no
        // cached authorisation to expire.
        try testing.expectEqual(@as(?Auth, null), c.resolveKey("doot_live_leaked"));

        // Revoking twice is not an error.
        try testing.expect(!(try c.revokeKey(key_id)));
        try testing.expect(!(try c.revokeKey(9999)));
    }
    {
        const c = try h.reopen();
        defer c.close();
        try testing.expectEqual(@as(?Auth, null), c.resolveKey("doot_live_leaked"));
    }
}

test "an unverified account cannot authenticate" {
    var h = try H.init(4);
    defer h.deinit();
    const c = try h.reopen();
    defer c.close();

    // What M3's email signup creates before the OTP is confirmed.
    const id = try c.createAccount("pending@example.com", .trial, .pending_verification, 0);
    _ = try c.issueKey(id, "", "doot_live_pending");
    try testing.expectEqual(@as(?Auth, null), c.resolveKey("doot_live_pending"));
}

test "an account is held to five keys" {
    var h = try H.init(5);
    defer h.deinit();
    const c = try h.reopen();
    defer c.close();

    const id = try c.createAccount("a@b.co", .trial, .active, 10);
    var buf: [32]u8 = undefined;
    for (0..max_keys_per_account) |i| {
        const plain = try std.fmt.bufPrint(&buf, "doot_live_{d}", .{i});
        _ = try c.issueKey(id, "", plain);
    }
    try testing.expectError(error.KeyLimitReached, c.issueKey(id, "", "doot_live_toomany"));

    // Revoking frees a slot, which is how rotation works.
    try testing.expect(try c.revokeKey(1));
    _ = try c.issueKey(id, "", "doot_live_rotated");
}

test "credits spend to exhaustion and refund no further than granted" {
    var h = try H.init(6);
    defer h.deinit();
    const c = try h.reopen();
    defer c.close();

    const id = try c.createAccount("a@b.co", .trial, .active, 2);
    try testing.expectEqual(Spend.spent, c.spendCredit(id));
    try testing.expectEqual(Spend.spent, c.spendCredit(id));
    try testing.expectEqual(Spend.exhausted, c.spendCredit(id));

    // A failed write refunds, so it costs nothing (03-data-model.md).
    c.refundCredit(id);
    try testing.expectEqual(@as(u32, 1), c.account(id).?.credits_remaining);

    // Refunding beyond the grant would mint credits.
    c.refundCredit(id);
    c.refundCredit(id);
    try testing.expectEqual(@as(u32, 2), c.account(id).?.credits_remaining);

    try testing.expectEqual(Spend.no_account, c.spendCredit(9999));
}

test "an unclean restart rewinds credits and never overcharges" {
    // D41's invariant, from the only direction that matters: a deduction must never
    // be durable unless the write it paid for is. Losing deductions hands back a few
    // free writes; the reverse would charge for writes that never landed.
    var h = try H.init(7);
    defer h.deinit();

    var id: u32 = 0;
    {
        const c = try h.reopen();
        // Abandoned, not closed: no checkpoint, which is what a crash looks like.
        defer c.abandon();

        id = try c.createAccount("a@b.co", .trial, .active, 100);
        _ = try c.maintain(); // checkpoint at 100
        for (0..10) |_| try testing.expectEqual(Spend.spent, c.spendCredit(id));
        try testing.expectEqual(@as(u32, 90), c.account(id).?.credits_remaining);
    }
    {
        const c = try h.reopen();
        defer c.close();
        // Rewound to the last checkpoint. Ten writes were free; none was charged
        // for and then lost.
        try testing.expectEqual(@as(u32, 100), c.account(id).?.credits_remaining);
    }
}

test "a clean shutdown makes balances exact" {
    var h = try H.init(8);
    defer h.deinit();

    var id: u32 = 0;
    {
        const c = try h.reopen();
        defer c.close(); // checkpoints
        id = try c.createAccount("a@b.co", .trial, .active, 100);
        for (0..10) |_| _ = c.spendCredit(id);
    }
    {
        const c = try h.reopen();
        defer c.close();
        try testing.expectEqual(@as(u32, 90), c.account(id).?.credits_remaining);
    }
}

test "a granted purchase survives even an unclean restart" {
    var h = try H.init(9);
    defer h.deinit();

    var id: u32 = 0;
    {
        const c = try h.reopen();
        defer c.abandon();
        id = try c.createAccount("a@b.co", .paid, .active, 100);
        // Logged, unlike a deduction: a purchase must not evaporate.
        try testing.expectEqual(@as(u32, 5_100), try c.grantCredits(id, 5_000));
    }
    {
        const c = try h.reopen();
        defer c.close();
        try testing.expectEqual(@as(u32, 5_100), c.account(id).?.credits_remaining);
        try testing.expectEqual(@as(u32, 5_100), c.account(id).?.credits_granted);
    }
}

test "a torn tail is truncated and everything before it survives" {
    var h = try H.init(10);
    defer h.deinit();

    var id: u32 = 0;
    var good_bytes: u64 = 0;
    {
        const c = try h.reopen();
        defer c.abandon();
        id = try c.createAccount("a@b.co", .trial, .active, 10);
        _ = try c.issueKey(id, "keep", "doot_live_keep");
        good_bytes = c.log_bytes;
    }

    // Half an event, as a crash mid-append would leave.
    {
        const fd = try os.open(h.dir_fd, file_name, .{ .write = true });
        defer os.close(fd);
        var junk: [7]u8 = @splat(0xAB);
        try os.pwriteAll(fd, &junk, good_bytes);
    }

    const c = try h.reopen();
    defer c.close();
    try testing.expect(c.resolveKey("doot_live_keep") != null);
    // The tail is gone, so the next append starts clean rather than after garbage.
    try testing.expectEqual(good_bytes, c.log_bytes);
}

test "a whole-event corruption stops replay at that point" {
    var h = try H.init(11);
    defer h.deinit();

    var first_len: u64 = 0;
    {
        const c = try h.reopen();
        defer c.abandon();
        const id = try c.createAccount("first@b.co", .trial, .active, 10);
        first_len = c.log_bytes;
        _ = try c.issueKey(id, "second", "doot_live_second");
    }

    // Corrupt the second event's payload.
    {
        const fd = try os.open(h.dir_fd, file_name, .{ .write = true });
        defer os.close(fd);
        var flip: [1]u8 = undefined;
        _ = try os.preadAll(fd, &flip, first_len + event.header_bytes + 2);
        flip[0] ^= 0xFF;
        try os.pwriteAll(fd, &flip, first_len + event.header_bytes + 2);
    }

    const c = try h.reopen();
    defer c.close();
    // The account before the damage is intact; the key after it is not, and is not
    // half-applied either.
    try testing.expectEqual(@as(u64, 1), c.stats().accounts);
    try testing.expectEqual(@as(?Auth, null), c.resolveKey("doot_live_second"));
    try testing.expectEqual(first_len, c.log_bytes);
}

/// Checkpoints needed to push the log past its rewrite threshold, derived from the
/// constants rather than guessed — otherwise a change to either one would silently
/// stop these tests exercising the rewrite path at all.
fn checkpointsToRewrite() usize {
    const per = (event.Payload{ .credits_checkpoint = .{
        .account_id = 0,
        .credits_remaining = 0,
    } }).encodedLen();
    return @intCast(rewrite_multiple * rewrite_floor_bytes / per + 16);
}

test "the log is rewritten wholesale once it outgrows its image" {
    var h = try H.init(12);
    defer h.deinit();
    const c = try h.reopen();
    defer c.close();

    const id = try c.createAccount("a@b.co", .trial, .active, 1_000_000);
    _ = try c.issueKey(id, "only", "doot_live_only");

    // Checkpoints are what make the log outgrow its image: each one appends a
    // balance that the next supersedes, so the log grows while the image does not.
    var rewritten = false;
    for (0..checkpointsToRewrite()) |_| {
        _ = c.spendCredit(id);
        const m = try c.maintain();
        if (m.rewritten) {
            rewritten = true;
            break;
        }
    }
    try testing.expect(rewritten);

    const s = c.stats();
    try testing.expectEqual(@as(u64, 1), s.rewrites);
    // A rewrite leaves exactly the image, so the log can no longer be 8x it.
    try testing.expect(s.log_bytes <= rewrite_multiple * @max(s.image_bytes, rewrite_floor_bytes));
    // And the state is unchanged by the rewrite.
    try testing.expect(c.resolveKey("doot_live_only") != null);
}

test "a rewrite drops revoked keys for good, and replays identically" {
    var h = try H.init(13);
    defer h.deinit();

    var id: u32 = 0;
    var remaining: u32 = 0;
    {
        const c = try h.reopen();
        defer c.close();

        id = try c.createAccount("a@b.co", .paid, .active, 1_000_000);
        const doomed = try c.issueKey(id, "old", "doot_live_old");
        _ = try c.issueKey(id, "new", "doot_live_new");
        try testing.expect(try c.revokeKey(doomed));

        var rewritten = false;
        for (0..checkpointsToRewrite()) |_| {
            _ = c.spendCredit(id);
            if ((try c.maintain()).rewritten) {
                rewritten = true;
                break;
            }
        }
        try testing.expect(rewritten);

        // Gone from the log, so gone from the image too.
        try testing.expectEqual(@as(u64, 0), c.stats().keys_revoked);
        try testing.expectEqual(@as(u64, 1), c.stats().keys_live);
        remaining = c.account(id).?.credits_remaining;
    }
    {
        const c = try h.reopen();
        defer c.close();
        try testing.expectEqual(@as(u64, 1), c.stats().keys_live);
        try testing.expectEqual(@as(u64, 0), c.stats().keys_revoked);
        try testing.expect(c.resolveKey("doot_live_new") != null);
        // A revoked key stays revoked after its event has been rewritten away.
        try testing.expectEqual(@as(?Auth, null), c.resolveKey("doot_live_old"));
        try testing.expectEqual(remaining, c.account(id).?.credits_remaining);
    }
}

test "an empty log opens clean" {
    var h = try H.init(14);
    defer h.deinit();
    const c = try h.reopen();
    defer c.close();

    const s = c.stats();
    try testing.expectEqual(@as(u64, 0), s.accounts);
    try testing.expectEqual(@as(u64, 0), s.log_bytes);
    try testing.expectEqual(@as(?Auth, null), c.resolveKey("doot_live_anything"));
}

test "ids keep ascending across a reopen" {
    var h = try H.init(15);
    defer h.deinit();

    var second: u32 = 0;
    {
        const c = try h.reopen();
        defer c.close();
        const first = try c.createAccount("one@b.co", .trial, .active, 1);
        _ = try c.issueKey(first, "", "doot_live_one");
        second = first;
    }
    {
        const c = try h.reopen();
        defer c.close();
        const third = try c.createAccount("two@b.co", .trial, .active, 1);
        // Never reused, so a stale reference can never silently address a new
        // account.
        try testing.expect(third > second);
        _ = try c.issueKey(third, "", "doot_live_two");
        try testing.expectEqual(@as(u64, 2), c.stats().keys_live);
    }
}

test "the same plaintext cannot be registered twice" {
    var h = try H.init(16);
    defer h.deinit();
    const c = try h.reopen();
    defer c.close();

    const a = try c.createAccount("a@b.co", .trial, .active, 1);
    const b = try c.createAccount("b@b.co", .trial, .active, 1);
    _ = try c.issueKey(a, "", "doot_live_same");
    // Would otherwise let one account's key resolve to another's data.
    try testing.expectError(error.KeyAlreadyExists, c.issueKey(b, "", "doot_live_same"));
}

test "a key is rejected for an account that does not exist" {
    var h = try H.init(17);
    defer h.deinit();
    const c = try h.reopen();
    defer c.close();
    try testing.expectError(error.AccountNotFound, c.issueKey(404, "", "doot_live_x"));
    try testing.expectError(error.AccountNotFound, c.grantCredits(404, 1));
}

test "an invalid email is refused before anything is written" {
    var h = try H.init(18);
    defer h.deinit();
    const c = try h.reopen();
    defer c.close();

    try testing.expectError(error.EmailInvalid, c.createAccount("", .trial, .active, 1));
    try testing.expectError(error.EmailInvalid, c.createAccount("e" ** 255, .trial, .active, 1));
    try testing.expectError(error.LabelTooLong, c.issueKey(1, "l" ** 65, "doot_live_x"));
    try testing.expectEqual(@as(u64, 0), c.stats().log_bytes);
}

test "the log lives beside the segments without confusing them" {
    // CONTROL sits in the data directory, which is only safe because segment
    // discovery skips filenames it does not recognise rather than unlinking them.
    var h = try H.init(19);
    defer h.deinit();
    {
        const c = try h.reopen();
        defer c.close();
        _ = try c.createAccount("a@b.co", .trial, .active, 1);
    }
    try testing.expect(!(try storage.segment.anySegments(h.dir_fd)));

    const s = try storage.Store.open(testing.allocator, h.dir_fd, h.mclock.clock(), .{});
    defer s.close();
    _ = try s.put(1, "entry", "body", "", &.{}, 3600);

    const c = try h.reopen();
    defer c.close();
    try testing.expectEqual(@as(u64, 1), c.stats().accounts);
}


// ---------------------------------------------------------------------------
// The pooled rate-limit bucket (D6, D58)
// ---------------------------------------------------------------------------

test "a fresh account starts with a full bucket" {
    var h = try H.init(40);
    defer h.deinit();
    const c = try h.reopen();
    defer c.close();

    const id = try c.createAccount("a@b.co", .trial, .active, 10);
    const lim = plan_mod.limits(.trial);

    // The very first request must not be rate limited by an empty bucket — the
    // zero-initialised state has to read as "full", not as "nothing accrued yet".
    const first = c.takeToken(id).?;
    try testing.expect(first.allowed);
    try testing.expectEqual(lim.rate_per_min, first.limit);
    try testing.expectEqual(lim.burst - 1, first.remaining);
    try testing.expectEqual(@as(u32, 0), first.retry_after_s);
}

test "the burst is spendable at once, and then the bucket is empty" {
    var h = try H.init(41);
    defer h.deinit();
    const c = try h.reopen();
    defer c.close();

    const id = try c.createAccount("a@b.co", .trial, .active, 10);
    const burst = plan_mod.limits(.trial).burst;

    // No clock movement at all, so nothing refills: exactly `burst` succeed.
    for (0..burst) |i| {
        const d = c.takeToken(id).?;
        try testing.expect(d.allowed);
        try testing.expectEqual(burst - 1 - @as(u32, @intCast(i)), d.remaining);
    }

    const refused = c.takeToken(id).?;
    try testing.expect(!refused.allowed);
    try testing.expectEqual(@as(u32, 0), refused.remaining);
    // A client honouring this must not come back too early, so it rounds up.
    try testing.expect(refused.retry_after_s >= 1);
}

test "an empty bucket refills at the sustained rate" {
    var h = try H.init(42);
    defer h.deinit();
    const c = try h.reopen();
    defer c.close();

    const id = try c.createAccount("a@b.co", .trial, .active, 10);
    const lim = plan_mod.limits(.trial);
    for (0..lim.burst) |_| _ = c.takeToken(id);
    try testing.expect(!c.takeToken(id).?.allowed);

    // Trial refills at 100/60 ≈ 1.667 tokens a second, so one second is enough for one.
    h.mclock.advance(1);
    try testing.expect(c.takeToken(id).?.allowed);

    // Six seconds accrues ten tokens; nine of them survive the one taken here.
    for (0..lim.burst) |_| _ = c.takeToken(id);
    h.mclock.advance(6);
    const d = c.takeToken(id).?;
    try testing.expect(d.allowed);
    try testing.expectEqual(@as(u32, 9), d.remaining);
}

test "a full bucket takes exactly the quoted window to refill" {
    var h = try H.init(43);
    defer h.deinit();
    const c = try h.reopen();
    defer c.close();

    const id = try c.createAccount("a@b.co", .trial, .active, 10);
    const burst = plan_mod.limits(.trial).burst;
    for (0..burst) |_| _ = c.takeToken(id);

    // Drained, so reset is the whole window: this is what RateLimit-Reset publishes.
    const drained = c.takeToken(id).?;
    try testing.expectEqual(@as(u32, 60), drained.reset_s);

    h.mclock.advance(60);
    const refilled = c.takeToken(id).?;
    try testing.expect(refilled.allowed);
    try testing.expectEqual(burst - 1, refilled.remaining);
}

test "the bucket never accrues past its burst, however long it idles" {
    var h = try H.init(44);
    defer h.deinit();
    const c = try h.reopen();
    defer c.close();

    const id = try c.createAccount("a@b.co", .trial, .active, 10);
    const burst = plan_mod.limits(.trial).burst;

    // A week of idleness must not bank a week of requests.
    h.mclock.advance(7 * 24 * 60 * 60);
    const d = c.takeToken(id).?;
    try testing.expectEqual(burst - 1, d.remaining);

    var allowed: u32 = 1;
    while (c.takeToken(id).?.allowed) allowed += 1;
    try testing.expectEqual(burst, allowed);
}

test "a paid account gets the larger bucket" {
    var h = try H.init(45);
    defer h.deinit();
    const c = try h.reopen();
    defer c.close();

    const trial = try c.createAccount("t@b.co", .trial, .active, 10);
    const paid = try c.createAccount("p@b.co", .paid, .active, 10);

    try testing.expectEqual(@as(u32, 100), c.takeToken(trial).?.limit);
    try testing.expectEqual(@as(u32, 500), c.takeToken(paid).?.limit);

    var trial_allowed: u32 = 1;
    while (c.takeToken(trial).?.allowed) trial_allowed += 1;
    var paid_allowed: u32 = 1;
    while (c.takeToken(paid).?.allowed) paid_allowed += 1;

    try testing.expectEqual(@as(u32, 100), trial_allowed);
    try testing.expectEqual(@as(u32, 500), paid_allowed);
}

test "all of an account's keys draw on one bucket" {
    var h = try H.init(46);
    defer h.deinit();
    const c = try h.reopen();
    defer c.close();

    const id = try c.createAccount("a@b.co", .trial, .active, 10);
    _ = try c.issueKey(id, "one", "doot_live_one");
    _ = try c.issueKey(id, "two", "doot_live_two");

    // D6's whole point: five keys must not be five times the limit. The bucket is keyed
    // on the account, so which key resolved is irrelevant.
    const first = c.resolveKey("doot_live_one").?;
    const second = c.resolveKey("doot_live_two").?;
    try testing.expectEqual(first.account_id, second.account_id);

    const burst = plan_mod.limits(.trial).burst;
    var allowed: u32 = 0;
    while (c.takeToken(second.account_id).?.allowed) allowed += 1;
    try testing.expectEqual(burst, allowed);
}

test "two accounts do not share a bucket" {
    var h = try H.init(47);
    defer h.deinit();
    const c = try h.reopen();
    defer c.close();

    const a = try c.createAccount("a@b.co", .trial, .active, 10);
    const b = try c.createAccount("b@b.co", .trial, .active, 10);

    while (c.takeToken(a).?.allowed) {}
    try testing.expect(!c.takeToken(a).?.allowed);
    // b is untouched.
    try testing.expect(c.takeToken(b).?.allowed);
}

test "a clock that steps backwards neither grants tokens nor trips an overflow" {
    var h = try H.init(48);
    defer h.deinit();
    const c = try h.reopen();
    defer c.close();

    const id = try c.createAccount("a@b.co", .trial, .active, 10);
    h.mclock.advance(1000);
    while (c.takeToken(id).?.allowed) {}

    // Wall clock corrections happen. Saturating subtraction makes this no refill rather
    // than a negative elapsed time, and erring toward refusing is the safe direction.
    h.mclock.set(H.start_time);
    try testing.expect(!c.takeToken(id).?.allowed);

    // And the bucket still works once time moves forward again.
    h.mclock.advance(60);
    try testing.expect(c.takeToken(id).?.allowed);
}

test "an unknown account has no bucket" {
    var h = try H.init(49);
    defer h.deinit();
    const c = try h.reopen();
    defer c.close();
    try testing.expectEqual(@as(?Control.RateDecision, null), c.takeToken(999));
}

test "a replayed account's bucket behaves like a fresh one" {
    var h = try H.init(50);
    defer h.deinit();

    var id: u32 = 0;
    {
        const c = try h.reopen();
        defer c.close();
        id = try c.createAccount("a@b.co", .trial, .active, 10);
        while (c.takeToken(id).?.allowed) {}
    }
    {
        // Bucket state is RAM-only and is not in the log, so a restart hands back a full
        // bucket. That is the same posture as idempotency state (D42) and errs in the
        // caller's favour, which is the only direction a rate limit may err on restart.
        const c = try h.reopen();
        defer c.close();
        const d = c.takeToken(id).?;
        try testing.expect(d.allowed);
        try testing.expectEqual(plan_mod.limits(.trial).burst - 1, d.remaining);
    }
}
