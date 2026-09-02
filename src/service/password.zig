//! Argon2id password hashing (D71), and the equalised work enumeration resistance needs
//! (D75).
//!
//! ## Where this runs
//!
//! **On an I/O worker, never on the event loop.** D57 established that nothing blocking
//! belongs on the loop and its argument was about disk; this is worse, because a storage
//! call at least releases the thread while the kernel works. A deliberately slow hash is a
//! deliberate stall, and login is precisely where an attacker chooses how often it happens.
//! Nothing in this file enforces that — it cannot — so the rule lives at the call site,
//! which hands the work to the pool the way every storage call already does.
//!
//! ## The parameters, and why these
//!
//! `m = 19456` KiB, `t = 2`, `p = 1` — RFC 9106's second recommended option, which is also
//! what `std.crypto.pwhash.argon2.Params.owasp_2id` carries. The choice is made by the
//! **memory budget**, not by the ~100 ms target: the first recommended option asks for
//! 2 GiB per verification, and eight I/O workers verifying at once would want 16 GiB on a
//! box whose memory is accounted for to the megabyte in `04-storage.md`. At 19 MiB the same
//! eight peak at 152 MiB, which fits beside the index and the transport reservation.
//!
//! The 100 ms figure is a property of the deployed CPU and gets measured in M5, alongside
//! the other numbers that only mean something on real hardware (D48). If the parameters
//! land far from it, the parameters move — which is possible without invalidating a single
//! stored hash, because each one records the parameters it was made with.

const std = @import("std");
const control = @import("control");

const argon2 = std.crypto.pwhash.argon2;

/// D71's parameters. Pinned against the stdlib constant rather than spelled out, and then
/// asserted field by field in the tests — so an upstream change to `owasp_2id` is a test
/// failure rather than a silent change to how every password on the box is hashed.
pub const params: argon2.Params = argon2.Params.owasp_2id;

/// The log's ceiling for a PHC string, which is the only place one is stored.
///
/// Taken from `control/event.zig` rather than restated, because a value that must agree
/// with a file format should not be written down twice (working rule 2). Measured: the
/// current parameters produce 118 bytes.
pub const max_phc_bytes: usize = control.event.max_phc_bytes;

pub const Error = error{PhcTooLong} || std.mem.Allocator.Error;

/// A freshly-created `Io` per call, deliberately.
///
/// Argon2 needs an `Io` on this toolchain — for the salt it draws and for the parallelism
/// it does not use at `p = 1`. The cheapest one that works is `init_single_threaded`, which
/// spawns nothing; measured against the real function before this module was written.
///
/// One per call rather than one shared instance, because hashing happens on **eight I/O
/// workers concurrently** (D71) and a shared `Threaded` carries mutable state. Copying a
/// comptime-known struct on the stack is free next to a 19 MiB memory-hard hash, and it
/// removes the question of whether the sharing would have been safe.
fn localIo() std.Io.Threaded {
    return .init_single_threaded;
}

/// Hashes `plaintext` into `out`, returning the PHC string written there.
///
/// `out` must be at least `max_phc_bytes`.
pub fn hash(gpa: std.mem.Allocator, plaintext: []const u8, out: []u8) Error![]const u8 {
    std.debug.assert(out.len >= max_phc_bytes);
    var t = localIo();
    defer t.deinit();

    return argon2.strHash(plaintext, .{
        .allocator = gpa,
        .params = params,
    }, out, t.io()) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        // Every other failure mode is a buffer too small for the encoding, which is a
        // programming error here rather than a runtime condition: `out` is asserted above
        // and `max_phc_bytes` is pinned by a test against what the parameters produce.
        else => error.PhcTooLong,
    };
}

/// Verifies `plaintext` against a stored PHC string.
///
/// Returns a plain `bool` rather than an error union on purpose. Every failure — wrong
/// password, malformed hash, unsupported parameters — is one answer to the caller, and a
/// caller that could distinguish them would be able to leak which stored hash is broken.
/// `06-auth.md` wants one response for a failed login, and the cheapest way to guarantee
/// that is for the function not to be able to say anything else.
pub fn verify(gpa: std.mem.Allocator, phc: []const u8, plaintext: []const u8) bool {
    var t = localIo();
    defer t.deinit();

    argon2.strVerify(phc, plaintext, .{ .allocator = gpa }, t.io()) catch return false;
    return true;
}

/// A hash of a random password, so that an address with no account costs what an address
/// with one costs (D75).
///
/// **Generated, not hardcoded.** A constant in our source is a constant an attacker
/// recognises — the same reasoning D63 used to refuse a default `DOOT_HMAC_SECRET`. The
/// password it hashes is random and immediately discarded, so nothing verifies against it
/// and it does not need to be a secret; what matters is only that verifying against it
/// costs the same as verifying against a real one.
pub const Dummy = struct {
    buf: [max_phc_bytes]u8 = undefined,
    len: usize = 0,

    pub fn init(gpa: std.mem.Allocator) Error!Dummy {
        var d: Dummy = .{};
        var throwaway: [32]u8 = undefined;
        var t = localIo();
        defer t.deinit();
        t.io().random(&throwaway);

        const encoded = try hash(gpa, &throwaway, &d.buf);
        d.len = encoded.len;
        return d;
    }

    pub fn phc(d: *const Dummy) []const u8 {
        return d.buf[0..d.len];
    }
};

/// The login path's verification, for an account that may not exist.
///
/// `stored` is `null` when there is no such account, and the work happens anyway. This is
/// the whole of D75 in one function: the branch that decides whether to compare is the
/// oracle, so there is no such branch — both paths run a full Argon2id verification and
/// both return false for a bad password.
pub fn verifyOrEqualise(
    gpa: std.mem.Allocator,
    stored: ?[]const u8,
    dummy: *const Dummy,
    plaintext: []const u8,
) bool {
    if (stored) |phc| return verify(gpa, phc, plaintext);
    // Discarded, and it will always be false: the dummy hashes a random 32 bytes nobody
    // has. The point is the time it takes, not the answer.
    _ = verify(gpa, dummy.phc(), plaintext);
    return false;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "the parameters are the ones D71 settled" {
    // Pinned field by field, so an upstream change to `owasp_2id` fails here instead of
    // quietly changing how every password on the box is hashed.
    try testing.expectEqual(@as(u32, 2), params.t);
    try testing.expectEqual(@as(u32, 19 * 1024), params.m);
    try testing.expectEqual(@as(u24, 1), params.p);
    // 19456 KiB is the figure 06-auth.md publishes.
    try testing.expectEqual(@as(u32, 19456), params.m);
}

test "eight concurrent verifications stay inside the stated memory budget" {
    // The constraint that picked the parameters, asserted as arithmetic rather than left
    // in a comment: 8 workers x 19 MiB is the peak, and the point of rejecting RFC 9106's
    // first option was that the same 8 would have wanted 16 GiB.
    const workers = 8;
    const peak_mib = (@as(u64, params.m) * workers) / 1024;
    try testing.expectEqual(@as(u64, 152), peak_mib);
    try testing.expect(peak_mib < 256);
}

test "a password round-trips, and a wrong one does not" {
    var buf: [max_phc_bytes]u8 = undefined;
    const phc = try hash(testing.allocator, "correct horse battery staple", &buf);

    try testing.expect(verify(testing.allocator, phc, "correct horse battery staple"));
    try testing.expect(!verify(testing.allocator, phc, "Correct horse battery staple"));
    try testing.expect(!verify(testing.allocator, phc, ""));
}

test "the PHC string records the parameters, which is what lets them be raised later" {
    var buf: [max_phc_bytes]u8 = undefined;
    const phc = try hash(testing.allocator, "pw", &buf);

    try testing.expect(std.mem.startsWith(u8, phc, "$argon2id$"));
    try testing.expect(std.mem.indexOf(u8, phc, "m=19456,t=2,p=1") != null);
}

test "a stored hash fits the log's ceiling, with room for raised parameters" {
    var buf: [max_phc_bytes]u8 = undefined;
    const phc = try hash(testing.allocator, "pw", &buf);
    try testing.expect(phc.len <= max_phc_bytes);
    // Measured at 118. The headroom is deliberate: D71 expects the parameters to be raised
    // once M5 measures them, and a raised `m` only adds digits.
    try testing.expectEqual(@as(usize, 118), phc.len);
    try testing.expect(max_phc_bytes >= phc.len + 32);
}

test "two hashes of one password differ, because the salt is per-password" {
    var a: [max_phc_bytes]u8 = undefined;
    var b: [max_phc_bytes]u8 = undefined;
    const pa = try hash(testing.allocator, "same", &a);
    const pb = try hash(testing.allocator, "same", &b);
    try testing.expect(!std.mem.eql(u8, pa, pb));
    // And both verify, which is the property a salt must not break.
    try testing.expect(verify(testing.allocator, pa, "same"));
    try testing.expect(verify(testing.allocator, pb, "same"));
}

test "a malformed stored hash is a failed verification, not an error" {
    // A caller able to distinguish "wrong password" from "corrupt hash" could learn which
    // stored hash is broken, and 06-auth.md wants one answer for a failed login.
    try testing.expect(!verify(testing.allocator, "not a phc string", "pw"));
    try testing.expect(!verify(testing.allocator, "", "pw"));
    try testing.expect(!verify(testing.allocator, "$argon2id$v=19$broken", "pw"));
}

test "the dummy hash is real, verifiable work and differs every run" {
    const d1 = try Dummy.init(testing.allocator);
    const d2 = try Dummy.init(testing.allocator);

    try testing.expect(std.mem.startsWith(u8, d1.phc(), "$argon2id$"));
    try testing.expect(std.mem.indexOf(u8, d1.phc(), "m=19456,t=2,p=1") != null);
    // Generated rather than hardcoded, so no build ships a constant an attacker recognises.
    try testing.expect(!std.mem.eql(u8, d1.phc(), d2.phc()));
    // And nothing verifies against it.
    try testing.expect(!verify(testing.allocator, d1.phc(), ""));
    try testing.expect(!verify(testing.allocator, d1.phc(), "password"));
}

test "an unknown account still pays for a verification" {
    const dummy = try Dummy.init(testing.allocator);
    var buf: [max_phc_bytes]u8 = undefined;
    const phc = try hash(testing.allocator, "hunter2", &buf);

    // Known account, right password.
    try testing.expect(verifyOrEqualise(testing.allocator, phc, &dummy, "hunter2"));
    // Known account, wrong password.
    try testing.expect(!verifyOrEqualise(testing.allocator, phc, &dummy, "wrong"));
    // No account at all: same answer, and the work was done rather than skipped. The
    // timing half of this property is asserted over the wire, where the comparison is
    // meaningful; here the point is that the null branch is not a fast path.
    try testing.expect(!verifyOrEqualise(testing.allocator, null, &dummy, "wrong"));
}

test "hashing works from several threads at once" {
    // D71 puts this on a pool of eight workers, so concurrent use is the normal case
    // rather than an edge one. A shared `Io` is what this design avoids; this asserts the
    // per-call one actually holds up.
    const Worker = struct {
        fn run(ok: *std.atomic.Value(u32)) void {
            var buf: [max_phc_bytes]u8 = undefined;
            const phc = hash(std.heap.page_allocator, "concurrent", &buf) catch return;
            if (verify(std.heap.page_allocator, phc, "concurrent")) {
                _ = ok.fetchAdd(1, .monotonic);
            }
        }
    };

    var ok: std.atomic.Value(u32) = .init(0);
    var threads: [8]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Worker.run, .{&ok});
    for (threads) |t| t.join();
    try testing.expectEqual(@as(u32, 8), ok.load(.monotonic));
}
