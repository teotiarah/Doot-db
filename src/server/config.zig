//! Canonical transport constants.
//!
//! Mirrors the tables and prose in `docs/05-architecture.md` — the process model, the
//! "HTTP behaviour that actually matters" list, and the SSE section. `src/storage/config.zig`
//! is the same thing for the engine; between them nothing else in the tree may hardcode a
//! limit (`docs/README.md`, working rule 2).
//!
//! Several of these are load-bearing in a way a bare number does not convey, so the
//! reasoning travels with the value rather than living only in the architecture document.

const std = @import("std");
const storage = @import("storage");

// ---------------------------------------------------------------------------
// Request head
// ---------------------------------------------------------------------------

/// Request line and header block combined. Exceeded is `431 headers_too_large`.
///
/// The whole head is buffered before anything is parsed, so this is also the bound on
/// how much an unauthenticated peer can make the origin hold per connection.
pub const max_head_bytes: u32 = 8 * 1024;

/// Header count ceiling, separate from the byte ceiling.
///
/// `max_head_bytes` alone would admit roughly two thousand one-byte-named headers, and
/// every header costs a slot in a fixed array plus a linear scan on every lookup. Doot's
/// own requests use six. Exceeded is `431`, the same as the byte bound, because from the
/// caller's side it is the same mistake.
pub const max_headers: u16 = 64;

/// The read a connection posts when it is idle, waiting for a request to start.
///
/// Deliberately far below `max_head_bytes`. D28 measured resident cost at 10,000 idle
/// keep-alive connections as a function of this number: 8.11 KB/connection naive,
/// 2.14 KB at a 2 KiB buffer, **0.63 KB at 512 B**. Resident cost is pages *touched*,
/// not bytes reserved, and an idle connection needs only enough to notice a request
/// beginning. A head that does not fit here escalates to a pooled `max_head_bytes`
/// buffer, which is rare: a Doot request head is typically 150-350 bytes.
pub const idle_read_bytes: u32 = 512;

// ---------------------------------------------------------------------------
// Response head
// ---------------------------------------------------------------------------

/// Status line plus response headers. Never holds a body.
///
/// The worst case is a `GET` reply carrying `Content-Type` (128), `X-Doot-Tags`
/// (5 x 64 + 4 separators), `X-Doot-Name` (256), both timestamps, three `RateLimit-*`
/// headers and `X-Doot-Credits-Remaining` — about 1,180 bytes with framing. 2 KiB leaves
/// room for the headers M3 and M4 add without revisiting this.
pub const max_response_head_bytes: u32 = 2 * 1024;

// ---------------------------------------------------------------------------
// Bodies
// ---------------------------------------------------------------------------

/// A pooled buffer big enough for either direction of the largest request.
///
/// Sized by the *read* path, not the write path: a body is capped at 256 KiB
/// (`storage.config.max_body_bytes`) but a whole record also carries a header, a name, a
/// content type and up to five tags, so `Store.get` needs 262,929 bytes (D51). 266,240 is
/// the next page multiple, which is why `05-architecture.md` calls the slot 260 KiB rather
/// than 256 KB.
pub const request_slot_bytes: u32 = 260 * 1024;

/// In-flight requests that may hold a slot at once. Beyond this, `503`.
///
/// This — not the connection count — is what bounds body memory:
/// 256 x 260 KiB = 65 MB, independent of how many idle connections exist. At around 5M
/// entries idle connections would otherwise outweigh the index (`04-storage.md`).
pub const max_concurrent_requests: u16 = 256;

// ---------------------------------------------------------------------------
// Connections
// ---------------------------------------------------------------------------

/// Ceiling on the connection table, which is indexed directly by file descriptor.
///
/// Indexing by fd removes the need for a free list, because the kernel already
/// guarantees descriptors are unique among *open* connections. The cost is that the table
/// must span the fd space rather than the connection count, so a descriptor at or above
/// this is closed on arrival. Pair with `RLIMIT_NOFILE` at or below the same number.
pub const max_connections: u32 = 65_536;

/// Idle keep-alive timeout.
///
/// Deliberately longer than Cloudflare's origin idle timeout so the *edge* decides when
/// to close and the origin is never the side that severs a connection the edge still
/// intends to reuse. There is no maximum-requests-per-connection cap.
pub const idle_timeout_s: u32 = 75;

pub const listen_backlog: u31 = 8192;

// ---------------------------------------------------------------------------
// Event loop
// ---------------------------------------------------------------------------

/// Submission queue depth per worker ring.
pub const ring_entries: u16 = 4096;

/// Completions drained per iteration.
pub const cqe_batch: u32 = 512;

/// The repeating timeout SQE's period.
///
/// **Mandatory, not a tuning knob.** An otherwise-idle ring blocks in `copy_cqes`
/// forever, so without this no housekeeping runs at all. It does only cheap work —
/// connection idle timeouts, stats, and signalling the maintenance thread — because
/// `Store.maintain()` blocks on disk and belongs on its own thread (D45).
pub const tick_interval_s: u32 = 1;

/// How often the maintenance thread runs `Store.maintain()` and `Control.maintain()`.
///
/// Sixty seconds rather than every tick, because the sweep is **not** a correctness
/// mechanism: expiry is authoritative at the index and checked lazily on every read
/// (`03-data-model.md`), so sweeping only reclaims memory. At 10M entries a full sweep
/// walks over 14M slots — worth doing once a minute, wasteful once a second (D45).
///
/// The thread is woken by the tick above rather than owning a timer, so this is a
/// threshold the thread checks rather than a sleep it performs (D63).
pub const maintenance_interval_s: u32 = 60;

/// I/O worker threads. Every `Store` call runs on one of these (D57).
///
/// Two forces set this. It must be **more than one**, because leader commit only
/// amortises an `fsync` when a second writer is already waiting for one, and a
/// single-threaded request path never has one — that is the ~200/s against ~41,000/s D48
/// measured. And it should not be large, because writes serialise on the engine's single
/// write lock (D35), so extra threads past a handful only queue against each other.
///
/// Eight is a typical core count and comfortably more concurrent writers than leader
/// commit needs to start batching. Reads, which are the majority, are short and do not
/// contend at all.
pub const io_workers: u16 = 8;

/// SSE heartbeat comment interval.
///
/// A ceiling rather than a preference: Cloudflare's Free and Pro proxy read timeout is
/// 100 seconds and an origin that sends nothing inside that window earns a 524 (D31).
pub const heartbeat_interval_s: u32 = 15;

/// How often the loop polls the change feed for parked streams (D84).
///
/// Its own timer rather than the one-second tick: `00-vision.md` promises a write and the
/// dashboard updating are "visibly simultaneous", and a second of lag reads as a page
/// refreshing rather than as data arriving. Shortening the main tick instead would make every
/// connection in the table pay the idle sweep ten times as often for a feature that is idle
/// whenever no dashboard is open — so this timer is armed only while someone is subscribed.
pub const feed_interval_ms: u32 = 100;

/// How many connections may be parked on the live feed at once (D86).
///
/// Not a memory bound — a parked stream builds frames in the idle read buffer it already has and
/// costs nothing extra. This bounds how much of the connection table one feature may hold open,
/// and how many entries the feed scan can find work in.
pub const max_subscribers: u32 = 1024;

// There is deliberately no long-poll wait constant. D87's fallback answers immediately and
// stateless -- a delayed reply would have to hold a 260 KiB request slot so its head could be
// rendered later, spending the data plane's concurrency budget on the dashboard's fallback.

// ---------------------------------------------------------------------------
// Invariants
// ---------------------------------------------------------------------------

comptime {
    // A slot must hold the largest record `Store.get` can hand back, or the read path
    // would truncate the biggest entry a caller is allowed to write (D51).
    std.debug.assert(request_slot_bytes >= storage.store.read_buffer_bytes);
    // ...and the largest body a caller may send.
    std.debug.assert(request_slot_bytes >= storage.config.max_body_bytes);
    // Page-aligned, so a slot never straddles a page it does not need.
    std.debug.assert(request_slot_bytes % 4096 == 0);
    // The escalation path only makes sense if the idle read is the smaller of the two.
    std.debug.assert(idle_read_bytes < max_head_bytes);
}

test "a slot holds the largest record and the largest body" {
    try std.testing.expect(request_slot_bytes >= storage.store.read_buffer_bytes);
    try std.testing.expect(request_slot_bytes >= storage.config.max_body_bytes);
    // The 785-byte gap D51 is about, restated as a check rather than a comment.
    try std.testing.expectEqual(
        @as(u32, 785),
        storage.store.read_buffer_bytes - storage.config.max_body_bytes,
    );
}

test "body memory is bounded by concurrency, not by connections" {
    // The 65 MB figure in 05-architecture.md.
    const total: u64 = @as(u64, request_slot_bytes) * max_concurrent_requests;
    try std.testing.expectEqual(@as(u64, 68_157_440), total);
    try std.testing.expect(total < 70 * 1024 * 1024);
}

test "260 KiB is what the architecture document calls it" {
    try std.testing.expectEqual(@as(u32, 266_240), request_slot_bytes);
}
