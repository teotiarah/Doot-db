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

/// `06-auth.md`: unverified accounts are deleted after 7 days.
pub const pending_verification_ttl_s: u32 = 7 * 24 * 60 * 60;

/// `06-auth.md`: sessions last 30 days, sliding.
pub const session_lifetime_s: u32 = 30 * 24 * 60 * 60;

/// `06-auth.md`: refreshed on use once over 24 hours old. The threshold exists so that a
/// busy dashboard does not move the expiry on every single request.
pub const session_refresh_after_s: u32 = 24 * 60 * 60;

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
    PasswordHashTooLong,
    SessionAlreadyExists,
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

    /// The control plane's own bucket, on the same account and behind the same mutex
    /// (D74). Separate from the pooled data-plane bucket above because exploring your
    /// data in the dashboard must not be able to exhaust the bucket a production script
    /// depends on — which is a product requirement, not a tuning choice
    /// (`01-product.md`).
    ctl_tokens: f64 = 0,
    ctl_tokens_at: u32 = 0,
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

pub const AnchorKind = event.AnchorKind;

/// An Argon2id hash and when it was set. Last write wins, so a password change is one
/// more append rather than a rewrite (D70, D71).
pub const Password = struct {
    /// PHC string, owned by the store. Carries the parameters it was made with, which
    /// is what allows them to be raised later without invalidating this hash.
    phc: []const u8,
    set_at: u32,
};

/// A dashboard session. The token itself is never stored — only its digest, exactly as
/// with an API key (`06-auth.md`).
pub const Session = struct {
    id: u32,
    account_id: u32,
    token_hash: [32]u8,
    created_at: u32,
    /// Slides on use. Authoritative in RAM and checkpointed, so a crash loses the most
    /// recent extensions and the session expires *earlier* than it would have — the
    /// mirror of D41, where a crash loses recent deductions and the customer gains
    /// (D70, as amended).
    expires_at: u32,
};

// The synchroniser token for state-changing control-plane requests is deliberately
// **not** a field here. It is derived in the service layer as a keyed hash of the
// session digest under `DOOT_HMAC_SECRET`, which means it needs no storage, no event
// type and no checkpoint, and it survives a restart without the log carrying it. The
// control plane owns sessions; CSRF is a property of the HTTP surface, and D73 puts
// that in the service layer.

/// An identity-anchor claim, keyed on kind and digest together.
///
/// Two kinds rather than one combined identity: a GitHub signup has no verified email
/// at the moment it claims, and an email signup never has a GitHub id (D72).
pub const AnchorId = struct {
    kind: AnchorKind,
    hash: [32]u8,
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
    passwords: u64,
    sessions: u64,
    anchors: u64,
    github_links: u64,
    sessions_checkpointed: u64,
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

/// Buckets on the digest and compares byte-wise.
///
/// Deliberately *not* constant-time, unlike `KeyContext`. An anchor digest is never
/// presented by a caller — it is derived server-side from an address the caller already
/// knows they typed — so there is no secret to leak by comparison timing. What an
/// attacker could probe here is whether an address is registered, and that is defended
/// where it actually matters: the response is identical either way and the request pays
/// a full Argon2id verification regardless (D75), which dwarfs a 32-byte compare by
/// six orders of magnitude.
const AnchorContext = struct {
    pub fn hash(_: AnchorContext, a: AnchorId) u64 {
        return std.mem.readInt(u64, a.hash[0..8], .little) ^
            (@as(u64, @intFromEnum(a.kind)) << 56);
    }
    pub fn eql(_: AnchorContext, a: AnchorId, b: AnchorId) bool {
        return a.kind == b.kind and std.mem.eql(u8, &a.hash, &b.hash);
    }
};

const Accounts = std.AutoHashMapUnmanaged(u32, Account);
const Keys = std.HashMapUnmanaged([32]u8, ApiKey, KeyContext, 80);
const Passwords = std.AutoHashMapUnmanaged(u32, Password);
/// Keyed on the token digest, and sharing `KeyContext` because a session token is a
/// credential presented by the caller and must be compared in constant time.
const Sessions = std.HashMapUnmanaged([32]u8, Session, KeyContext, 80);
const Anchors = std.HashMapUnmanaged(AnchorId, u32, AnchorContext, 80);
const GithubLinks = std.AutoHashMapUnmanaged(u64, u32);

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
    passwords: Passwords = .empty,
    sessions: Sessions = .empty,
    anchors: Anchors = .empty,
    github: GithubLinks = .empty,
    next_account_id: u32 = 1,
    next_key_id: u32 = 1,
    next_session_id: u32 = 1,

    rewrites: u64 = 0,
    credits_checkpointed: u64 = 0,
    sessions_checkpointed: u64 = 0,

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
        // Sessions get the same treatment for the same reason: without this every
        // deploy would rewind every session's sliding expiry to whatever the last
        // periodic checkpoint caught, silently shortening the window `06-auth.md`
        // publishes (D70).
        _ = self.checkpointSessionsLocked() catch {};
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

        var pit = self.passwords.valueIterator();
        while (pit.next()) |p| self.gpa.free(p.phc);
        self.passwords.deinit(self.gpa);

        // Sessions, anchors and links own no allocations of their own.
        self.sessions.deinit(self.gpa);
        self.anchors.deinit(self.gpa);
        self.github.deinit(self.gpa);
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

    /// The balance now, for the header every write response carries.
    ///
    /// Read after the deduction rather than derived from the `Auth` snapshot taken at
    /// resolve time, because a concurrent write on another key of the same account moves it
    /// — and `X-Doot-Credits-Remaining` is the number that stops the wall being a surprise
    /// (`01-product.md`), so a stale one is worse than none.
    pub fn creditsRemaining(self: *Control, account_id: u32) u32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const a = self.accounts.get(account_id) orelse return 0;
        return a.credits_remaining;
    }

    /// One key by id, for `GET /v1/whoami` to report which key was presented.
    ///
    /// Keyed by id rather than by hash, because the request path already resolved the
    /// hash and carries the id — looking it up by digest again would mean hashing the
    /// caller's key a second time to answer a question we already know the answer to.
    ///
    /// `label` borrows the store's copy, owned for the key's lifetime, like `Account.email`.
    pub fn key(self: *Control, key_id: u32) ?ApiKey {
        self.mutex.lock();
        defer self.mutex.unlock();

        var it = self.keys.valueIterator();
        while (it.next()) |k| {
            if (k.id == key_id) return k.*;
        }
        return null;
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

    // -----------------------------------------------------------------------
    // Passwords, activation and deletion (D70, D71, D77)
    // -----------------------------------------------------------------------

    /// Records an Argon2id PHC string for an account. Last write wins, so this is both
    /// "set" and "change".
    ///
    /// The store never hashes or verifies a password: that is CPU-bound work which by
    /// D71 belongs on an I/O worker, and putting it behind this mutex would block every
    /// key lookup for ~100 ms.
    pub fn setPassword(self: *Control, account_id: u32, phc: []const u8) Error!void {
        if (phc.len == 0 or phc.len > event.max_phc_bytes) return error.PasswordHashTooLong;

        self.mutex.lock();
        defer self.mutex.unlock();

        if (!self.accounts.contains(account_id)) return error.AccountNotFound;

        const owned = try self.gpa.dupe(u8, phc);
        errdefer self.gpa.free(owned);
        try self.passwords.ensureUnusedCapacity(self.gpa, 1);

        const now = self.clock.now();
        try self.appendLocked(.{ .password_set = .{
            .account_id = account_id,
            .set_at = now,
            .phc = phc,
        } });

        if (self.passwords.fetchRemove(account_id)) |old| self.gpa.free(old.value.phc);
        self.passwords.putAssumeCapacity(account_id, .{ .phc = owned, .set_at = now });
    }

    /// The stored hash, for a verification that happens on a worker.
    ///
    /// `phc` borrows the store's copy. A caller that will hold it across the
    /// verification must copy it first, because a concurrent password change frees this
    /// one — and a verification is exactly long enough for that to matter.
    pub fn password(self: *Control, account_id: u32) ?Password {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.passwords.get(account_id);
    }

    /// `pending_verification` → `active`, granting the recorded credits (D70).
    ///
    /// The amount is passed in rather than read from the plan table, because the caller
    /// has already evaluated the identity anchors and a match means zero regardless of
    /// plan (`06-auth.md`).
    pub fn activateAccount(self: *Control, account_id: u32, credits_granted: u32) Error!void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const a = self.accounts.getPtr(account_id) orelse return error.AccountNotFound;

        try self.appendLocked(.{ .account_activated = .{
            .account_id = account_id,
            .credits_granted = credits_granted,
        } });

        a.state = .active;
        a.credits_granted = credits_granted;
        a.credits_remaining = credits_granted;
    }

    /// Makes an account's data permanently inaccessible, immediately (D77).
    ///
    /// **This does not delete entries, and cannot.** The index is keyed on a hash of
    /// `(account_id, name)` and holds no names (D11), so nothing can enumerate an
    /// account's entries — the same property that makes cross-account addressing
    /// unrepresentable. Access ends here, at the credential, and the bytes leave with
    /// their expiry, bounded by the plan's maximum lifetime.
    ///
    /// Returns false when the account is already gone, so deleting twice is not an error.
    pub fn deleteAccount(self: *Control, account_id: u32) Error!bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (!self.accounts.contains(account_id)) return false;

        try self.appendLocked(.{ .account_deleted = .{
            .account_id = account_id,
            .deleted_at = self.clock.now(),
        } });
        self.purgeAccountLocked(account_id);
        return true;
    }

    // -----------------------------------------------------------------------
    // Identity anchors and GitHub links (D72)
    // -----------------------------------------------------------------------

    /// Records a claim on an anchor, or reports who already holds it.
    ///
    /// Returns the owning account id — `account_id` when the claim is new, and the
    /// existing owner when it is not. **First claim wins**, which is what makes the
    /// trial grant one-time: the caller grants credits only when the returned id is its
    /// own.
    ///
    /// Idempotent, so a retried activation cannot hand out a second grant.
    pub fn claimAnchor(
        self: *Control,
        kind: AnchorKind,
        hash: [32]u8,
        account_id: u32,
    ) Error!u32 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const id: AnchorId = .{ .kind = kind, .hash = hash };
        if (self.anchors.get(id)) |owner| return owner;

        try self.anchors.ensureUnusedCapacity(self.gpa, 1);
        try self.appendLocked(.{ .anchor_claimed = .{
            .kind = kind,
            .hash = hash,
            .account_id = account_id,
        } });
        self.anchors.putAssumeCapacity(id, account_id);
        return account_id;
    }

    /// Visits every account, so a caller can build an index this module cannot.
    ///
    /// Login has to find an account from an email address, and the normalisation that makes
    /// that work — lowercasing, plus-stripping, the Gmail fold (D72) — lives in `api`, which
    /// `control` does not and must not import. So the index is **derived state owned by the
    /// layer that can compute it**: the service builds it at boot from this iteration and
    /// maintains it on signup.
    ///
    /// Deriving it rather than logging it is what keeps the log unchanged. The alternative
    /// was widening `account_created` with a 32-byte anchor and bumping its version — a
    /// permanent wire change to serve an index that costs one pass over an in-RAM map at
    /// startup, which D40 already establishes is single-digit megabytes at ten thousand
    /// accounts.
    ///
    /// The callback runs **with the mutex held**, so it must not call back into `Control`.
    /// It is given a copy rather than a pointer for the same reason.
    pub fn forEachAccount(
        self: *Control,
        ctx: anytype,
        comptime visit: fn (@TypeOf(ctx), Account) void,
    ) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var it = self.accounts.valueIterator();
        while (it.next()) |a| visit(ctx, a.*);
    }

    /// Who holds an anchor, without claiming it.
    pub fn anchorOwner(self: *Control, kind: AnchorKind, hash: [32]u8) ?u32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.anchors.get(.{ .kind = kind, .hash = hash });
    }

    /// Routes a GitHub identity to an account. Keyed on the numeric user id, never the
    /// username, because usernames can be changed and reused (`06-auth.md`).
    pub fn linkGithub(self: *Control, account_id: u32, github_user_id: u64) Error!void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (!self.accounts.contains(account_id)) return error.AccountNotFound;

        try self.github.ensureUnusedCapacity(self.gpa, 1);
        try self.appendLocked(.{ .github_linked = .{
            .account_id = account_id,
            .github_user_id = github_user_id,
        } });
        self.github.putAssumeCapacity(github_user_id, account_id);
    }

    pub fn githubOwner(self: *Control, github_user_id: u64) ?u32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.github.get(github_user_id);
    }

    // -----------------------------------------------------------------------
    // Sessions (D70)
    // -----------------------------------------------------------------------

    /// What the control plane needs from a presented session cookie, in one lookup.
    pub const SessionAuth = struct {
        session_id: u32,
        account_id: u32,
        plan: Plan,
        expires_at: u32,
    };

    /// Creates a session for an account and returns its id. The caller generates the
    /// opaque token; only its digest is kept, exactly as with an API key.
    pub fn createSession(self: *Control, account_id: u32, token: []const u8) Error!u32 {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (!self.accounts.contains(account_id)) return error.AccountNotFound;
        if (self.next_session_id == std.math.maxInt(u32)) return error.IdSpaceExhausted;

        const hash = hashKey(token);
        if (self.sessions.contains(hash)) return error.SessionAlreadyExists;

        const id = self.next_session_id;
        const now = self.clock.now();
        try self.sessions.ensureUnusedCapacity(self.gpa, 1);

        try self.appendLocked(.{ .session_created = .{
            .session_id = id,
            .account_id = account_id,
            .token_hash = hash,
            .created_at = now,
            .expires_at = now +| session_lifetime_s,
        } });

        self.sessions.putAssumeCapacity(hash, .{
            .id = id,
            .account_id = account_id,
            .token_hash = hash,
            .created_at = now,
            .expires_at = now +| session_lifetime_s,
        });
        self.next_session_id = id + 1;
        return id;
    }

    /// The control plane's authentication step, and the sliding refresh in one call.
    ///
    /// Unknown, expired, deleted and not-yet-verified all return null, so this is no
    /// more an enumeration oracle than `resolveKey` is.
    ///
    /// **The refresh happens here, in memory only.** `06-auth.md` says a session is
    /// refreshed on use once it is over 24 hours old, and doing it at the point of use is
    /// the only place that knows it was used. It is not logged — that would be a log
    /// write per dashboard request — and rides `sessions_checkpoint` instead (D70).
    pub fn resolveSession(self: *Control, token: []const u8) ?SessionAuth {
        const hash = hashKey(token);

        self.mutex.lock();
        defer self.mutex.unlock();

        const s = self.sessions.getPtr(hash) orelse return null;
        const now = self.clock.now();
        if (s.expires_at <= now) return null;

        const a = self.accounts.get(s.account_id) orelse return null;
        if (a.state != .active) return null;

        if (now -| s.created_at >= session_refresh_after_s) {
            s.expires_at = now +| session_lifetime_s;
        }

        return .{
            .session_id = s.id,
            .account_id = a.id,
            .plan = a.plan,
            .expires_at = s.expires_at,
        };
    }

    /// Logout. Immediate and server-side, which is the whole reason sessions are opaque
    /// tokens rather than signed ones (`06-auth.md`).
    pub fn revokeSession(self: *Control, session_id: u32) Error!bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        var found = false;
        var it = self.sessions.valueIterator();
        while (it.next()) |s| {
            if (s.id == session_id) {
                found = true;
                break;
            }
        }
        if (!found) return false;

        try self.appendLocked(.{ .session_revoked = .{ .session_id = session_id } });
        self.dropSessionLocked(session_id);
        return true;
    }

    /// Invalidates every session for an account, which is what a password change and a
    /// completed reset both require (`06-auth.md`).
    pub fn revokeSessionsFor(self: *Control, account_id: u32) Error!usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        var n: usize = 0;
        var ids: [64]u32 = undefined;
        while (true) {
            var found: usize = 0;
            var it = self.sessions.valueIterator();
            while (it.next()) |s| {
                if (s.account_id != account_id) continue;
                if (found == ids.len) break;
                ids[found] = s.id;
                found += 1;
            }
            if (found == 0) break;
            for (ids[0..found]) |id| {
                try self.writeLocked(.{ .session_revoked = .{ .session_id = id } });
                self.dropSessionLocked(id);
            }
            n += found;
        }
        // One flush for the batch: a password change invalidating five sessions should
        // not pay five fsyncs.
        if (n > 0) try self.flushLocked();
        return n;
    }

    /// Takes one token from the account's **control-plane** bucket (D74).
    ///
    /// Separate from `takeToken` rather than parameterised by which bucket, because the
    /// two carry different numbers from different tables and a boolean argument at every
    /// call site is how the wrong bucket eventually gets charged.
    pub fn takeControlToken(self: *Control, account_id: u32) ?RateDecision {
        self.mutex.lock();
        defer self.mutex.unlock();

        const a = self.accounts.getPtr(account_id) orelse return null;
        const now = self.clock.now();
        const burst: f64 = @floatFromInt(plan_mod.control_burst);
        const per_second = plan_mod.controlRefillPerSecond();

        const elapsed: f64 = @floatFromInt(now -| a.ctl_tokens_at);
        a.ctl_tokens = @min(burst, a.ctl_tokens + elapsed * per_second);
        a.ctl_tokens_at = now;

        const allowed = a.ctl_tokens >= 1.0;
        if (allowed) a.ctl_tokens -= 1.0;

        return .{
            .allowed = allowed,
            .limit = plan_mod.control_rate_per_min,
            .remaining = @intFromFloat(@floor(a.ctl_tokens)),
            .reset_s = secondsToAccrue(burst - a.ctl_tokens, per_second),
            .retry_after_s = if (allowed) 0 else secondsToAccrue(1.0 - a.ctl_tokens, per_second),
        };
    }

    pub const Maintenance = struct {
        checkpointed: usize,
        rewritten: bool,
        sessions_checkpointed: usize = 0,
        sessions_swept: usize = 0,
        unverified_swept: usize = 0,
    };

    /// Persists balances and reclaims the log. Called from the maintenance thread,
    /// on the same cadence as the storage engine's own housekeeping (D45).
    ///
    /// One flush covers every balance, so the cost does not scale with how many
    /// accounts moved.
    pub fn maintain(self: *Control) Error!Maintenance {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Sweep before checkpointing, so nothing about to be discarded is written
        // first, and before sizing the image, so the rewrite threshold is judged
        // against what a rewrite would actually produce.
        const sessions_swept = self.sweepExpiredSessionsLocked();
        const unverified_swept = try self.sweepUnverifiedAccountsLocked();

        const checkpointed = try self.checkpointCreditsLocked();
        const sessions_checkpointed = try self.checkpointSessionsLocked();

        var rewritten = false;
        const image = self.imageBytesLocked();
        if (self.log_bytes > rewrite_multiple * @max(image, rewrite_floor_bytes)) {
            try self.rewriteLocked();
            rewritten = true;
        }
        return .{
            .checkpointed = checkpointed,
            .rewritten = rewritten,
            .sessions_checkpointed = sessions_checkpointed,
            .sessions_swept = sessions_swept,
            .unverified_swept = unverified_swept,
        };
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
            .passwords = self.passwords.count(),
            .sessions = self.sessions.count(),
            .anchors = self.anchors.count(),
            .github_links = self.github.count(),
            .sessions_checkpointed = self.sessions_checkpointed,
        };
    }

    // -----------------------------------------------------------------------
    // The log
    // -----------------------------------------------------------------------

    /// One absolute expiry per live session, then a single flush.
    ///
    /// This is what makes the sliding window survive a restart (D70). Expired sessions
    /// are skipped rather than checkpointed: they are about to be swept, and writing an
    /// expiry that has already passed only makes the log longer.
    fn checkpointSessionsLocked(self: *Control) Error!usize {
        const now = self.clock.now();
        var n: usize = 0;
        var it = self.sessions.valueIterator();
        while (it.next()) |s| {
            if (s.expires_at <= now) continue;
            try self.writeLocked(.{ .sessions_checkpoint = .{
                .session_id = s.id,
                .expires_at = s.expires_at,
            } });
            n += 1;
        }
        if (n > 0) {
            try self.flushLocked();
            self.sessions_checkpointed += n;
        }
        return n;
    }

    /// Drops sessions whose expiry has passed.
    ///
    /// Expiry is already authoritative at lookup — `session()` refuses an expired one —
    /// so this is reclamation rather than enforcement, exactly as the entry store treats
    /// a dead index slot. Without it the map would grow with every login for the life of
    /// the process.
    fn sweepExpiredSessionsLocked(self: *Control) usize {
        const now = self.clock.now();
        var removed: usize = 0;
        var doomed: [64][32]u8 = undefined;
        while (true) {
            var n: usize = 0;
            var it = self.sessions.iterator();
            while (it.next()) |e| {
                if (e.value_ptr.expires_at > now) continue;
                if (n == doomed.len) break;
                doomed[n] = e.key_ptr.*;
                n += 1;
            }
            if (n == 0) return removed;
            for (doomed[0..n]) |h| _ = self.sessions.remove(h);
            removed += n;
        }
    }

    /// `06-auth.md`: unverified accounts are deleted after 7 days.
    ///
    /// Safe to purge wholesale because an anchor is claimed at *activation* (D72), so an
    /// account that never verified holds none — there is nothing here that must outlive
    /// the account, which is the one thing deletion has to be careful about (D77).
    fn sweepUnverifiedAccountsLocked(self: *Control) Error!usize {
        const now = self.clock.now();
        var removed: usize = 0;
        var doomed: [64]u32 = undefined;
        while (true) {
            var n: usize = 0;
            var it = self.accounts.valueIterator();
            while (it.next()) |a| {
                if (a.state != .pending_verification) continue;
                if (now -| a.created_at < pending_verification_ttl_s) continue;
                if (n == doomed.len) break;
                doomed[n] = a.id;
                n += 1;
            }
            if (n == 0) return removed;
            for (doomed[0..n]) |id| {
                // Logged, so the purge survives a restart rather than being redone --
                // and so a replay reaches the same image without needing the clock.
                try self.writeLocked(.{ .account_deleted = .{
                    .account_id = id,
                    .deleted_at = now,
                } });
                self.purgeAccountLocked(id);
            }
            try self.flushLocked();
            removed += n;
        }
    }

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

    /// Enumerates exactly the events a rewrite writes, in replay order.
    ///
    /// **One definition, used by both `imageBytesLocked` and `rewriteLocked`.** Those
    /// two held separate copies of this list, which was survivable with four event types
    /// and is a trap with twelve: a state added to the rewrite but not to the estimate
    /// merely mis-sizes a threshold, but a state added *neither* place is silently
    /// destroyed the first time the log is reclaimed. Making the two share one
    /// enumeration means a new event type cannot be half-added.
    ///
    /// Order matters. `account_created` precedes anything referring to an account,
    /// because `applyLocked` attaches a password, a session or a checkpoint to an
    /// account that must already exist.
    fn forEachImageEvent(
        self: *Control,
        ctx: anytype,
        comptime emit: fn (@TypeOf(ctx), event.Payload) Error!void,
    ) Error!void {
        const now = self.clock.now();

        var ait = self.accounts.valueIterator();
        while (ait.next()) |a| {
            try emit(ctx, .{ .account_created = .{
                .account_id = a.id,
                .created_at = a.created_at,
                .credits_granted = a.credits_granted,
                .plan = a.plan,
                // The live state, so an activated account is written as `.active` and
                // needs no `account_activated` replayed after it.
                .state = a.state,
                .email = a.email,
            } });
            try emit(ctx, .{ .credits_checkpoint = .{
                .account_id = a.id,
                .credits_remaining = a.credits_remaining,
            } });
        }

        var pit = self.passwords.iterator();
        while (pit.next()) |e| {
            try emit(ctx, .{ .password_set = .{
                .account_id = e.key_ptr.*,
                .set_at = e.value_ptr.set_at,
                .phc = e.value_ptr.phc,
            } });
        }

        var kit = self.keys.valueIterator();
        while (kit.next()) |k| {
            if (k.revoked) continue;
            try emit(ctx, .{ .key_created = .{
                .key_id = k.id,
                .account_id = k.account_id,
                .created_at = k.created_at,
                .hash = k.hash,
                .label = k.label,
            } });
        }

        // Written with the *current* expiry, so the slide is folded in and no
        // `sessions_checkpoint` is needed after it. An already-expired session is
        // dropped here, which is where dead sessions finally leave the log — the same
        // treatment a revoked key gets.
        var sit = self.sessions.valueIterator();
        while (sit.next()) |s| {
            if (s.expires_at <= now) continue;
            try emit(ctx, .{ .session_created = .{
                .session_id = s.id,
                .account_id = s.account_id,
                .token_hash = s.token_hash,
                .created_at = s.created_at,
                .expires_at = s.expires_at,
            } });
        }

        // Anchors outlive their accounts, so these are written whether or not the
        // account they name is still present (D77).
        var anit = self.anchors.iterator();
        while (anit.next()) |e| {
            try emit(ctx, .{ .anchor_claimed = .{
                .kind = e.key_ptr.kind,
                .hash = e.key_ptr.hash,
                .account_id = e.value_ptr.*,
            } });
        }

        var git = self.github.iterator();
        while (git.next()) |e| {
            try emit(ctx, .{ .github_linked = .{
                .account_id = e.value_ptr.*,
                .github_user_id = e.key_ptr.*,
            } });
        }
    }

    /// What a rewrite would produce: exactly the live image, nothing historical.
    fn imageBytesLocked(self: *Control) u64 {
        var total: u64 = 0;
        // Infallible, so the error union is unreachable in practice.
        self.forEachImageEvent(&total, struct {
            fn emit(acc: *u64, p: event.Payload) Error!void {
                acc.* += p.encodedLen();
            }
        }.emit) catch {};
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

        var sink: Sink = .{ .fd = fd };
        try self.forEachImageEvent(&sink, Sink.emit);
        const offset = sink.offset;

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

    /// Appends image events to a fresh file, carrying its own encode buffer so the
    /// enumeration above does not have to know it is writing to disk.
    const Sink = struct {
        fd: os.Fd,
        offset: u64 = 0,
        buf: [event.max_event_bytes]u8 = undefined,

        fn emit(s: *Sink, p: event.Payload) Error!void {
            const bytes = try event.encode(p, &s.buf);
            try os.pwriteAll(s.fd, bytes, s.offset);
            s.offset += bytes.len;
        }
    };

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
            .password_set => |e| {
                const owned = try self.gpa.dupe(u8, e.phc);
                errdefer self.gpa.free(owned);
                try self.passwords.ensureUnusedCapacity(self.gpa, 1);
                if (self.passwords.fetchRemove(e.account_id)) |old| self.gpa.free(old.value.phc);
                self.passwords.putAssumeCapacity(e.account_id, .{
                    .phc = owned,
                    .set_at = e.set_at,
                });
            },
            .session_created => |e| {
                try self.sessions.ensureUnusedCapacity(self.gpa, 1);
                _ = self.sessions.remove(e.token_hash);
                self.sessions.putAssumeCapacity(e.token_hash, .{
                    .id = e.session_id,
                    .account_id = e.account_id,
                    .token_hash = e.token_hash,
                    .created_at = e.created_at,
                    .expires_at = e.expires_at,
                });
                if (e.session_id >= self.next_session_id) self.next_session_id = e.session_id + 1;
            },
            .session_revoked => |e| self.dropSessionLocked(e.session_id),
            // Authoritative, last one wins — the same treatment `credits_checkpoint`
            // gets, and for the same reason. The safe direction is not enforced by a
            // comparison here: a crash loses the most recent checkpoints, so it loses
            // the most recent extensions, so the session expires *earlier* than it
            // would have. That falls out of checkpointing rather than being imposed on
            // it (D70, as amended). A revoked session is already gone from the image,
            // so no checkpoint can resurrect one.
            .sessions_checkpoint => |e| {
                var it = self.sessions.valueIterator();
                while (it.next()) |s| {
                    if (s.id == e.session_id) s.expires_at = e.expires_at;
                }
            },
            .anchor_claimed => |e| {
                try self.anchors.ensureUnusedCapacity(self.gpa, 1);
                const id: AnchorId = .{ .kind = e.kind, .hash = e.hash };
                // First claim wins. A later event for the same anchor would mean a
                // second account tried to claim it, and the whole point of the anchor
                // is that the first holder keeps it (`06-auth.md`).
                if (!self.anchors.contains(id)) self.anchors.putAssumeCapacity(id, e.account_id);
            },
            .github_linked => |e| {
                try self.github.ensureUnusedCapacity(self.gpa, 1);
                self.github.putAssumeCapacity(e.github_user_id, e.account_id);
            },
            .account_activated => |e| {
                if (self.accounts.getPtr(e.account_id)) |a| {
                    a.state = .active;
                    // The grant is replayed as recorded rather than re-derived, because
                    // the amount depended on anchor evaluation at the time (D70).
                    a.credits_granted = e.credits_granted;
                    a.credits_remaining = e.credits_granted;
                }
            },
            // A tombstone. Anchors survive it deliberately (D77, `06-auth.md`).
            .account_deleted => |e| self.purgeAccountLocked(e.account_id),
        }
    }

    /// Removes one session by id, wherever it sits in the digest-keyed map.
    fn dropSessionLocked(self: *Control, session_id: u32) void {
        var it = self.sessions.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.id == session_id) {
                _ = self.sessions.remove(e.key_ptr.*);
                return;
            }
        }
    }

    /// Removes every session belonging to an account.
    ///
    /// Collect-then-remove in bounded passes rather than removing mid-iteration, which
    /// invalidates the iterator. Same shape as the revoked-key sweep in `rewriteLocked`.
    fn dropSessionsForLocked(self: *Control, account_id: u32) void {
        var doomed: [64][32]u8 = undefined;
        while (true) {
            var n: usize = 0;
            var it = self.sessions.iterator();
            while (it.next()) |e| {
                if (e.value_ptr.account_id != account_id) continue;
                if (n == doomed.len) break;
                doomed[n] = e.key_ptr.*;
                n += 1;
            }
            if (n == 0) return;
            for (doomed[0..n]) |h| _ = self.sessions.remove(h);
        }
    }

    /// Everything deletion removes, in one place so the live path and replay cannot
    /// disagree about what deletion means.
    ///
    /// **Anchor claims are not removed.** `06-auth.md` retains them as hashes so the
    /// trial grant cannot be re-farmed by delete-and-resignup, and that is the one place
    /// deletion is deliberately not total. The GitHub *link* does go, because it exists
    /// to route a login to an account and there is no longer an account to route to —
    /// the anchor claim under `.github` is what survives.
    fn purgeAccountLocked(self: *Control, account_id: u32) void {
        if (self.accounts.fetchRemove(account_id)) |old| self.gpa.free(old.value.email);
        if (self.passwords.fetchRemove(account_id)) |old| self.gpa.free(old.value.phc);
        self.dropSessionsForLocked(account_id);

        var git = self.github.iterator();
        const link: ?u64 = while (git.next()) |e| {
            if (e.value_ptr.* == account_id) break e.key_ptr.*;
        } else null;
        if (link) |gid| _ = self.github.remove(gid);

        // Keys are flagged rather than removed, exactly as `revokeKey` does: it keeps
        // the operation idempotent without a second id-to-digest index, and the next
        // wholesale rewrite drops them for good. `resolveKey` already refuses a key
        // whose account is gone, so access ends the moment this returns.
        var kit = self.keys.valueIterator();
        while (kit.next()) |k| {
            if (k.account_id == account_id) k.revoked = true;
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


// ---------------------------------------------------------------------------
// M3: passwords, sessions, anchors, activation and deletion
// ---------------------------------------------------------------------------

const phc_a = "$argon2id$v=19$m=19456,t=2,p=1$c2FsdHNhbHRzYWx0c2FsdA$" ++
    "aGFzaGhhc2hoYXNoaGFzaGhhc2hoYXNoaGFzaGhhcw";
const phc_b = "$argon2id$v=19$m=19456,t=2,p=1$b3RoZXJzYWx0b3RoZXJzYQ$" ++
    "b3RoZXJoYXNob3RoZXJoYXNob3RoZXJoYXNob3RoZXI";

test "a password survives a reopen, and the last one set wins" {
    var h = try H.init(60);
    defer h.deinit();

    var id: u32 = 0;
    {
        const c = try h.reopen();
        defer c.close();
        id = try c.createAccount("a@b.co", .trial, .active, 10);
        try c.setPassword(id, phc_a);
        try testing.expectEqualStrings(phc_a, c.password(id).?.phc);

        try c.setPassword(id, phc_b);
        try testing.expectEqualStrings(phc_b, c.password(id).?.phc);
    }
    {
        const c = try h.reopen();
        defer c.close();
        // Replay applies both appends in order, so the change is what survives — which is
        // the whole reason `password_set` is its own event rather than a field on
        // `account_created`.
        try testing.expectEqualStrings(phc_b, c.password(id).?.phc);
    }
}

test "a password hash beyond the ceiling is refused before anything is written" {
    var h = try H.init(61);
    defer h.deinit();
    const c = try h.reopen();
    defer c.close();

    const id = try c.createAccount("a@b.co", .trial, .active, 10);
    const too_long = "p" ** (event.max_phc_bytes + 1);
    try testing.expectError(error.PasswordHashTooLong, c.setPassword(id, too_long));
    try testing.expect(c.password(id) == null);
}

test "a password cannot be set for an account that does not exist" {
    var h = try H.init(62);
    defer h.deinit();
    const c = try h.reopen();
    defer c.close();
    try testing.expectError(error.AccountNotFound, c.setPassword(999, phc_a));
}

test "a session resolves, and an expired one does not" {
    var h = try H.init(63);
    defer h.deinit();
    const c = try h.reopen();
    defer c.close();

    const id = try c.createAccount("a@b.co", .trial, .active, 10);
    _ = try c.createSession(id, "session-token-one");

    const auth = c.resolveSession("session-token-one").?;
    try testing.expectEqual(id, auth.account_id);
    try testing.expectEqual(Plan.trial, auth.plan);

    try testing.expect(c.resolveSession("not-a-session") == null);

    // Expiry is authoritative at lookup, exactly as an entry's is at the index.
    h.mclock.advance(session_lifetime_s + 1);
    try testing.expect(c.resolveSession("session-token-one") == null);
}

test "a session belonging to a non-active account does not resolve" {
    var h = try H.init(64);
    defer h.deinit();
    const c = try h.reopen();
    defer c.close();

    const id = try c.createAccount("a@b.co", .trial, .pending_verification, 0);
    _ = try c.createSession(id, "tok");
    // Same posture as `resolveKey`: unknown, expired and unverified are one answer, so
    // none of them is an enumeration oracle.
    try testing.expect(c.resolveSession("tok") == null);

    try c.activateAccount(id, 10_000);
    try testing.expect(c.resolveSession("tok") != null);
}

test "a session slides on use, but only once it is old enough" {
    var h = try H.init(65);
    defer h.deinit();
    const c = try h.reopen();
    defer c.close();

    const id = try c.createAccount("a@b.co", .trial, .active, 10);
    _ = try c.createSession(id, "tok");
    const first = c.resolveSession("tok").?.expires_at;

    // Inside the refresh threshold, nothing moves — otherwise a busy dashboard would
    // rewrite the expiry on every request.
    h.mclock.advance(session_refresh_after_s - 1);
    try testing.expectEqual(first, c.resolveSession("tok").?.expires_at);

    // Past it, the window slides.
    h.mclock.advance(2);
    try testing.expect(c.resolveSession("tok").?.expires_at > first);
}

test "a clean shutdown preserves the slide, and an unclean one shortens it" {
    // The paired halves of D70's amended rule. Both use the same timeline, and the
    // assertion is made by *advancing past the un-slid expiry* rather than by comparing
    // timestamps — because reading a session through `resolveSession` legitimately slides
    // it again, so a comparison would measure the fresh refresh instead of the lost one.
    const slide_at = 25 * 24 * 60 * 60; // past the 24 h refresh threshold
    const just_past_original = session_lifetime_s + 60;

    {
        var h = try H.init(66);
        defer h.deinit();
        const c0 = try h.reopen();
        const id = try c0.createAccount("a@b.co", .trial, .active, 10);
        _ = try c0.createSession(id, "tok");
        h.mclock.advance(slide_at);
        _ = c0.resolveSession("tok"); // slides to now + 30 days
        c0.close(); // checkpoints sessions

        const c1 = try h.reopen();
        defer c1.close();
        h.mclock.set(H.start_time + just_past_original);
        // Past where the session would have died without the slide, and the slide was
        // preserved — so it is still good.
        try testing.expect(c1.resolveSession("tok") != null);
    }

    {
        var h = try H.init(67);
        defer h.deinit();
        const c0 = try h.reopen();
        const id = try c0.createAccount("a@b.co", .trial, .active, 10);
        _ = try c0.createSession(id, "tok");
        h.mclock.advance(slide_at);
        _ = c0.resolveSession("tok"); // slides in RAM only
        c0.abandon(); // a crash: no checkpoint

        const c1 = try h.reopen();
        defer c1.close();
        h.mclock.set(H.start_time + just_past_original);
        // The extension is gone, so the session expires *earlier* than it would have.
        // That is the direction D70 requires, and it falls out of checkpointing rather
        // than being imposed by a comparison: a crash loses recent checkpoints, and for a
        // credential losing recent updates is the safe side. The mirror of D41, where
        // losing recent deductions favours the customer.
        try testing.expect(c1.resolveSession("tok") == null);
    }
}

test "logout is immediate and survives a reopen" {
    var h = try H.init(68);
    defer h.deinit();

    var sid: u32 = 0;
    {
        const c = try h.reopen();
        defer c.close();
        const id = try c.createAccount("a@b.co", .trial, .active, 10);
        sid = try c.createSession(id, "tok");
        try testing.expect(try c.revokeSession(sid));
        try testing.expect(c.resolveSession("tok") == null);
        // Revoking twice is not an error, matching `revokeKey`.
        try testing.expect(!(try c.revokeSession(sid)));
    }
    {
        const c = try h.reopen();
        defer c.close();
        try testing.expect(c.resolveSession("tok") == null);
    }
}

test "a password change invalidates every session for the account, and no others" {
    var h = try H.init(69);
    defer h.deinit();
    const c = try h.reopen();
    defer c.close();

    const a = try c.createAccount("a@b.co", .trial, .active, 10);
    const b = try c.createAccount("b@b.co", .trial, .active, 10);
    _ = try c.createSession(a, "a1");
    _ = try c.createSession(a, "a2");
    _ = try c.createSession(b, "b1");

    try testing.expectEqual(@as(usize, 2), try c.revokeSessionsFor(a));
    try testing.expect(c.resolveSession("a1") == null);
    try testing.expect(c.resolveSession("a2") == null);
    try testing.expect(c.resolveSession("b1") != null);
}

test "an anchor is claimed once, and the first holder keeps it" {
    var h = try H.init(70);
    defer h.deinit();
    const c = try h.reopen();
    defer c.close();

    const first = try c.createAccount("a@b.co", .trial, .active, 0);
    const second = try c.createAccount("b@b.co", .trial, .active, 0);
    const anchor: [32]u8 = @splat(0x11);

    try testing.expectEqual(first, try c.claimAnchor(.email, anchor, first));
    // The second account is told who holds it, which is how the caller knows to grant
    // zero credits (06-auth.md) rather than a second trial.
    try testing.expectEqual(first, try c.claimAnchor(.email, anchor, second));
    // Idempotent, so a retried activation cannot hand out a second grant.
    try testing.expectEqual(first, try c.claimAnchor(.email, anchor, first));
    try testing.expectEqual(first, c.anchorOwner(.email, anchor).?);

    // The two kinds are separate namespaces: the same digest under `.github` is unclaimed.
    try testing.expect(c.anchorOwner(.github, anchor) == null);
}

test "a GitHub link routes to an account, and goes when the account does" {
    var h = try H.init(71);
    defer h.deinit();
    const c = try h.reopen();
    defer c.close();

    const id = try c.createAccount("a@b.co", .trial, .active, 10);
    try c.linkGithub(id, 987_654_321);
    try testing.expectEqual(id, c.githubOwner(987_654_321).?);

    _ = try c.deleteAccount(id);
    // The link is gone, because it exists to route a login to an account and there is no
    // longer an account to route to.
    try testing.expect(c.githubOwner(987_654_321) == null);
}

test "activation grants the recorded credits and turns the key on" {
    var h = try H.init(72);
    defer h.deinit();

    var id: u32 = 0;
    {
        const c = try h.reopen();
        defer c.close();
        id = try c.createAccount("a@b.co", .trial, .pending_verification, 0);
        _ = try c.issueKey(id, "k", "doot_live_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
        // Unverified cannot authenticate, which is what `pending_verification` is for.
        try testing.expect(c.resolveKey("doot_live_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") == null);

        try c.activateAccount(id, 10_000);
        const auth = c.resolveKey("doot_live_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa").?;
        try testing.expectEqual(@as(u32, 10_000), auth.credits_remaining);
    }
    {
        const c = try h.reopen();
        defer c.close();
        const a = c.account(id).?;
        try testing.expectEqual(AccountState.active, a.state);
        try testing.expectEqual(@as(u32, 10_000), a.credits_granted);
    }
}

test "activation with a matching anchor can grant zero, and replay reproduces that" {
    var h = try H.init(73);
    defer h.deinit();

    var second: u32 = 0;
    {
        const c = try h.reopen();
        defer c.close();
        const anchor: [32]u8 = @splat(0x22);
        const first = try c.createAccount("a@b.co", .trial, .pending_verification, 0);
        _ = try c.claimAnchor(.email, anchor, first);
        try c.activateAccount(first, 10_000);

        second = try c.createAccount("a+x@b.co", .trial, .pending_verification, 0);
        const owner = try c.claimAnchor(.email, anchor, second);
        try testing.expect(owner != second);
        try c.activateAccount(second, 0);
    }
    {
        const c = try h.reopen();
        defer c.close();
        // The grant is replayed as recorded rather than re-derived from the plan table,
        // which is exactly why `account_activated` carries the figure (D70).
        try testing.expectEqual(@as(u32, 0), c.account(second).?.credits_granted);
    }
}

test "deletion ends access at once, and the anchor outlives the account" {
    var h = try H.init(74);
    defer h.deinit();

    const anchor: [32]u8 = @splat(0x33);
    var id: u32 = 0;
    {
        const c = try h.reopen();
        defer c.close();
        id = try c.createAccount("a@b.co", .trial, .active, 10);
        _ = try c.claimAnchor(.email, anchor, id);
        try c.setPassword(id, phc_a);
        _ = try c.issueKey(id, "k", "doot_live_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
        _ = try c.createSession(id, "tok");

        try testing.expect(try c.deleteAccount(id));

        // Access ends at the credential, which is what D77 substitutes for a deletion the
        // index cannot perform: nothing can enumerate an account's entries, so the bytes
        // leave with their expiry instead.
        try testing.expect(c.resolveKey("doot_live_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb") == null);
        try testing.expect(c.resolveSession("tok") == null);
        try testing.expect(c.password(id) == null);
        try testing.expect(c.account(id) == null);
        // Retained, so the trial grant cannot be re-farmed by delete-and-resignup.
        try testing.expectEqual(id, c.anchorOwner(.email, anchor).?);

        try testing.expect(!(try c.deleteAccount(id)));
    }
    {
        const c = try h.reopen();
        defer c.close();
        // The tombstone means replay does not resurrect it.
        try testing.expect(c.account(id) == null);
        try testing.expect(c.resolveKey("doot_live_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb") == null);
        try testing.expectEqual(id, c.anchorOwner(.email, anchor).?);
    }
}

test "a rewrite preserves every kind of M3 state" {
    // The test this whole file most needed. `imageBytesLocked` and `rewriteLocked` used to
    // hold separate copies of the event list, and a state present in neither is *destroyed*
    // by the next reclamation rather than merely mis-sized. They now share one enumeration;
    // this asserts the enumeration is complete.
    var h = try H.init(75);
    defer h.deinit();

    const anchor: [32]u8 = @splat(0x44);
    var id: u32 = 0;
    var sid: u32 = 0;
    var expiry: u32 = 0;
    {
        const c = try h.reopen();
        defer c.close();
        id = try c.createAccount("a@b.co", .trial, .pending_verification, 0);
        try c.activateAccount(id, 10_000);
        try c.setPassword(id, phc_a);
        try c.linkGithub(id, 424_242);
        _ = try c.claimAnchor(.github, anchor, id);
        _ = try c.issueKey(id, "live", "doot_live_cccccccccccccccccccccccccccccccc");
        sid = try c.createSession(id, "tok");
        _ = c.spendCredit(id);
        expiry = c.resolveSession("tok").?.expires_at;

        // Force the rewrite by pushing the log past its own image. Each `maintain` appends
        // a couple of checkpoints, and the threshold is eight times the image or the
        // 4 KiB floor — so this is a loop with a bound rather than a guessed count.
        var n: usize = 0;
        while (c.stats().rewrites == 0 and n < 5_000) : (n += 1) _ = try c.maintain();
        try testing.expect(c.stats().rewrites > 0);

        // Everything still present in RAM immediately after the rewrite.
        try testing.expectEqualStrings(phc_a, c.password(id).?.phc);
        try testing.expectEqual(id, c.githubOwner(424_242).?);
        try testing.expectEqual(id, c.anchorOwner(.github, anchor).?);
        try testing.expect(c.resolveSession("tok") != null);
        try testing.expect(c.resolveKey("doot_live_cccccccccccccccccccccccccccccccc") != null);
    }
    {
        // And present again after replaying only the rewritten log.
        const c = try h.reopen();
        defer c.close();
        const a = c.account(id).?;
        try testing.expectEqual(AccountState.active, a.state);
        try testing.expectEqual(@as(u32, 9_999), a.credits_remaining);
        try testing.expectEqualStrings(phc_a, c.password(id).?.phc);
        try testing.expectEqual(id, c.githubOwner(424_242).?);
        try testing.expectEqual(id, c.anchorOwner(.github, anchor).?);
        try testing.expect(c.resolveKey("doot_live_cccccccccccccccccccccccccccccccc") != null);
        const s = c.resolveSession("tok").?;
        try testing.expectEqual(sid, s.session_id);
        try testing.expectEqual(expiry, s.expires_at);
    }
}

test "the control-plane bucket is separate from the data-plane one" {
    var h = try H.init(76);
    defer h.deinit();
    const c = try h.reopen();
    defer c.close();

    const id = try c.createAccount("a@b.co", .trial, .active, 10);

    // Draining the dashboard's bucket must not touch the bucket a production script
    // depends on. That is a product requirement, not a tuning choice (01-product.md).
    var taken: u32 = 0;
    while (c.takeControlToken(id).?.allowed) : (taken += 1) {}
    try testing.expectEqual(plan_mod.control_burst, taken);

    const data = c.takeToken(id).?;
    try testing.expect(data.allowed);
    try testing.expectEqual(plan_mod.limits(.trial).rate_per_min, data.limit);
}

test "expired sessions are swept, and live ones are not" {
    var h = try H.init(77);
    defer h.deinit();
    const c = try h.reopen();
    defer c.close();

    const id = try c.createAccount("a@b.co", .trial, .active, 10);
    _ = try c.createSession(id, "old");
    h.mclock.advance(session_lifetime_s - 10);
    _ = try c.createSession(id, "new");

    // `old` is now past its expiry, `new` is not.
    h.mclock.advance(20);
    const m = try c.maintain();
    try testing.expectEqual(@as(usize, 1), m.sessions_swept);
    try testing.expect(c.resolveSession("old") == null);
    try testing.expect(c.resolveSession("new") != null);
    try testing.expectEqual(@as(u64, 1), c.stats().sessions);
}

test "an unverified account is swept after seven days, and a verified one is not" {
    var h = try H.init(78);
    defer h.deinit();

    var pending: u32 = 0;
    var active: u32 = 0;
    {
        const c = try h.reopen();
        defer c.close();
        pending = try c.createAccount("p@b.co", .trial, .pending_verification, 0);
        active = try c.createAccount("a@b.co", .trial, .active, 10);

        h.mclock.advance(pending_verification_ttl_s + 1);
        const m = try c.maintain();
        try testing.expectEqual(@as(usize, 1), m.unverified_swept);
        try testing.expect(c.account(pending) == null);
        try testing.expect(c.account(active) != null);
    }
    {
        // Logged, so the sweep is not redone on every boot and replay reaches the same
        // image without consulting the clock.
        const c = try h.reopen();
        defer c.close();
        try testing.expect(c.account(pending) == null);
        try testing.expect(c.account(active) != null);
    }
}

test "the same session token cannot be registered twice" {
    var h = try H.init(79);
    defer h.deinit();
    const c = try h.reopen();
    defer c.close();

    const id = try c.createAccount("a@b.co", .trial, .active, 10);
    _ = try c.createSession(id, "tok");
    try testing.expectError(error.SessionAlreadyExists, c.createSession(id, "tok"));
}

test "a session cannot be created for an account that does not exist" {
    var h = try H.init(80);
    defer h.deinit();
    const c = try h.reopen();
    defer c.close();
    try testing.expectError(error.AccountNotFound, c.createSession(999, "tok"));
}

test "session ids keep ascending across a reopen" {
    var h = try H.init(81);
    defer h.deinit();

    var id: u32 = 0;
    var first: u32 = 0;
    {
        const c = try h.reopen();
        defer c.close();
        id = try c.createAccount("a@b.co", .trial, .active, 10);
        first = try c.createSession(id, "one");
    }
    {
        const c = try h.reopen();
        defer c.close();
        try testing.expect((try c.createSession(id, "two")) > first);
    }
}


test "every account can be visited, so a caller can derive an index" {
    // Login needs email -> account, and the normalisation that makes it work lives in `api`,
    // which `control` must not import. So the index is derived by the layer that can compute
    // it, from this iteration -- which is what keeps the log format unchanged.
    var h = try H.init(82);
    defer h.deinit();
    const c = try h.reopen();
    defer c.close();

    const a = try c.createAccount("a@b.co", .trial, .active, 10);
    const b = try c.createAccount("b@b.co", .trial, .pending_verification, 0);
    _ = try c.createAccount("c@b.co", .paid, .active, 0);

    const Seen = struct {
        n: usize = 0,
        found_a: bool = false,
        found_pending: bool = false,
        fn visit(s: *@This(), acct: Account) void {
            s.n += 1;
            if (std.mem.eql(u8, acct.email, "a@b.co")) s.found_a = true;
            if (acct.state == .pending_verification) s.found_pending = true;
        }
    };
    var seen: Seen = .{};
    c.forEachAccount(&seen, Seen.visit);

    try testing.expectEqual(@as(usize, 3), seen.n);
    try testing.expect(seen.found_a);
    // Pending accounts are visited too: a signup for an address that already has an
    // unverified account must be recognised, or the second attempt would create a duplicate.
    try testing.expect(seen.found_pending);
    _ = a;
    _ = b;
}

test "a deleted account is not visited" {
    var h = try H.init(83);
    defer h.deinit();
    const c = try h.reopen();
    defer c.close();

    const id = try c.createAccount("gone@b.co", .trial, .active, 10);
    _ = try c.createAccount("here@b.co", .trial, .active, 10);
    _ = try c.deleteAccount(id);

    const Counter = struct {
        n: usize = 0,
        fn visit(s: *@This(), _: Account) void {
            s.n += 1;
        }
    };
    var counter: Counter = .{};
    c.forEachAccount(&counter, Counter.visit);
    // Deletion removes the account outright, so an index rebuilt from this cannot resurrect
    // a login for it (D77).
    try testing.expectEqual(@as(usize, 1), counter.n);
}
