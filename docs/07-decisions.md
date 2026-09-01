# Decisions

Append-only log. Each entry records what was decided, why, and what was rejected. When
a decision is reversed, the original is marked superseded and kept — the reasoning that
turned out to be wrong is more useful than a clean record.

Status: **locked** (settled, implement against it) · **superseded** · **deferred**
(deliberately not now, with the trigger that would reopen it).

---

## D1 — Doot is a bundle of four constraints, not "a simple database" · locked

Positioning is mandatory lifetime + tags-not-queries + free reads + live explorer. The
bundle is the product.

"Simplest database" was rejected because it provides no principled basis for refusing
feature requests. Under that framing, "add a filter", then a sort, then a join, each
sound reasonable. Under the bundle framing they are all obviously out of scope.

Sets up every refusal in `00-vision.md`.

---

## D2 — "key" and "value" are banned vocabulary · locked

The endpoint was originally drafted as `/v1/kv/{key}`. That single word undoes D1: any
reader who sees `kv` concludes this is a key-value store and every non-goal loses its
footing.

Resolution: the unit is an **entry**, addressed by a **name**, holding a **body**,
grouped by **tags**, with a **lifetime**. Enforced in code identifiers, endpoints, error
codes, log lines, docs and UI copy. Mapping table in `00-vision.md`.

Rejected: `/v1/kv`, `/v1/objects` (implies blob storage, which D8 forbids), `/v1/records`
and `/v1/documents` (imply a database), `/v1/doots` (brand-cute, reads badly in a URL).

---

## D3 — Zig 0.16, pinned to an exact version · locked

Chosen over C.

- `std.Io` with io_uring gives a fast single-box server without hand-rolling an event
  loop (D14 explains why idle-connection cost decides this).
- `std.http.Client` and `std.crypto.tls` ship in-tree, so outbound HTTPS to GitHub,
  ZeptoMail and R2 needs no dependency. In C this is OpenSSL plus libcurl.
- `std.crypto` covers Argon2id, SHA-256, HMAC, SipHash, CRC32C, and the TLS primitives.
- Errors as values, no undefined behaviour by default, built-in test runner, trivially
  static single binary.

C was rejected because it buys nothing Zig does not, at the cost of an eventual
memory-safety incident on a service holding other people's data.

Pinned to an exact 0.16.x version and tarball hash, enforced in CI. Zig breaks between
minor releases; upgrading is a reviewed act.

**M0 amendment.** 0.16.0 is the only 0.16.x release, and it ships a broken
`std.Io.Uring` — see D26. The language choice stands and every stdlib claim above
verified, but the toolchain now carries a patch, and D27 supersedes the assumption
that `std.Io` would be the concurrency layer.

---

## D4 — Metadata in headers, body stays opaque · locked

Tags, lifetime and idempotency key travel as headers. The request body is only the bytes
to store.

This is what makes `curl --data-binary @file` work with no `jq`, no base64 and no
escaping — the product's whole onboarding claim. A JSON envelope would force every caller
to wrap their payload and would force a decision on whether bodies must be valid JSON.

Consequence: `Content-Type` passthrough is what lets the dashboard render intelligently
without the server ever parsing a body.

---

## D5 — Seven endpoints, and both `PUT` and `POST` · locked

`PUT /v1/entries/{name}` for caller-chosen names (edge state, CI state, locks).
`POST /v1/entries` for server-assigned ULIDs (webhook dumps, trace events, logs).

Both are needed. Rejected `PUT`-only: generating a unique sortable name in bash is
miserable, and the dump case is a primary use case. Rejected `POST`-only: overwrite-by-name
is the entire point of the state-storage case.

ULID over UUIDv4 for assigned names: lexicographic sort by creation time comes free.

---

## D6 — Pooled rate limit per account · locked

One token bucket per account covering reads, writes, lists and deletes. Trial 100
ops/min, paid 500 ops/min, both raisable manually.

Pooling is what makes "reads are free" safe. Reads consume no credits but cannot be
issued without bound, so there is no path to unbounded free resource consumption. It is
a rate story, not a metering story.

**Per account, not per API key** — per-key buckets let anyone multiply their limit
fivefold by creating five keys. Accepted consequence: a runaway script on one key starves
the others; it is visible in the dashboard and the remedy is revoking that key.

Rejected: per-endpoint limits and per-operation-type limits. Both add explanation
surface to a product whose pitch is simplicity, for a problem the pooled bucket already
solves.

Superseded a draft in which reads were unlimited and only writes were limited.

---

## D7 — Dashboard is read-only · locked

Explore and manage the account. No create, edit or delete.

Writes from the dashboard would need their own validation, credit accounting,
idempotency and audit path, and would diverge from `/v1` over time. One write path is a
boundary worth defending.

Accepted consequence: a user who writes a secret by accident must delete it via the API
or ask support. Cheaper than a permanent second write path.

---

## D8 — 256 KB body ceiling · locked

Above this, users treat Doot as blob storage, which breaks the economics (bandwidth is
not billed), the latency profile, and the memory model (buffers are sized against this
constant). Rejected as `Content-Length` before the body is read, so oversized uploads are
refused rather than drained.

---

## D9 — No perpetual free tier · locked

10,000 write credits, one-time, never refreshed. Then manual purchase.

A recurring free tier means paying other people's server bills indefinitely in exchange
for adoption metrics that do not convert. The trial exists to answer one question — does
this fit your use case.

Superseded a draft proposing 10,000 writes/month refreshing, on the argument that a hard
wall with no payment path would churn engaged users. Correctly rejected: during labelled
beta the manual-payment conversation is itself the goal, and a warm inbound request from
someone who just hit the wall is worth more than automated checkout.

Requirements that make the wall survivable: `402` on writes, **reads keep working**,
credits on every write response, notifications at 80% and 100%, and a one-click mail-us
path (`01-product.md`).

---

## D10 — Lifetime classes, not expiry-time partitioning · locked

Segments are grouped into four append streams by requested lifetime (≤1h, ≤24h, ≤7d,
≤max). A sealed segment records its maximum expiry and is `unlink()`ed wholesale when
that passes.

Supersedes an earlier design partitioning segments by *expiry time*. That was wrong on
tracing: a segment for expiry window `[T, T+1d)` accepts writes from `T − max_ttl` right
up to `T`, so it stays open for the entire maximum-lifetime window and is immutable only
briefly before deletion. It broke backup (nothing stable long enough to upload once) and
implied up to 90 open files.

Classes give four open files, and a segment's max expiry is approximately
`seal_time + class_bound` — so short-lived data reclaims fast and cannot be pinned by
long-lived neighbours. **This is what eliminates compaction from the steady state.**

Class boundaries derive from `DOOT_MAX_TTL`; nothing hardcodes 14 or 30 days.

Accepted cost: up to four `fsync` calls per commit window instead of one. Immaterial on
NVMe, and re-measured under load.

---

## D11 — Names are not held in RAM · locked

The index stores a 64-bit keyed hash of `(account_id, name)` and the location. The full
name is verified against the record already being read.

Every read touches disk for the body regardless, so verification is free and storing
names buys nothing. Result: **~29 bytes of RAM per live entry**, about a sixth of a
name-resident index. 10M entries fit in 286 MB.

Supersedes a draft with a name-resident index at ~170 bytes/entry, which assumed a
larger box than the project should need. On a single machine memory is the binding cost,
and that draft treated it as free.

Hash keyed with a per-instance secret so hash-flooding is not a remote DoS vector.

**M2 amendment.** The requirement stands; where the secret lives has changed. Because the
key is baked into every slot and every hash in `SNAPSHOT`, it must be byte-identical on
every boot for the lifetime of the data — so it is generated once at initialisation and
persisted in a `STORE` file rather than supplied from the environment. Configuring it was
a silent data-loss path. See D43.

---

## D12 — Tag chains on disk, heads in RAM · locked

Each record carries a per-tag back-pointer to the previous record with that tag in that
lifetime class. RAM holds only `(account, tag, class) → head location`.

In-memory tag cost becomes `O(distinct tags per account)` rather than `O(entries)` — about
32 MB at 10k accounts, independent of data volume. A conventional posting list per tag
would have dwarfed the index and undone D11.

Chains are **per class** because chains order by write time while entries expire in a
different order; a cross-class chain could hit a dead link whose segment is already
unlinked and orphan live entries behind it. Within a class, expiry order and write order
agree.

Each hop is validated against the index to skip superseded and deleted records.
Traversal is bounded at 500 hops per page — which is why a short page does not mean the
end of results, and why clients must paginate until the cursor is absent.

---

## D13 — Cloudflare edge, TLS terminated twice · locked

Cloudflare fronts the origin. TLS terminates at the edge for clients, and **again at the
origin** via a vendored pure-Zig TLS 1.3 server plus a Cloudflare Origin CA certificate,
in `Full (strict)` mode with Authenticated Origin Pulls and a Cloudflare-only firewall.

Rejected `Flexible` mode (cleartext edge→origin): bearer tokens on transit networks,
catastrophic to walk back after disclosure.

Rejected a reverse proxy on the box (Caddy) and Cloudflare Tunnel: both add a second
process, which the single-binary constraint forbids. A **vendored source dependency
compiled into the binary is not a sidecar** — one artifact, one process, constraint
intact. This was the error in the original proposal: hearing "single binary" and reaching
for a second process.

Origin CA certificates are valid 15 years, so there is no ACME client and no renewal
automation.

Vendored behind a `tls.Listener` seam. An in-house TLS 1.3 server is a tracked option,
made bounded by the fact that Cloudflare is the only peer forever — one version, one
cipher suite, no client auth, no resumption — and `std.crypto` already has every
primitive.

**Consequences banked:** the origin never implements HTTP/2, HTTP/3, or response
compression; clients get all three at the edge. Cold-request latency roughly halves
(~390 ms → ~175 ms), which matters because Doot's callers are almost always cold.

**M0 verdict: validated in full.** See D29 for the measured evidence and the exact
pinned commit. The one part that could not be tested locally — Cloudflare's own
behaviour — is now tracked separately as D31.

---

## D14 — Network is the bottleneck; optimise connections, not lookups · locked

A cold cross-region request costs ~390 ms, of which storage lookup is ~0.1 ms —
**0.03%**. Storage micro-optimisation is invisible to users.

Priorities follow: keep-alive with a 75 s idle timeout (longer than Cloudflare's, so the
edge decides when to close), `TCP_NODELAY`, single-`writev` responses, `Expect:
100-continue` handling, early `413` from `Content-Length`, and buffers pooled per
in-flight request rather than per connection.

io_uring is chosen for **idle connection cost**, not throughput: thread-per-connection
at 8 MB of stack makes 10k idle keep-alives impossible, and keep-alive is the single
highest-leverage latency win available.

Also settles that 5 ms group-commit latency needs no optimisation — under 3% of what a
user experiences.

**M0 verdict: the reasoning holds, the mechanism does not.** Every priority above is
confirmed and the memory prediction was accurate to within 1.4% (D28). But io_uring
cannot be reached through `std.Io` on this toolchain, so it is driven directly —
see D27. The conclusion survived; the implementation route changed.

---

## D15 — No application-level body cache · locked

The kernel page cache already holds hot bodies. A user-space cache buys the same memory
twice. At 10M entries the application uses ~450 MB and leaves ~15 GB of a 16 GB box to
page cache, which is where hot bodies belong.

---

## D16 — Off-box backup to R2 · locked

Sealed segments upload once and never again. Snapshots and the four open tails upload
every 5 minutes. Recovery point is the tail interval.

"Best effort, no guarantee" is not a reason to skip durability engineering — trusting a
single machine is the worst available assumption. Sealed-segment immutability (D10) is
what makes this cheap: nothing is re-uploaded except tails, so bandwidth tracks write
rate rather than dataset size. Roughly $0.75/month for 50 GB.

Restore uses the same code path as local recovery with a different source, and **must be
drilled before launch**. An untested restore is not a backup.

---

## D17 — Recovery replays only post-snapshot tails · locked

Snapshot every 5 minutes; recovery `mmap`s it and scans forward from the recorded
per-class offsets. Sealed segments are never re-read. Target under 10 seconds, tracked as
a regression metric.

Snapshots are taken shard by shard under short per-shard locks, so no slot is copied
mid-update and there is no stop-the-world pause.

Valuable consequence: **tombstones only need to outlive one snapshot interval.** Deletes
are written to class 0 expiring in 10 minutes. This removes long-lived tombstone tracking
and the risk of an entry resurrecting because its tombstone was reclaimed first.

---

## D18 — The change feed is the sequence stream · locked

`seq` is already a total order over mutations, so the live dashboard needs no separate
mechanism — just a 65,536-event in-memory ring (~1.5 MB), filtered per account and
delivered over SSE.

The headline dashboard feature falls out of the storage layout at almost no cost. Best
effort by design: it drives a UI, not a guarantee. Subscribers that fall behind get a
resync marker rather than silent gaps.

**M0 verdict: cheap as claimed, with two caveats now recorded.** Measured 4.33 KB per
subscriber at 5,000 concurrent subscribers (21.7 MB), events delivered incrementally
at exactly the emit interval. But "one shared frame buffer for all subscribers" is
unsafe under io_uring and had to change (D30), and Cloudflare is a live risk to the
whole feature (D31).

**M2 amendment.** The ring itself is built in M2, not M4, because the write path is what
publishes to it — and having it early lets M2's Cloudflare probe stream real events rather
than synthetic ones. It lives in the storage engine, published under the write lock, and
is read by cursor-based poll. Only the subscriber side waits for M4. See D44.

---

## D19 — Overwrite replaces everything, including lifetime · locked

`PUT` replaces body, content type, tags and expiry. Omitting `X-Doot-TTL` applies the
7-day default rather than inheriting the previous expiry. Reads never extend lifetime.

One rule with no exceptions beats a partial-update model. Overwrite is the only refresh
mechanism, which keeps "when does this entry die" answerable from the last write alone.

Explicitly rejected: touch-on-read (a Redis session idiom that would make lifetime depend
on read traffic), and a separate refresh endpoint (an eighth endpoint for something
`PUT` already does).

---

## D20 — Idempotency is a core primitive, and replays are free · locked

`Idempotency-Key`, scoped per account, 24-hour window. Same key + same body replays the
recorded outcome and **consumes no credit**. Same key + different body is `409`.

Retries are unavoidable in CI runners, webhook senders and automation platforms. Free
replays make idempotency a trust feature as well as a correctness one: a misconfigured
automation retrying in a loop does not generate a bill. This belongs on the pricing page.

Only hashes of the key and body are retained; bodies are not kept for comparison.

**M2 amendment.** The window does not survive a restart. Idempotency state is held in RAM
only, capped at 1M records, because persisting it would put an `fsync` on the path we tell
every automated caller to use and would leave orphaned in-progress keys `409`ing for 24
hours after a crash. A retry straddling a restart re-executes and costs one credit; this is
now stated in `02-api.md` rather than implied away. See D42.

---

## D21 — SHA-256 for API keys, Argon2id for passwords · locked

Keys are ~190 bits of uniform randomness: no dictionary to attack, no benefit from a
slow KDF, and slow hashing on a credential checked every request would be a
self-inflicted performance problem. Passwords are low-entropy and human-chosen, which is
exactly what Argon2id is for.

Different credential classes, different threat models, different primitives.

---

## D22 — Opaque session tokens, not JWTs · locked

32 random bytes, stored server-side as SHA-256, in a `__Host-` prefixed cookie.

Instant server-side revocation matters more than saving a hash lookup, and a token that
cannot be revoked is a liability on a service holding other people's data. There is no
scaling argument for statelessness on a single box.

---

## D23 — List returns metadata only · locked

No bodies, ever, from `GET /v1/entries?tag=`. Page capped at 100.

This is what makes a free, rate-limited list safe: one call can never return megabytes.
Supersedes a draft with `?values=true` for inlined bodies — that was the single operation
capable of returning megabytes for one token, and removing it deleted a feature, an
asymmetry, and a response-size cap in one move.

---

## D24 — Environment variables only for configuration · locked

No config file format, therefore no parser, therefore no dependency and no precedence
ambiguity. The binary refuses to start on a missing secret or unwritable path.

---

## D25 — Trial grant bound to two identity anchors · locked

Recorded against normalised verified email **and** GitHub numeric user id. A new account
matching either activates with zero credits. Anchors are retained as hashes after account
deletion, disclosed in the privacy statement.

Deliberately nothing heavier — no device fingerprinting, no phone verification, no card
on signup. Each costs real conversions on a product pitched on under-a-minute onboarding,
and the downside of leakage is a few thousand writes.

---

---

# M0 findings

Everything below came out of the spikes in `spikes/`. Measured numbers, not estimates.

> **Note on the paths below.** `spikes/` was deleted at M1 as always intended (D49), so the
> filenames cited in D26–D31 no longer exist in the working tree. They are preserved as
> written because these entries are the record of what was measured and how; retrieve the
> code from git history at `4547b32` if a finding needs re-checking. The one file that
> survived is now `ops/sseprobe.py`.
Where a spike contradicted an earlier decision, the earlier decision carries an
amendment pointing here rather than being quietly edited.

---

## D26 — The pinned toolchain carries a stdlib patch · locked

**`std.Io.Uring` does not compile in Zig 0.16.0 as shipped.** Two exhaustive error
switches in `lib/std/Io/Uring.zig` omit `error.ReadOnlyFileSystem`, in `dirOpenDir`
(~line 2732) and `dirRealPathFile` (~line 3157). Merely calling `Uring.io()` fails
semantic analysis, because that instantiates the whole vtable. Reproducer:
`spikes/gate/minimal.zig`, 8 lines. Independently reported
[on ziggit](https://ziggit.dev/t/error-compiling-concurrency-sample-code/16401) with
the identical error location, so it is upstream and not local.

Resolution: a two-line patch adding `error.ReadOnlyFileSystem => return errnoBug(.ROFS)`
to both switches. Both call sites open `O_RDONLY`/`O_PATH` with no `O_CREAT`, so `EROFS`
genuinely cannot occur, and the file already maps every other impossible errno the same
way. **The patch changes no public API** — it completes an error mapping the authors
missed rather than widening an error set.

Carried as `toolchain/patches/0001-uring-erofs-impossible-errno.patch`, applied by
`toolchain/setup.sh`, which is idempotent, verifies the tarball SHA-256, refuses to
apply to a tree it does not recognise, and proves the fix by compiling and running a
program that uses the ring.

Rejected: **tracking Zig master.** Upstream has renamed `Io/Uring.zig` to
`Io/IoUring.zig` and cut it from 3,000+ lines to roughly 1,500, so master is a
different API, not a fix — and a moving pre-release contradicts the point of pinning.
Rejected: **waiting for 0.16.1.** 0.16.0 is the only 0.16.x release and there is no
announced patch release.

A patched compiler is a real maintenance cost, accepted deliberately: it is
deterministic, auditable, two lines, and removable the moment upstream ships a fix.

---

## D27 — Drive io_uring directly, not through `std.Io` · locked

**`std.Io.Uring` has no networking in Zig 0.16.0.** 13 of its 111 vtable entries are
`*Unavailable` stubs returning `error.NetworkDown`, and they are precisely the network
surface: `netListenIp`, `netAccept`, `netConnectIp`, `netListenUnix`, `netConnectUnix`,
`netSocketCreatePair`, `netSend`, `netRead`, `netWrite`, `netWriteFile`, `netLookup`,
`netInterfaceName`, `netInterfaceNameResolve`. A server cannot be built on it at all.

**`std.Io.Threaded` has real networking but wedges under keep-alive.** Measured: it
accepts exactly 7 connections — `async_limit`, which defaults to cores − 1 — and then
hangs permanently. The 8th connection never receives a response and throughput goes to
zero. Cause: every idle keep-alive connection permanently occupies a pool thread. This
is not slowness, it is a hard stall, and it is caused by the exact feature D14 names as
the highest-leverage latency win.

So: **`std.os.linux.IoUring`**, the low-level ring, driven by our own event loop. It is
mature, in-tree, and has `accept_multishot`, `recv`, `send` and `timeout`. Measured on
`spikes/uring/ringserver.zig`, single-threaded, pipelined over loopback with client and
server sharing 8 cores, so a floor rather than a ceiling:

| connections | pipeline depth | throughput |
|---|---|---|
| 1 | 128 | 2.93M req/s |
| 8 | 128 | 2.99M req/s |
| 16 | 128 | 2.80M req/s |

Peak observed server-side: 3.18M req/s. Roughly a hundred times any plausible demand,
which confirms the D14 conclusion that the box is never the constraint.

Consequences: no fibers, so the 60 MB per-fiber stack reservation in `std.Io.Uring`
never applies, and connection state is a struct we size ourselves (D28). We also own
the housekeeping timer — **a repeating `timeout` SQE is mandatory**, because an
otherwise-idle ring blocks forever in `copy_cqes` and nothing else runs. That same
timer drives expiry sweeps and SSE heartbeats, so it is not overhead.

This is more code than calling `std.Io`, and it is the right trade: it is the layer
Doot actually needs control over, and the alternative does not function.

---

## D28 — Connection state is pooled, and per-connection cost is pages touched · locked

D14 predicted roughly 8 KB per idle connection and 80 MB at 10,000. Measured with the
naive approach — one `page_allocator` allocation per connection struct and per read
buffer — **8.11 KB per connection, 79 MB at 10,000 idle keep-alive connections.** The
estimate was accurate to 1.4%.

Two findings change the design:

**Per-connection RSS is driven by pages actually *touched*, not bytes allocated.**
Resident size was identical (8.10 KB/conn) for read buffers from 512 B to 16 KB;
only virtual size grew. An idle connection has received one small request, so exactly
one page of its buffer is resident. A 24-byte connection struct from `page_allocator`
burns a whole 4 KB page — half the total cost — for nothing.

**Pooling therefore beats the estimate by up to 13×.** Connection structs from one
static array, read buffers carved from a single arena, 10,000 idle connections:

| read buffer | naive (one allocation each) | pooled |
|---|---|---|
| 512 B | 8.10 KB/conn → 81 MB | **0.63 KB/conn → 6.3 MB** |
| 2 KB | 8.10 KB/conn → 81 MB | **2.14 KB/conn → 21 MB** |
| 8 KB | 8.10 KB/conn → 81 MB | **4.14 KB/conn → 41 MB** |

RSS returned to 1.2 MB after all connections closed, so no leak. `sizeOf(Conn)` was
24 bytes.

This is the measured form of D14's "buffers pooled per in-flight request, not per
connection", and it argues for keeping the idle read buffer small — a request head is
bounded at 8 KB (`05-architecture.md`) but an *idle* connection needs only enough to
detect the start of one.

**M2 amendment — the shipped transport's marginal cost is zero, and the table above no
longer describes it.** Both columns measured a spike that allocated *per connection*, so
both were per-connection numbers; the question was only which one was smaller. The
implementation reserves everything at startup instead — a descriptor-indexed `Conn` slab
plus two pools — so accepting a connection allocates nothing at all. Re-measured against
`tools/transport` in `ReleaseFast`:

| idle keep-alive connections | RSS | marginal cost |
|---|---|---|
| 0 | 39,984 kB | — |
| 1,000 | 39,984 kB | **0 B/conn** |
| 2,500 | 39,984 kB | **0 B/conn** |
| 5,000 | 39,984 kB | **0 B/conn** |
| 10,000 | 39,984 kB | **0 B/conn** |

Each of those connections had completed a real request and was sitting idle with a
pending read, which is the state D28 was about. RSS did not move by a single page.

The cost moved rather than vanished, and it is now a **fixed reservation**: 107 MB
virtual — a 38 MB `Conn` table (65,536 × 616 B), a 66 MB request-slot pool
(256 × 272,560 B) and a 2 MB head-buffer pool — of which **39 MB is resident at boot**
because `Table.init` touches every entry, rising to about **93 MB** once traffic has
touched all 256 slots. Virtual stays at 110 MB throughout.

That trade is the right way round for a single box: a fixed ceiling known at startup
beats a per-connection slope, because the slope is what turns a connection spike into an
out-of-memory kill. The 0.63 KB/conn figure keeps its point — the *idle read buffer
should still be small*, and `idle_read_bytes` is 512 because of it — but it is no longer
the cost of a connection.

---

## D29 — tls.zig pinned at `fe60069`, driven over raw sockets · locked

D13's resolution validated end to end.

- **The commit matters.** tls.zig HEAD requires Zig `0.17.0-dev` and will not build on
  our pin. Commit `fe60069029602fb0ca7129f35c1af7c97d6d2473` (2026-04-15, "upgrade to
  zig 0.16.0") declares `minimum_zig_version = "0.16.0"` and builds clean. Pinned by
  content hash in `build.zig.zon`.
- **TLS 1.3 handshake confirmed** against an independent OpenSSL 3.5.7 client with
  `minimum_version` forced to TLS 1.3, full chain verification and hostname checking.
  Works with both ECDSA P-256 and RSA 2048 chains; negotiated
  `TLS_AES_256_GCM_SHA384`.
- **Authenticated Origin Pulls confirmed in both directions.** With
  `client_auth = .{ .auth_type = .require, .root_ca = bundle }`, a valid client
  certificate passes and a client presenting none is rejected —
  `error.TlsCertificateRequired` at the origin, `TLSV13_ALERT_CERTIFICATE_REQUIRED` at
  the client. Rejecting correctly matters more than accepting correctly.
- **It does not need `std.Io` networking.** Its `nonblock` API is a pure buffer
  transformation: hand it received ciphertext, it returns what it consumed and what to
  send. `spikes/tls/nonblock.zig` runs TLS 1.3 on the raw io_uring loop of D27. This
  is what makes D27 and D13 compatible rather than in conflict.
- **The single-binary claim holds.** 7.3 MB ReleaseFast, statically linked, "not a
  dynamic executable", zero OpenSSL or libcrypto strings.

The in-house TLS 1.3 server stays a tracked option, no longer urgent.

---

## D30 — An io_uring send buffer must be immutable until its completion · locked

Found by trying to break the SSE broadcast, and it would have been a genuinely nasty
production bug.

`io_uring` reads a send buffer **asynchronously**, after `submit()` returns. D18's
"one shared frame buffer for all subscribers, since every subscriber gets identical
bytes" is therefore unsafe: rewriting that buffer on the next tick corrupts frames
still in flight.

Measured with `spikes/sse/validate.py`, which validates every frame byte-for-byte:

| subscribers | torn frames |
|---|---|
| 50 | 1,000 |
| 500 | 9,505 |
| 2,000 | 40,000 |

The corruption signature is a truncated frame — `data:` arriving as `ta:` or `ata:`.
**It is invisible with a single subscriber**, which is exactly how it would have
shipped.

Resolution: a pool of 256 **refcounted** frame slots. A broadcast acquires a slot,
formats the frame into it, and sets the refcount to the number of sends issued; each
send completion decrements, and the slot returns to the free list at zero. The slot
index rides in the unused high bits of `user_data`. If no slot is free the broadcast is
dropped and counted, which is bounded and consistent with the feed being best-effort.

After the fix: **zero torn frames across more than 210,000 validated frames** at 50,
500, 2,000 and 5,000 subscribers, with no slot exhaustion and no slot leak.

The sharing idea was right and the memory argument for it stands — frame payloads are
still not duplicated per subscriber. What was wrong was assuming "shared" implies
"safe to overwrite".

Generalised rule for the implementation: **any buffer handed to the ring is owned by
the kernel until its completion arrives.** This applies to the shared pipelined
response buffer in `ringserver.zig` too — that one is safe only because it is written
once at startup and never mutated.

---

## D31 — Cloudflare zone configuration is part of the deployable artifact · locked

The SSE spike could not test Cloudflare, so it tested the literature instead, and the
risk is real: **Cloudflare buffering `text/event-stream` is a recurring, repeatedly
reported failure**, with reports in 2020, 2023, May 2024, June 2025 and August 2025.
One 2025 report describes responses being withheld until roughly 100 KB accumulates
even with response buffering nominally off. For most of that history the only reliable
workaround was disabling the proxy entirely — which would forfeit every benefit in D13.

**There is now a first-class fix.** Cloudflare Configuration Rules expose a
[Response Body Buffering setting](https://developers.cloudflare.com/rules/configuration-rules/settings/)
whose `none` value streams the response body straight to the client without inspection.
[Configuration Rules are available on the Free plan](https://developers.cloudflare.com/rules/configuration-rules/)
with a limit of 10 rules. Cloudflare notes that disabling buffering also disables WAF
and Bot Management body inspection on matching paths, which is acceptable for
`/app/stream`: a session-authenticated `GET` with no request body.

So the zone is configuration we own and version, not a console someone clicked once:

| setting | value | why |
|---|---|---|
| Configuration Rule on the stream path | `response_body_buffering: none` | without it, SSE is buffered and the live dashboard silently dies |
| Compression Rule on the stream path | compression off | Cloudflare always offers `accept-encoding: br, gzip` to the origin, and compression forces buffering |
| Cache Rule on `/v1/*` and the stream path | bypass | a cached read breaks the state-storage use case outright |
| SSL/TLS mode | Full (strict) | D13 |
| Authenticated Origin Pulls | on | D13, D29 |
| origin firewall | Cloudflare ranges only | D13 |

**Hard number, newly pinned down:** Cloudflare's proxy read timeout on Free and Pro is
100 seconds, after which an origin that has sent nothing gets a 524. So the SSE
heartbeat in `05-architecture.md` is not decorative — it has a ceiling. **Set it to
15 seconds**, comfortably inside 100 and inside most intermediary idle timeouts too.

Still unverified, and honestly so: none of this can be confirmed without the zone, the
domain and a publicly reachable origin. `spikes/sse/sseprobe.py` is the verification
procedure — it takes any URL including `https://`, judges streaming on arrival timing
rather than content, flags a `Content-Length` or `Content-Encoding` that would indicate
buffering, and exits non-zero when buffered. **Run it against `doot.run` as the first
act of deployment, before the dashboard is built on the assumption that it works.**

Rejected: switching the live view to polling pre-emptively. Polling would work through
any proxy, but it degrades the one feature meant to drive adoption, and there is now a
documented fix worth trying first. The fallback is recorded rather than taken:
long-polling on the same endpoint, chosen only if the probe fails against the real
zone.

---

# M1 findings

Everything below came out of implementing the storage engine. D32 and D33 were settled
*before* any code was written, per the two-pass rule; D34 onward were forced by the
implementation and its measurements.

Where a finding contradicted the specification, `04-storage.md` was corrected and the
decision recorded here rather than the document being quietly edited.

---

## D32 — Four spec defects, found by reading the spec as an implementer · locked

Settled before any M1 code was written, per the two-pass rule. Each was a real defect,
not a clarification, and three of the four would have produced silently wrong behaviour.

**Name length was one byte, but names go to 256.** `04-storage.md` declared `name_len` as
a single byte holding `1..255`, while `03-data-model.md` allows names of 1–256 bytes.
An implementer following the record format would have capped names at 255 and quietly
contradicted the published limit. Fixed by storing the length biased by one: names can
never be empty, so `0..255` maps exactly onto `1..256` at no cost.

**The checksum did not cover the framing.** `crc32c` was specified over "all bytes after
this field", which excludes `record_length` and `body_len` — the two fields a recovery
scan uses to locate the next record. A single corrupted length byte would have walked the
scanner into garbage with nothing to detect it. The checksum now covers everything except
itself. This also forced the verification *order* to be written down, since a length
cannot be trusted before the checksum and the checksum cannot be computed without a
length: bounds-check the length first, then verify.

Also settled: a failed checksum means two different things, and both are correct. During
a recovery tail scan it is a torn write at the moment of the crash — stop, and treat that
record as never having existed. On a record the index still points to, it is corruption
of data that was once durable — serve `404` and count it. Same signal, opposite
responses, counted separately.

**Deletion from an open-addressed table was unspecified.** Blanking a slot severs the
probe sequence and orphans every entry stored past it. The resolution is better than a
new marker: a slot already carries `expires_at`, so **a dead slot is one whose
`expires_at` has passed**, and deletion just forces it to `0`. Expired and deleted slots
become indistinguishable to every code path — which is precisely what `03-data-model.md`
promises callers, now true in the data structure rather than in a check bolted on top.

It also makes segment reclamation safe with no extra work. A segment is unlinked only
once all its records have expired, so any slot pointing into it is already dead by
definition. No index scan at unlink time, and a lookup can never be handed a location in
a file that no longer exists. Added a shard **rebuild** at 25% dead slots to reclaim
index memory — deliberately a different thing from segment compaction, and a normal
steady-state event rather than an escape hatch.

**Nothing was testable.** Covered separately in D33.

---

## D33 — The clock and the crash point are injected parameters · locked

Every M1 exit condition is a statement about time or about crashes, and neither was
reachable in the design as documented.

**The clock is a parameter.** All expiry, reclamation, tombstone lifetime and snapshot
scheduling derive from an injected clock; nothing else in the engine may read system
time. Two implementations: real, and manual.

This is not scaffolding, it is what makes the project's central claim checkable. "Bounded
lifetime eliminates compaction" (D10) is a claim about behaviour over days, and M1
requires a 24-hour mixed-lifetime soak to demonstrate it. On a wall clock that takes 24
hours, cannot run in CI, and therefore in practice never runs — leaving the load-bearing
argument of the whole storage design permanently unverified. On an injected clock it runs
in seconds, on every change.

**The crash point is a parameter.** Durability is defined by surviving a crash at the
worst moment, and the worst moments are `fsync` boundaries. So `fsync` calls are counted
and a build can abort immediately after the *n*-th. That turns "does it survive a crash"
from something argued into something enumerated: run the workload once per boundary, kill
it there, reopen, assert the invariants.

The counter compiles in unconditionally — one increment beside a syscall that already
costs 50–200 µs — but the abort is armed only by explicit configuration and cannot fire
in production.

Rejected: testing durability by reasoning about the code, and testing expiry with
`sleep`. The first is how storage engines lose data, and the second is how time-dependent
tests get deleted for being slow.

---

## D34 — Leader commit replaces the commit timer · locked

The specification described a commit thread firing every 5 ms or every 1 MiB. The
implementation instead has the first writer needing durability take a lock and perform
the flush, with every writer waiting at that moment covered by it.

Better on both axes the triggers balanced: a writer waits one `fsync` rather than up to
5 ms, and batching still amortises because writers arriving during a flush are covered by
the next. And there is nothing left for a timer to do — the triggers bound how long
staged data sits unflushed, and nothing is staged. Every acknowledged write has a writer
waiting on it; an unacknowledged write has no durability requirement to bound.

Related: **records are `pwrite`n on arrival and only the flush is batched.** A user-space
staging buffer would mostly duplicate the page cache while adding the buffer-lifetime
failure mode D30 demonstrated. Durability is identical either way.

Both constants are removed from the document rather than left unimplemented.

---

## D35 — One write lock; reads unlocked · locked

The index's own contract (D11) asks callers to serialise same-key mutations, because
verifying a name needs a disk read and the index holds no names. Rather than key-striped
locks, the whole write path takes one mutex. Reads take none. Durability waiting happens
outside it, so writers still group.

D14 measured storage at 0.03% of what a request costs end to end, so parallelising writes
optimises the wrong 0.03% while introducing the hardest concurrency in the system.
Appends to a class already serialise and one flush already covers many writers, so the
lock removes very little real parallelism.

It also dissolves two problems: same-key mutations serialise for free, and a record's tag
back-pointers can be published to the chain heads before the record is encoded without
racing another writer on the same tag — which the reserve-then-write split (below) needs.

Accepted consequence: **visibility precedes durability.** The index updates when a write
is ordered, so a reader can briefly see an entry a crash would erase. Standard for group
commit, and harmless: the guarantee is about *acknowledged* writes, and nothing in that
window has been acknowledged.

Segments therefore expose `reserve` / `writeReserved` / `unreserve` rather than only
`append`, because a record's address must be known before its tag pointers are published.
Reservations are explicitly not hole-tolerant: a failed write between reserve and write
would strand a gap ahead of records that later get acknowledged, and a recovery scan would
stop at the gap and lose them. The write lock is what makes the pair atomic.

---

## D36 — A process kill cannot test durability · locked

The most useful thing M1's crash harness produced was proof that an earlier version of it
proved nothing.

The harness kills the engine with `SIGKILL` at every `fsync` boundary and checks that no
acknowledged write was lost. It passed. Then durability was deliberately broken —
`awaitDurable` made a no-op, so writes are acknowledged before they are flushed — **and it
still passed.** The workload's flush count fell from 39 to 6 and nothing complained.

The reason is simple and easy to miss: **`SIGKILL` kills a process, but dirty page cache
survives it.** Un-flushed data is still readable by the next open, because the kernel
still has it. A process-kill sweep tests *recovery* — torn tails, half-written snapshots,
rotation in flight, manifest lag — and cannot test `fsync` at all.

Resolution: durability is asserted **white-box, at the moment of acknowledgement.** After
every operation the engine is asked whether it considers that write durable, in three unit
tests and after every operation in the crash workload. The same mutation now fails eight
tests and fails the harness at operation 0.

Stated limit, not a solved problem: **true power-loss durability remains untested.**
Proving it needs a block layer that discards un-flushed writes — `dm-flakey`, a VM power
cut, or equivalent — which a container cannot provide. What is proven is that the engine
calls for a flush before acknowledging, and that recovery is correct at every flush
boundary. The gap between those two and real power loss is the correctness of `fsync`
itself on the deployed filesystem.

Also settled: the crash verifier asserts only on keys whose final operation was
acknowledged. A crash point is a flush boundary, not an operation boundary, so later
unacknowledged operations may also have landed; if keys were rewritten, every assertion
would weaken to "some value". Expiry is checked unconditionally instead, since it holds
regardless of acknowledgement.

---

## D37 — Hardware CRC32C · locked

Every record is checksummed on write and verified on read, so the checksum sits directly
in the recovery path. Decomposing replay time by body size gave ~3.1 µs fixed per record
plus ~2.5 ns/byte, and the per-byte half was Zig's byte-at-a-time CRC table — **roughly
half of total replay time at 1 KiB records.**

x86-64 has had a CRC32C instruction since 2008 that computes this exact polynomial. Using
it took 1 KiB records from 5,345 ns to 3,230 ns, and replay from 196 to 324 MiB/s. Without
it the measured recovery of a 3 GB tail would have been roughly 20 s against a 10 s target.

**It is an optimisation, not a format change**, and that is worth being certain of rather
than assuming, since this is the one code path that decides whether data is considered
intact. The tests assert byte-identical output against the standard library at every
length from 0 to 300, on buffers up to 256 KiB, across incremental splits, and against the
RFC 3720 vectors. A table fallback is retained for other targets.

---

## D38 — Recovery is bounded by the snapshot interval, not the dataset · locked

Measured: **3,000,000 records / 3,147 MiB replayed in 9.5 s** — inside the 10 s target,
with 5% of margin. Thin enough that the relationship matters more than the number:

```
recovery time  ≈  (write rate × record size × snapshot interval) / 332 MiB/s
```

A 10 s budget buys about 3.3 GB of tail, which at 1 KiB records covers sustained write
rates to roughly 11k/s at the default five-minute snapshot interval. Above that the lever
is `DOOT_SNAPSHOT_INTERVAL_S` — halving it halves both the tail and recovery time.

The consequence for operations is that **recovery time is a tunable, not a property of how
much data is stored.** A store holding 100 GB recovers as fast as one holding 1 GB,
provided the write rate and snapshot interval are the same.

Two implementation notes that were required to get there: replay reads in 1 MiB chunks
(one `pread` per record would miss the target by orders of magnitude), and the four class
tails are merged on lowest pending sequence rather than replayed class by class — the
index carries no sequence number to arbitrate with, so class-at-a-time replay would let an
older write from one class overwrite a newer one from another.

**M2 amendment — the 332 MiB/s is a warm-page-cache number.** It was measured replaying
bytes that were already resident, on tmpfs. A cold restart reads the tail from the deployed
filesystem instead, so the formula above is an optimistic bound rather than the operational
one. Reproduced independently at 355 MiB/s, also on tmpfs; the same harness on a persistent
volume writes 200× slower, which is leader commit behaving correctly under a
single-threaded workload rather than a regression. M5's recovery measurement must be taken
on the deployed volume from a cold cache, and that is the number this lever derives from.
See D48.

---

## D39 — Index rebuild is driven by maintenance as well as insert · locked

The documented 25%-dead rebuild threshold was only checked on insert, so a shard that
stopped receiving writes kept its dead slots indefinitely. Nothing was lost — dead slots
stay reusable — but the documented behaviour did not hold in the case that most needs it,
immediately after a wave of expiry. Maintenance now checks it too.

Related clarification, because the number looks alarming otherwise: **bytes per live entry
is only meaningful near the admission point.** A store whose entries have mostly expired
holds a table sized for its peak, so the ratio climbs arbitrarily — a soak ending with
3,023 live entries in a 65,536-slot table reports 434 B/entry. That is the minimum table
size showing through, not accumulating waste. The 29 B/entry figure is a statement about
the table at its load limit, which is the point the memory budget describes.

---

# M2 decisions

Settled before any data-plane code exists, per the two-pass rule. The M1 engine is
complete and measured; everything below is a question that had to be answered before
anything could be built on top of it.

Five are corrections to earlier documents. One — D43 — is a format addition that would
have been very expensive to discover later.

---

## D40 — Control-plane state is an append-only log with a full in-RAM image · locked

Accounts, API key hashes, sessions, OTP challenges, identity anchors and credit balances
all have to survive a restart, and **no document said where they live.** `04-storage.md`
budgets rate-limit buckets and idempotency records as RAM and is silent on the rest.

Rejected first, because it is the tempting answer: **keeping control-plane state as
entries in the entry store.** Disqualifying on three counts. Every entry must expire
(minimum 60 s, maximum bounded by plan), so an account would need a background job
refreshing its own lifetime forever. Segment reclamation `unlink()`s whole files once
their maximum expiry passes, so accounts would be deleted by the engine's normal
operation. And a dead index slot *is* one whose `expires_at` has passed (D32), so "never
expires" is not representable in the index at all. The entry store is built for data that
dies; account state is data that must not.

Rejected: **SQLite, or any embedded database.** `build.zig.zon` has zero dependencies and
D3's argument was that the standard library already covers what Doot needs. A C
dependency for a few megabytes of state would be the largest dependency in the project
serving its smallest subsystem.

Rejected: **a second instance of the M1 engine with expiry switched off.** Expiry is not a
feature of that engine that can be disabled — it is the representation of slot liveness.
Turning it off forks `index.zig`.

Resolution: **a separate append-only log, `CONTROL`, with the entire state held as an
in-RAM image.**

The state is tiny and bounded. At ten thousand accounts: ~200 B per account, five API keys
each at ~80 B, ~40 B per live browser session. Single-digit megabytes, against a budget
with ~15 GB left to page cache. So there is no index, no segments, no compaction and no
partial loading — the image is a set of hash maps, and disk exists only to rebuild them at
boot.

Mechanics reuse what M1 established, deliberately:

- A mutation appends a length-prefixed, CRC32C-checksummed **event** and `fsync`s before
  the response is written. Signup, key creation, revocation and login are rare; one flush
  each is invisible.
- Recovery replays the log from the start into empty maps. A torn tail is truncated,
  exactly as `replayManifest` already treats one.
- The log is **rewritten wholesale** once it exceeds eight times the live image:
  serialise to `CONTROL.tmp`, `fsync`, `rename`, `syncDir` — the same atomic replace
  `snapshot.zig` already performs. Because the image fits in RAM there is no incremental
  compaction problem to solve. This is reclamation by rewrite, the same distinction D32
  drew for index shards.
- `CONTROL` lives in `DOOT_DATA_DIR` beside the segments. Verified safe rather than
  assumed: `SegmentSet.discover` skips any filename that is not `c{class}-{id}.seg`
  instead of unlinking it, which is already how `MANIFEST` and `SNAPSHOT` coexist there.

**Rate-limit buckets stay out of the log.** RAM only, 16 B per account, and every bucket
starts full after a restart. That is the generous direction, it costs one restart's worth
of burst, and persisting a token count across a ten-second outage would be preserving a
number that has already refilled.

Vocabulary: the unit in this log is an **event**, not a record — D2 reserves "record" as a
banned synonym for *entry*, and `record.zig` already uses it for the physical framing of
one. `control.Event` and `feed.Event` (D44) are distinct types in distinct namespaces.

---

## D41 — Credit balances are authoritative in RAM and checkpointed, never logged per write · locked

Credits are the only control-plane state mutated on the hot path: every successful write
deducts one. Logging each deduction with an `fsync` would double the flush cost of the
write path in order to persist a counter whose granularity is 10,000.

What actually has to hold is an ordering property, worth stating precisely because
getting it backwards over-charges users. `03-data-model.md` already promises a failed
write costs nothing. So:

> A credit deduction must never be durable unless the write it paid for is also durable.

That constrains the design in one direction only. A deduction lost while the entry
survives gives the user a free write — bounded, invisible, in their favour. An entry lost
while the deduction survives means the user paid for nothing, which is the failure
`01-product.md` says must not happen.

Resolution: **the balance is authoritative in RAM and persisted as an absolute value in a
periodic checkpoint**, never as per-write deltas. The in-RAM balance is what enforces the
`402` wall and what `X-Doot-Credits-Remaining` reports, so user-visible behaviour is exact
at all times. The checkpoint rides the control log at the snapshot interval.

Absolute values rather than deltas matter twice: the log does not grow with write volume,
and a duplicated or partially applied checkpoint cannot compound.

**Accepted consequence, stated rather than hidden:** an unclean restart rewinds balances to
the last checkpoint, granting up to one checkpoint interval of writes for free. It can
never charge for a write that did not land, because the deduction was never durable in the
first place. This sits inside the recovery-point language already published in
`01-product.md`.

Rejected: **flushing the deduction on the same group commit as the entry.** Genuinely
elegant — one flush covers both and the ordering property holds exactly — but it means
threading a fifth append stream through `commit.zig`, which is M1 code whose exit
conditions are measured and whose flush set is asserted in tests. Paying that to make a
billing counter exact, when inexactness only ever favours the user, is the wrong trade.
Reopen it if credits become a real revenue mechanism rather than a beta trial grant.

---

## D42 — Idempotency state is in RAM and does not survive a restart · locked

`02-api.md` promises a 24-hour window. `04-storage.md` budgets idempotency at ~50 B per
record capped at 1M, in the *application memory* table. Those two readings conflict, and
the conflict had to be resolved before the endpoint was written.

Resolution: **in RAM only, bounded at 1,000,000 records, lost on restart — and said so in
the published docs.**

Three arguments, in increasing order of weight.

**The protected window is narrow.** Retries arrive seconds after the original; a restart
is a connection reset plus under ten seconds of recovery. Only a retry straddling that
window is affected.

**Durability would tax the path we tell people to use.** `02-api.md` advises
`Idempotency-Key` on anything automated, so it is meant to be the common case. Persisting
it puts an `fsync` on the common write path to defend a rare race.

**Durability creates a worse failure mode than it removes.** A key with a request in
flight returns `409 idempotency_in_progress`. Persist that and a crash mid-write leaves a
key marked in-progress with no request left to finish it — a key that `409`s for a full 24
hours until it expires, needing recovery logic whose only job is cleaning up after a case
that has no clean form. In RAM, a restart clears in-progress state and the retry simply
executes, which is the correct outcome.

**Accepted consequence:** a retry spanning a restart re-executes. For `PUT` that is
harmless at the data level — same name, same bytes, same result — and costs one credit.
For `POST` it produces a second entry under a new ULID. Both are stated in `02-api.md`,
because a published 24-hour window that quietly does not survive restarts is exactly the
kind of implied guarantee `01-product.md` criticises this category for.

Eviction at the cap: drop the records closest to expiry first. **Never reject a write
because the idempotency table is full** — an optional header must not be able to fail an
otherwise valid request. Dropping a record degrades to re-execution, which is what not
supplying the header at all already does. Under extreme volume the effective window
shortens below 24 hours: bounded, safe, and visible in `/admin/stats`.

---

## D43 — The index hash key belongs to the store, not to the environment · locked

`05-architecture.md` listed `DOOT_INDEX_HASH_SECRET` among the boot secrets. **That is a
data-loss bug waiting to be configured**, and it is the most valuable thing this pass
found.

The index stores a 64-bit keyed SipHash of `(account_id, name)` and nothing else (D11). The
key is therefore part of the *identity* of every slot: baked into every entry in the
in-RAM table and into every hash written to `SNAPSHOT`. Supply a different key on the next
boot and every lookup misses. Nothing reports an error — `get` probes, finds no matching
hash, returns `404`. Worse, a full tail replay cannot repair it, because replay re-hashes
only records after the snapshot watermark and sealed segments are never re-read. The store
would come up "healthy", report its entry count, and be unable to find a single entry
written before the change.

A secret that must be byte-identical on every boot for the lifetime of the data is not a
secret the environment should hold. Rotating it is not a security operation, it is a
destructive one.

Resolution: **the key is generated once, when the store is initialised, and persisted with
the data.** `DOOT_INDEX_HASH_SECRET` is removed from `05-architecture.md`.

A new file, `STORE`, holds the store's identity:

```
offset  size  field
  0       4   magic "DSTR"
  4       2   format version
  6       2   reserved
  8       4   created_at        unix seconds
 12      16   index_hash_key    16 random bytes, CSPRNG at initialisation
 28       4   crc32c            over bytes 0..27
```

32 bytes, written once, never rewritten. `Store.open` reads it **before `Index.init`**,
because the index is constructed from `opts` and the key has to be in `opts` by then. The
current ordering — `validate` → `Index.init` → `SegmentSet.open` → `recover` — makes this
an insertion at the top rather than a restructure.

Three cases, and the third is the one that matters:

| directory | `STORE` | behaviour |
|---|---|---|
| empty | absent | generate a key, write `STORE`, `fsync`, `syncDir` |
| has segments | present, valid | adopt the persisted key |
| has segments | absent or corrupt | **refuse to start** — `error.StoreIdentityMissing` |

Refusing beats guessing. A missing `STORE` beside existing segments means an incomplete
restore or a deleted file, and inventing a fresh key there silently orphans every entry.
Failing loudly at boot is the pattern D24 already established.

Deliberately a separate file rather than the 56 reserved bytes in the snapshot header:
`snapshot.read` is fail-soft by design and returns `null` on any damage, falling back to
full replay. A key living only there would mean a damaged snapshot silently produces a
*different* key and an unreadable store that reports success — the worst available failure
shape. `STORE` is small, always present, and independently checksummed.

D11's requirement is fully met and slightly improved: the key is per-store, unknown to any
attacker, and now *cannot* be misconfigured to a shared value across deployments.

`STORE` is immutable after creation, so backup treats it exactly like a sealed segment —
uploaded once, never again — and a restore lacking it cannot proceed, which is correct.

**Implementation note.** Creating `STORE` costs two flush boundaries, the file and the
directory entry, so the M1 crash sweep now enumerates **41 boundaries rather than 39** and
recovers at every one. The two additions are on the fresh-store path, where a crash is
trivially survivable because no data exists yet for a regenerated key to orphan. The count
quoted in D48 was measured before this landed and is left as recorded.

**Related, and settled the other way.** `Options.max_index_bytes` defaults to `0`, meaning
unlimited, which disables admission control entirely. Unlike the hash key, a wrong value
here corrupts nothing — it only changes when `503 capacity_exhausted` begins. So this stays
a boot concern: the server requires `DOOT_MAX_INDEX_BYTES` and refuses to start without
it, while the library keeps `0` as its default, because a library should not invent a
memory ceiling for its own tests.

---

## D44 — The change feed ring ships in M2; only its consumers wait for M4 · locked

`config.feed_ring_events = 65_536` has been defined and referenced by nothing since M1.
The roadmap places the live view in M4, which left the ring itself unassigned — and the
ring is written by the write path, which is M2 code.

Resolution: **the ring is built in M2. Subscriber fan-out, refcounted frame slots (D30)
and resync markers are M4.**

Splitting it there is not scaffolding, for two reasons.

The halves are genuinely different sizes. Publishing is one slot write per mutation — no
I/O, no allocation, no flush. Consuming is the substantial part: per-account filtering,
SSE framing, the refcounted slot pool D30 forced, and lag handling. A ring with no
subscribers is complete and testable on its own: assert order matches `seq`, assert
wraparound reports a resync condition.

And it makes M2's own exit condition better evidence. M2 already stands up a throwaway SSE
endpoint behind the real Cloudflare zone to run `sseprobe.py` (D31). If the ring exists,
that endpoint streams **real feed events** rather than synthetic ones, so the probe
measures the production shape instead of a stand-in. Strictly stronger, for no extra work.

**The ring lives in the storage engine**, as `src/storage/feed.zig`, published from inside
the write path while the write lock is held. Two reasons it belongs there rather than in
the server: `seq` and the location are generated inside `Store.put`/`Store.delete`, so
publishing there makes ring order match sequence order for free; and the alternative — a
callback out of the engine — would run server code underneath the global write mutex,
inviting exactly the re-entrancy hazard lock discipline exists to prevent. `04-storage.md`
already documents the ring in the storage chapter, so this makes the code agree with the
document.

Reading is a cursor-based poll, the same shape as `maintain()`: the server asks for
everything after a sequence it has already seen. No callbacks and no subscriber registry
inside the engine.

**Visibility precedes durability here too** (D35). A subscriber can observe a mutation a
crash would erase. The feed is best-effort and drives a UI, not a guarantee (D18), so this
is consistent — but it is now written down.

---

## D45 — Maintenance is a thread, not an event-loop tick · locked

`store.zig` says `maintain()` is "called from the event loop's tick in production". That
is wrong, and wrong in a way that would have surfaced as latency nobody could explain.

`maintain()` sweeps all 64 index shards, `unlink()`s reclaimable segments, rebuilds
dead-heavy shards, and writes a full snapshot when the interval has passed. The snapshot
alone flushes and then writes the entire slot array. Running that on the event-loop thread
stalls every connection pinned to that worker for its duration. `05-architecture.md`
already lists snapshot and segment reclamation among the background threads that are "all
off the request path"; the engine's comment simply contradicts it.

Resolution: **one maintenance thread.** The event loop's repeating `timeout` SQE —
mandatory anyway, per D27 — only signals it.

| cadence | driver | work |
|---|---|---|
| 1 s | event-loop timeout SQE | connection idle timeouts, stats, signalling the maintenance thread |
| 15 s | maintenance thread | SSE heartbeats — ceiling is Cloudflare's 100 s read timeout (D31) |
| 60 s | maintenance thread | `Store.maintain()` |
| 300 s | inside `maintain()` | snapshot, already gated on `snapshot_interval_s` |

Sixty seconds for `maintain()` rather than every tick, because the sweep is **not** a
correctness mechanism: expiry is authoritative at the index and checked lazily on every
read (`03-data-model.md`), so sweeping only reclaims memory. At 10M entries a full sweep
walks over 14M slots — worth doing once a minute, wasteful once a second.

The engine's doc comment is corrected as part of this decision rather than left to
contradict the architecture document.

---

## D46 — Pagination cursors have a fixed signed wire format · locked

`tagchain.Cursor` is 40 bytes of internal traversal state — four class frontiers and a
sequence bound — and `tagchain.zig` notes that "the store signs it before handing it out".
Nothing signs it. `02-api.md` promises cursors that are opaque, HMAC-signed, bound to the
issuing account and valid for one hour. Specifying the format now leaves Pass 2 nothing to
invent.

```
offset  size  field
  0       1   format version (1)
  1       4   account_id
  5       4   issued_at              unix seconds
  9      40   cursor state           4 × u64 class frontier, then u64 seq bound
 49      16   HMAC-SHA256 truncated  over bytes 0..48, keyed by DOOT_HMAC_SECRET
```

65 bytes, base64url without padding, **87 characters**. Truncating the tag to 16 bytes
leaves forgery at 2^128, which is not the weak link in anything here.

Verification, in this order, every failure returning `400 invalid_cursor` with no
distinction between them:

1. decodes as base64url to exactly 65 bytes
2. version is 1
3. HMAC verifies, under **constant-time comparison**
4. `account_id` equals the authenticated account
5. `issued_at` is within the last hour

Checking the tag before the account is deliberate: an attacker learns nothing about which
accounts exist, and step 4 becomes a check on data already proven to be ours.

Signing and verification live in the API layer, not the engine — `tagchain.Cursor` stays a
plain struct, which is the seam M1 left. `DOOT_HMAC_SECRET` is already in the boot secret
list, and unlike the index hash key (D43) it is genuinely rotatable: rotation invalidates
outstanding cursors, and a client's documented response to `invalid_cursor` is to restart
pagination.

---

## D47 — Request parsing is specified, not left to the implementer · locked

Four wire-format questions were unanswered. Each is the kind of gap every implementer
fills differently, and then it becomes a compatibility obligation.

**`X-Doot-TTL` grammar.** `02-api.md` gave examples (`90s`, `15m`, `24h`, `14d`, bare
`3600`) without a grammar. Settled: one or more ASCII digits, optionally followed by
exactly one lowercase suffix from `s`, `m`, `h`, `d`. Nothing else — no compound forms
(`1h30m`), no fractions (`1.5h`), no sign, no internal whitespace, no uppercase. Digits
are bounded at 10 and the multiplied result at `u32`, so overflow is a parse failure
rather than a wraparound. Unparseable is `400 invalid_ttl`; parseable but out of range is
`ttl_too_short` or `ttl_too_long`, which keeps "I typed it wrong" distinct from "my plan
won't allow it". `0` and `0s` parse, then fail as `ttl_too_short`.

Compound and fractional forms are refused because they are the start of a duration
language, and every extension invites another: `1h30m` invites `1h 30m`, then
`90 minutes`. Four suffixes cover what a shell script needs.

**`X-Doot-Tags` parsing.** Settled, in this order: split on `,`; trim leading and trailing
spaces and tabs from each element; **drop empty elements**; lowercase; de-duplicate keeping
first-occurrence order; then enforce ≤ 5 and validate each against the character set. An
absent or empty header is zero tags, which is valid.

Empty elements are dropped rather than rejected because `a,b,` is a shell artefact, not a
caller bug, and `03-data-model.md` already sets the tolerant precedent that duplicates
collapse instead of erroring. Note the ordering: the count is enforced **after**
de-duplication, so `ci,ci,ci,ci,ci,ci` is one tag rather than `too_many_tags`. Lowercasing
here is what lets the engine's `validateTag` keep rejecting uppercase as a caller bug
instead of normalising it — the engine's comment already says normalisation is the API
layer's job, and this is that job.

**Name percent-decoding.** Decoded exactly once, before validation. A `%` not followed by
two hex digits is `400 invalid_name`, as is any decoded byte outside printable ASCII, which
`validateName` already enforces. The 1–256 byte limit applies to the decoded bytes, as
`03-data-model.md` says.

One consequence, stated now because callers will find it: **`%2F` and a literal `/`
produce the same name.** Names are byte strings compared after decoding and `/` is a
permitted byte, so `a%2Fb` and `a/b` are one entry, not two. That follows from decoding
once and comparing bytes. The alternative — treating an escaped slash as distinct — would
require carrying the encoded form around and make "is this the same entry" depend on how it
was spelled.

**Server-assigned names.** ULIDs are non-monotonic: 48-bit millisecond timestamp, 80 bits
from the CSPRNG, Crockford base32, 26 characters. The monotonic variant of the spec is
deliberately not used. D5 wants lexicographic sort by creation time, which the timestamp
delivers at millisecond granularity; two entries created inside the same millisecond sort
arbitrarily against each other, and nothing in the product depends on their relative
order — list-by-tag is ordered by `seq`, not by name. A monotonic counter would add shared
mutable state to the write path to fix an ordering nobody observes.

---

## D48 — M1's throughput figures are properties of the filesystem they were measured on · locked

Reproducing M1's exit conditions on a second machine produced a discrepancy worth
recording, because one of those numbers has been promoted into an operational formula.

Everything passes, and recovery came in slightly better than documented: **3,000,000
records / 3,147 MiB replayed in 8.85 s, 355 MiB/s**, against 9.5 s and 332 MiB/s
originally. All 111 unit tests pass. All five exit conditions pass. The crash sweep
enumerated 39 boundaries and recovered at all 39.

But that run was on **tmpfs**. The same harness against a persistent volume wrote at
roughly **200 writes/s, against ~41,000 writes/s on tmpfs** — over two orders of
magnitude, enough that the 3M-record write phase does not finish in half an hour.

That gap is not a defect. It is D34 working as designed: the harness is single-threaded, so
every `put` becomes its own flush leader with nobody to piggyback, giving one `fsync` per
write. Under concurrent load — the only load that exists in production — writers batch
behind one flush, which is the entire point of leader commit. **The harness's write phase
is a durability test, not a throughput measurement, and must never be quoted as one.**

Two consequences.

`04-storage.md` and `08-roadmap.md` now state the filesystem each figure was measured on. A
number that moves by 200× with the mount deserves that much.

**D38's formula is a warm-page-cache figure, and is amended.** `recovery ≈ tail ÷
332 MiB/s` was measured replaying bytes that were already resident. A cold restart reads
the tail from the deployed filesystem instead, and while sequential NVMe reads should clear
a 3.3 GB tail comfortably, "should" is not what M1's other four conditions settled for. M5
already has an exit condition measuring recovery against the claim published in
`01-product.md`; that measurement is now explicitly required to be taken on the deployed
volume, from a cold page cache, and to be the number the operational lever is derived from.

Also worth knowing for anyone reproducing: `m1 all` runs the recovery check with the
**default 300,000 records**, not the 3,000,000 the published figure describes. The headline
needs `m1 recovery <dir> 3000000` explicitly.

---

## D49 — `spikes/` retires into `ops/` · locked

`spikes/README.md` says the directory "is deleted at M1". M1 is complete and merged and it
is still present. Root `README.md` meanwhile lists `spikes/` as one of two directories that
"are permanent". Both statements cannot stand.

Resolution: **`spikes/` is deleted.** Its purpose was retiring three unknowns; the findings
are D26–D31, the code is in git history at `4547b32`, and keeping a directory of throwaway
probes invites treating them as maintained.

One artifact survives, as D31 and `05-architecture.md` both already promised:
`sseprobe.py`, the procedure that decides whether Cloudflare streams SSE. It moves to a new
**`ops/`** directory, where deployment artifacts belong — and which D31 already requires for
a second reason, since the zone configuration is "part of the deployable artifact" and must
be "applied as code rather than console clicks". `ops/` receives that configuration in
Pass 2, when there is a real zone to write it against. Nothing empty is created now to hold
the space.

Root `README.md` is corrected.

---

## D50 — CI enforces what the decisions already claim is enforced · locked

D3 says the toolchain pin is "enforced in CI". `05-architecture.md` says it is "recorded in
the repository and enforced in CI". M2's exit condition is a `curl` script "that runs in
CI".

There is no CI. There never has been.

Three commitments against no infrastructure, and M2 is where the first comes due — so it
is built now rather than after the milestone that depends on it. GitHub Actions, on the
repository that already exists, with the toolchain cached on the hash of
`toolchain/zig.lock`.

Four jobs, each enforcing something a decision already claims:

| job | enforces |
|---|---|
| `toolchain/setup.sh` | D3, D26 — the pinned tarball still hashes correctly and the patch still applies cleanly |
| `zig build test` | the 111 unit tests |
| `zig build verify && m1 all` | M1's five exit conditions, including the 39-boundary crash sweep |
| vocabulary check | D2 |

The vocabulary check is the interesting one, and it is deliberately narrow. D2 is enforced
"in code identifiers, endpoints, error messages, log lines, docs and UI copy" and until now
nothing checked it. A general ban on "key" is unworkable — "API key", "Idempotency-Key",
"index hash key", "keep-alive" and "keyed hash" are all legitimate and frequent. So the
check bans only tokens that cannot be innocent: `key-value`, `keyvalue`, `key_value`,
`/v1/kv`, and `kv` as a standalone word. That catches the specific drift D2 fears — the
vocabulary sliding back toward "key-value store" — and is honest about not catching
subtler slippage. A check with no false positives that runs on every commit beats a
thorough one that gets disabled.

The exit-condition job is worth its runtime. It is ~10 s on tmpfs, and it is the only thing
standing between a refactor and a silent durability regression, which D36 demonstrated is a
failure mode that hides.

---

## D51 — Two M1 defects, found by reading the engine as its first caller · locked

Neither is reachable from the M1 harness. Both are prerequisites for M2 rather than
optional cleanups.

**`Store.delete` puts 257 KiB on the stack.** It encodes its tombstone into
`var buf: [record.max_record_bytes]u8` — 262,929 bytes — as a stack local, while
`Store.put` heap-allocates exactly the length it needs. A tombstone carries no body,
content type or tags, so the buffer is enormous precisely where it is least needed. It
survives today because the harness calls `delete` from the main thread, which has a large
stack. M2 puts it on event-loop worker threads with stacks we size ourselves, where a
257 KiB frame is how a stack overflow gets discovered in production. Fixed by allocating
`encodedLen()`, matching `put`. A tombstone's true maximum is 36 + 256 = **292 bytes**.

**`Store.get`'s buffer contract does not match the documented pool.** `get` requires a
caller-supplied buffer large enough for the whole record, which is
`record.max_record_bytes` = **262,929 B**, not 256 KiB. `05-architecture.md` budgets "256
concurrent × 256 KB = 64 MB of body buffers" — 785 bytes per slot short of what `get` can
need, so a maximum-size entry would come back truncated. Pool slots are therefore
**266,240 B (260 KiB)**, the next page multiple, for a total of exactly **65 MiB**.
Corrected in the memory budget rather than left as an off-by-a-page that only appears on
the largest possible entry.

---

## D52 — Seven error codes the catalogue was missing · locked

Surfaced by implementing the catalogue rather than reading it. `02-api.md` publishes
eighteen codes and promises that `code` "is a stable machine-readable identifier and
never changes once published" — which makes inventing one inside an implementation
diff exactly the wrong move. Each gap below is a response the specification already
requires, with no code named for it.

| status | code | the gap it fills |
|---|---|---|
| 411 | `length_required` | `05-architecture.md` requires `411 Length Required` when a write omits `Content-Length`, and names no code |
| 400 | `content_type_too_long` | `03-data-model.md` caps `Content-Type` at 128 bytes and does not say what happens above it. The engine already returns a distinct error |
| 405 | `method_not_allowed` | a known path with a method it does not support. Seven endpoints are published; nothing said what the eighth combination does |
| 431 | `headers_too_large` | `05-architecture.md` bounds the request line and headers at 8 KB total and rejects early, without naming a status. 431 is the status for exactly this |
| 400 | `invalid_request` | a malformed request line or header block — not a validation failure of a *field*, so none of the existing 400s fit |
| 500 | `internal_error` | the catalogue had no 5xx but `503`, while promising a uniform body on **every** non-2xx |
| 404 | `not_found` — **reused, deliberately** | an unrouted path |

Three of these are worth the reasoning.

**`internal_error` carries a fixed, generic message and never any detail.** The
failures that reach it are the engine's I/O errors, a checksum failure on a record the
index still pointed at, and allocation failure. Every one of those is a sentence about
our disks or our memory, and none of it is a caller's business — `05-architecture.md`
already forbids logging bodies, names and keys, and the same instinct applies to
putting internals in a response. The detail goes to the structured log, where the
operator is; the caller gets a code and a `docs` link. This is also why it is not
tempting to make it informative: an error body is the one place where being helpful to
the reporter and helpful to an attacker are the same act.

**An unrouted path reuses `not_found` rather than getting its own code.** A distinct
code would tell an unauthenticated prober which paths exist, which is a small
enumeration oracle for no benefit. It also cannot be confused with a missing entry in
practice, because the validation order in `03-data-model.md` puts authentication
first: an unknown `/v1` path with a bad key is `401` and never reaches routing at all.

**`431` rather than `400` for oversized headers.** The bound is on the request
*framing*, not on a value the caller supplied, and 431 exists precisely so a client
can tell "your headers are too big" from "your input was wrong". Same reasoning that
keeps `413` separate from `400` for bodies.

`method_not_allowed` carries an `Allow` header listing what the path does support,
because a client that guessed wrong deserves to be told rather than made to read docs.

All six are added to the table in `02-api.md`, which remains the published catalogue.
Nothing already published changed.

---

## D53 — A scheduling-dependent property is asserted by retry, not by hope · locked

Found by stress-testing the change feed: `commit.zig`'s "concurrent writers all reach
durability with far fewer flushes than writers" fails roughly one run in twenty when
pinned to two cores, and every run on one core. The property it checks is real and the
code is correct — four writer threads simply do not always overlap, and when they do
not, every write leads its own flush and `flushes < writers` is false.

This is the same effect D48 recorded from the other end: a workload with no concurrency
gets one `fsync` per write, because leader commit has nobody to piggyback. Correct
behaviour, wrong assertion.

It matters because CI runs on two cores, so this would have gone red intermittently
for reasons unrelated to whatever was being reviewed — and an intermittently red suite
teaches people to press re-run, which is how a real regression gets waved through.

Rejected: **weakening the assertion to `flushes <= writers`.** That can never fail, and
D36 is the standing lesson that a test which cannot fail is worse than no test.

Rejected: **skipping the check whenever it does not batch.** Same defect wearing a
disguise — break batching entirely and `piggybacked` drops to zero, the check is
skipped, and the suite goes green.

Resolution: **run the workload up to five times and require batching to be observed at
least once.** Overlap is the scheduler's to grant, so asking repeatedly is legitimate;
never being granted it across five attempts on a multi-core machine is a genuine
regression and fails the test. On a single-core machine the claim is unmeasurable —
there is no parallelism to amortise — so it is stated as such rather than papered over.

The correctness half is unchanged and still asserted on **every** attempt: every writer
reaches durability, and `isDurable` agrees at the moment each one returns. Only the
amortisation claim, which is a statement about performance, is the one allowed to need
more than one try.

General rule this sets, since more of these will appear once the event loop exists:
**assert correctness unconditionally, and measure performance by retry with a bounded
budget.** Never assert a timing outcome once and call it a property.

---

## D54 — Accepted sockets stay blocking · locked

Building the transport raised a question the M0 spikes never had to answer, because they
never wrote a response large enough to stall: **should accepted sockets be `O_NONBLOCK`?**

It is not a stylistic question. io_uring attempts an operation inline, and when it cannot
complete it either arms an internal poll and retries — cheap — or hands the work to an
`io-wq` kernel worker thread, which performs it with blocking semantics. If the second
path is what happens, then a slow client owns a kernel thread for as long as it is slow,
and that is a milder version of the exact failure D27 rejected `std.Io.Threaded` for:
"every idle connection permanently owns a pool thread". Reasoning cannot settle which
path the kernel takes. Measurement can.

Measured against `tools/transport` on the deployment kernel (6.1.180, 8 cores), counting
threads in `/proc/<pid>/task` and `io-wq` workers by their `iou-` name prefix:

| situation | threads | `io-wq` workers | still serving? |
|---|---|---|---|
| idle | 1 | 0 | — |
| 10,000 idle keep-alive connections | **1** | **0** | yes |
| 2,000 half-sent request heads (slow loris) | **1** | **0** | yes |
| 256 stalled 200 KB writes | **1** | **0** | yes, 6 ms |
| 320 stalled 200 KB writes | **1** | **0** | yes |

**Zero worker threads, in every case.** The ring uses its poll-based retry path
throughout, so a blocking socket costs nothing and D27's failure does not recur. A new
request was served in 6 ms while 256 responses were parked mid-write.

Resolution: **leave accepted sockets blocking.** `O_NONBLOCK` has nothing to buy — there
are no threads to save — and it would cost real complexity: with the flag set, io_uring
declines to arm poll and returns `-EAGAIN` to us instead, so every read and every write
would need a re-arm path, on the two hottest paths in the process. Adding failure modes
to buy nothing is the wrong direction.

Rejected: **`O_NONBLOCK` for the sake of textbook io_uring style.** The textbook advice
exists to avoid worker-thread punting. Measurement says we are not punting.

Rejected: **`IOSQE_ASYNC` to force the async path.** That asks for the behaviour the
question was worried about.

**Why a single `writev` almost always finishes, and why the resumption logic stays.** A
stalled write is genuinely stalled — with a 2 KB client receive window, only 2,048 bytes
were readable while the response was parked, and all 200,144 arrived once the client
drained. Yet the completion reports the full count and the request slot is released
immediately: 320 slow readers never exhausted a 256-slot pool, and no `503` was ever
produced. The reason is that the socket send buffer autotunes up to `tcp_wmem`'s maximum,
4 MB here, which is an order of magnitude beyond the 260 KiB ceiling on a Doot response.
The kernel accepts the whole thing and drip-feeds it to the receiver.

So `stats.partial_writes` is normally **zero**, and the cursor in `response.zig` is not
reachable by any traffic pattern we can construct from outside. It stays regardless, for
two reasons: it is not *guaranteed* — an operator lowering `net.core.wmem_max`, or memory
pressure capping `sk_wmem`, restores short writes — and correctness that depends on a
tunable staying generous is not correctness. It is proved deterministically by unit tests
over the cursor, including byte-at-a-time reassembly, rather than by hoping an
integration test triggers it. This is D53's rule applied to a buffer instead of a clock:
assert the property directly where it is deterministic, and do not assert kernel
behaviour you do not control.

**Accepted consequence, and it is a real one: a slow reader's response is buffered in
kernel socket memory, which none of our accounting sees.** `05-architecture.md` budgets
65 MB of body buffers and D28 now adds a 107 MB fixed reservation, but a parked response
also occupies up to 260 KiB of `sk_wmem` per connection — roughly 83 MB across the 320
stalled writes above, invisible to `VmRSS` and to `/admin/stats`. Capping `SO_SNDBUF` on
accepted sockets would bound it, and would have the tidy side effect of making the
partial-write path ordinary rather than theoretical.

It is deliberately **not** decided here, because the cost is not measurable on loopback.
Fixing `SO_SNDBUF` disables send-buffer autotuning, and the edge-to-origin hop is a real
WAN path whose bandwidth-delay product decides whether a 64 KiB buffer is generous or a
throughput ceiling. Deciding that from a measurement taken over `127.0.0.1` would be
guessing with a number attached. It is in the Deferred table, to be answered on the
deployed link alongside the other figures M5 re-measures for the same reason (D48).

---

## D55 — `Date` is sent on every response · locked

The transport emits `Date` on every response. Neither `05-architecture.md`'s header list
nor `02-api.md`'s per-endpoint tables enumerated it, which made it an undocumented header
on a documented surface — worth settling rather than leaving as a diff nobody reviewed.

RFC 9110 requires an origin server with a clock to send `Date` on 2xx, 3xx and 4xx
responses. Doot has a clock. Omitting it is a spec deviation that costs nothing to fix now
and is awkward to add later, once clients exist that were built against its absence.

It is **not** part of Doot's own surface. Nothing in the product reads it, no endpoint
depends on it, and it is deliberately absent from the per-endpoint header tables in
`02-api.md` for that reason — those tables describe the product's headers. `Date` belongs
to HTTP, and is documented once, under "Headers on every response".

Cost is nil: the loop formats it once per tick and every response in between borrows the
result, so no response formats a timestamp. That is what makes it free rather than a
per-request `clock_gettime` plus a conversion.

**One exception, and it is on the overload path.** The `503` returned when the request-slot
pool is empty is rendered at compile time, because it is the one reply that must be
sendable when there is nothing left to build one with. A static constant cannot carry a
live `Date`. A connection-terminating overload reply is also the case where a missing
`Date` changes no client and no cache behaviour, so the trade is the right way round.

Rejected: **omitting `Date` everywhere for consistency with the static `503`.** Consistency
with the degraded path is not a reason to make the normal path non-conforming.

---

## D56 — Plan limits are a table in code, and the paid ceiling stays configuration · locked

`01-product.md` has specified per-tier limits since the beginning, and nothing in code has
ever consulted them. `Plan` is persisted on the account and read back by `resolveKey`, but
no code path uses it for policy: there is no rate limit by plan, no maximum lifetime by
plan, and `storage.config.Options.max_ttl_s` is a single store-wide ceiling.

Three things about to be built need it at once — the pooled rate limit needs a bucket size,
`GET /v1/whoami` publishes a `limits` object, and `ttl_too_long`'s message promises "the
maximum for this plan". So the table lands first, in one place.

Resolution: **one table in `src/control/plan.zig`, keyed by `Plan`, mirroring the Tiers
table in `01-product.md`.** It lives with the control plane because a plan is a property of
an account, and accounts are the control plane's business. `01-product.md` remains the
source of the numbers; this is a mirror, in the sense working rule 2 means.

**The paid maximum lifetime is not in the table, deliberately.** `01-product.md` is explicit
that the 30-day figure "is a starting point, not a commitment", that it "moves with observed
usage", and that **nothing may hardcode it** — it is `DOOT_MAX_TTL`, and the storage layout
derives from it. So the table carries the trial's 14 days, which *is* a product constant,
and the paid ceiling resolves to whatever the store is configured for. There are therefore
two ceilings, and the effective one is the lower:

- the **engine** ceiling, `Options.max_ttl_s`, which class 3's bound derives from (D10)
- the **plan** ceiling, from this table

A plan ceiling above the engine's would be a limit the storage layout cannot honour, so it
is asserted rather than silently clamped.

Rejected: **putting the table in `server/config.zig` beside the transport constants.** Those
are properties of the process; these are properties of a customer.

Rejected: **deriving the rate limit from the plan at each call site.** That is how the same
number ends up written three times and disagreeing after the first change.

---

## D57 — Storage calls never run on the event loop · locked

The engine's public calls block, and the amount they block by is not small:

- `Store.delete` takes the one global write lock, appends a tombstone, and then waits in
  `awaitDurable` — an `fsync` wait.
- `Store.list` performs up to `tag_hop_budget` record reads. That bound is 500.
- `Store.get` performs one or two `pread`s per candidate.

Running these on the event-loop thread is not merely a latency question. **It makes D34
inert.** Leader commit's entire benefit is that the first writer needing durability performs
the flush and every writer waiting at that moment is covered by it — and a single-threaded
request path never has a second writer waiting. D48 measured exactly this from the other
end: ~200 writes/s on a persistent volume against ~41,000/s on tmpfs, "because a
single-threaded workload gives every write its own flush leader with nobody to piggyback".
So an inline `delete` would cap deletes at roughly 200/s *and* stall every connection
pinned to the loop for the duration of each one. A cold-cache `list` walking its full hop
budget is tens of milliseconds of head-of-line blocking in front of unrelated requests.

Resolution: **a bounded pool of I/O worker threads owns every `Store` call.** The event loop
does sockets, parsing, routing and authentication — all of which are memory-only — and
nothing that can touch a disk.

The rule is deliberately **uniform**: every storage call goes to the pool, including `get`.
A boundary drawn at "calls fast enough to run inline" requires a judgement about each one,
and that judgement rots the first time a call gains a slow path nobody re-checked. The
handoff costs microseconds against a request whose network round trip is measured in tens
of milliseconds (`05-architecture.md`), so uniformity is nearly free.

It also gives the pool a second job: it is what supplies leader commit with concurrent
writers, so D34 starts working as designed rather than degrading to one flush per write.

Rejected: **running storage inline on the loop.** Costed above.

Rejected: **one event loop per core instead of a pool** — the `SO_REUSEPORT` item already in
Deferred. It would give leader commit its writers, and it is the model `05-architecture.md`
describes, but it multiplies the transport's fixed reservation by the core count: the
107 MB in D28's amendment becomes roughly 856 MB at eight loops, because each loop needs its
own connection table spanning the descriptor space and its own slot pool. It also leaves a
blocking call stalling 1/N of connections rather than none, and ties storage concurrency to
core count rather than to disk behaviour. Single-loop throughput is ~100× any plausible
demand (D27), so there is no throughput reason to pay that. It stays deferred, on the
grounds it was already deferred on.

Rejected: **acknowledging a delete before it is durable.** `204` would become a claim a
crash could contradict, and M1's first exit condition is that nothing acknowledged is lost
and nothing deleted resurrects. Free at the till is not free of meaning.

**Mechanism: a per-loop `eventfd`.** The loop keeps a `read` posted on it; a worker pushes a
finished job onto that loop's completion queue and writes to the `eventfd`; the read
completes and the loop drains the queue. `IORING_OP_MSG_RING` is the tidier mechanism and
the deployment kernel has it, but the pinned toolchain's `IoUring` does not wrap it, and
D26's standing rule is that the pin is not worked around casually. This is the same class of
gap as D27's, handled the same way: use what the pin supports, and record why.

Handing a request between threads is safe because of a property the transport already has
for another reason: requests live in a pool addressed **by index, not by pointer** (D28
amendment), so nothing a job refers to moves when the job crosses a thread boundary.

**Accepted consequence: the pool is a queue, and a queue can fill.** When every worker is
busy, storage-bound requests wait. That is correct behaviour — it is backpressure, and it is
what stops a slow disk from being absorbed as unbounded memory — but queue depth becomes a
number that must be visible in `/admin/stats` rather than inferred from latency.

---

## D58 — The service layer, and the engine surface it is allowed to touch · locked

The router, API-key authentication, the pooled rate-limit bucket and the endpoint handlers
need to know both what an entry is and what an HTTP path is. Nothing existing may hold both.

- `src/api/` is specified as pure functions over request bytes — "no allocation, no clock,
  no I/O, no sockets". Handlers need all four.
- `src/server/` is specified as knowing nothing about entries, accounts or credits. The
  `Handler` seam exists precisely to keep it that way, and putting routing behind it would
  make the seam decorative.

Resolution: **a new module, `src/service/`.** It is the composition layer, and the only place
that imports `storage`, `control`, `api` and `server` together. The naming follows the
existing modules, which are named for the layer they are rather than what they contain.

**It may not reach into the engine's internals.** `GET /healthz` needs the current sequence
number and whether writes are being admitted, and today both are reachable only as
`store.com.lastSeq()` and `store.idx.admissionClosed()` — through fields that are public so
the engine's own tests can drive them, not as an interface. Reaching through them from
another module would make every future change to the engine's internals a change to the API
surface. `Store` gains two accessors instead, and the service layer uses those.

**The rate-limit bucket lives on the account, in `Control`.** Not in the service layer and
not per connection: a bucket per worker or per connection multiplies the limit, which is the
same failure D6 rejected per-key buckets for. `Control` already serialises every per-account
mutation behind one mutex — `spendCredit` is the precedent — and a bucket is one more
mutation of the same kind, so it needs no new lock and inherits the property that made
credits safe.

Rejected: **a `service` module that also owns the transport.** The split earned itself: the
transport's 104 tests run without a store, a control log or an account existing, and folding
the two together would cost that.

---

## D59 — Account and key identifiers are Crockford base32, padded · locked

`02-api.md` publishes `"account_id": "acct_7Q2M9XKV"` and `06-auth.md` shows `key_3F8A`,
and neither says what those strings are. Illustrative was fine until something had to emit
one: `GET /v1/whoami` returns both, and an identifier on a published response is a format
callers store, log and compare.

Underneath both are a `u32` — `Account.id` and `ApiKey.id`.

Resolution: **`<prefix>_` followed by the id in uppercase Crockford base32, zero-padded to
seven characters.** `acct_0000001` for account 1, `key_0000001` for key 1.

Crockford because it is already in the tree — `api/ulid.zig` uses it for server-assigned
names — and because it excludes `I`, `L`, `O` and `U`, so an identifier read off a screen
into a support ticket does not arrive as a different one. Seven characters because that is
what a `u32` needs, so the width never changes and no identifier is ever a prefix of a
longer one.

Zero-padded rather than variable-width, because unpadded identifiers sort wrongly as text
and sorting a list of them is the first thing anyone does.

Rejected: **decimal.** It invites arithmetic on an identifier, and `acct_42` reads like a
row number, which is the one impression an opaque handle should not give.

Rejected: **matching the illustrative examples exactly.** `acct_7Q2M9XKV` is eight
characters and `key_3F8A` is four, which cannot both be the same encoding at the same
width. The examples in `02-api.md` and `06-auth.md` are corrected to the real format
instead, because a published example the implementation contradicts is worse than either
choice.

---

## D60 — The metadata document, which `02-api.md` referred to and did not define · locked

`02-api.md` says of a write: "Body is a JSON metadata document (see Metadata shape)."
There is no Metadata shape section. It has been a dangling reference since the API was
written, and the write path is the first thing that has to emit one.

Resolution: **the same document the list endpoint already publishes per entry**, as a
single object rather than inside an array:

```json
{
  "name": "ci/last-green-sha",
  "tags": ["ci", "main"],
  "content_type": "text/plain",
  "size": 13,
  "created_at": "2026-08-30T20:41:07Z",
  "expires_at": "2026-09-06T20:41:07Z"
}
```

Defined once in `02-api.md` and referenced by `PUT`, `POST` and the list, so the three
cannot drift. One renderer in code for the same reason.

The list's shape is the anchor because it is the one already published, and inventing a
second shape for writes would mean a caller that reads its own write back through a
listing gets two different descriptions of one entry.

**`seq` is deliberately not in it.** It is the engine's ordering number, it appears in
`GET /healthz` only as a liveness signal, and putting it on a write response invites
callers to depend on it — at which point it becomes a compatibility obligation and the
write path can never be reordered again. Nothing in the product needs it.

`created_at` on an overwrite is the *new* write's time, because `PUT` replaces the entry
completely including its lifetime (D19). An overwrite is not an edit.

---

## D61 — An idempotency record stores a location, not an outcome · locked

Two locked statements could not both be satisfied, and the write path is where they meet.

`02-api.md` says a replay "replays the recorded outcome (status and metadata)".
`04-storage.md` budgets idempotency records at **~50 B, capped at 1M, ≤ 50 MB**, and D42
locked that cap.

A metadata document (D60) does not fit in 50 bytes. The name alone is up to 256, the tags
up to 324, the content type up to 128. Stored inline, a record is roughly 750 B and the
table is 750 MB at the cap — on a box that also holds a 286 MB index, 65 MB of request
buffers and 107 MB of transport reservation. Inline storage and the cap are mutually
exclusive.

Resolution: **a record stores the packed `Location` of the record it wrote, and a replay
re-reads it.** 48 bytes, under budget:

| field | bytes | why |
|---|---|---|
| key hash | 16 | truncated SHA-256 of `(account_id, key)`. 128 bits is not collidable, and a collision would return another account's outcome |
| body hash | 16 | truncated. Detects same key with a different body, which is `409` |
| location | 8 | the packed segment and offset of the record written |
| status | 1 | `200` or `201`, which a replay must reproduce and cannot re-derive |
| expiry | 4 | 24 hours from insertion |

The location is what makes this work, and it works **uniformly for `PUT` and `POST`**. The
record on disk already holds the name, the tags, the content type, the size and both
timestamps — everything the metadata document needs. So the replay reads one record and
renders the same document the original response did, without the table holding any of it.
It also removes what would otherwise be an asymmetry: a `PUT` replay could have recovered
its name from the request path, but a `POST` replay could not, because that name was
server-assigned.

**A replay returns the original entry's metadata, not the current entry's**, and that is
the correct reading of "the recorded outcome". Segments are append-only and reclaimed
wholesale, so a superseded record is still readable at its old location — an overwrite
between the original and the replay does not change what the replay reports.

Rejected: **raising the cap's memory budget to store outcomes inline.** 750 MB for a
convenience feature, against 286 MB for the index that is the product.

Rejected: **storing the name and re-rendering from the request.** Asymmetric between `PUT`
and `POST`, and a name is 256 B on its own — five times the budget for one field.

Rejected: **re-reading the entry by name rather than by location.** It would return the
*current* entry, so an overwrite between the original and the replay would make the replay
report metadata the original never sent.

**Accepted consequence: a replay whose location no longer reads re-executes.** An entry
with a lifetime under 24 hours can expire, and its segment be reclaimed, while its
idempotency record is still live. The read then fails and there is no outcome to reproduce.
The record is treated as absent and the request executes normally, consuming a credit —
which is precisely the degradation D42 already accepted for a record dropped at the cap:
"dropping a record degrades to re-execution, which is what omitting the header already
does." It needs a retry arriving after the entry has both expired and been reclaimed, which
is rare, and it fails in the direction of doing the work rather than lying about it.

This needs one engine addition: reading a record by location. `Store` gains it rather than
the service reaching into `segs`, per D58.

---

## D62 — The idempotency table is a FIFO ring, in the service layer · locked

**Where.** `src/service/`, owned by the `Service` — not `Control`, even though `Control` is
where D58 put the rate-limit bucket.

The bucket is two fields on an `Account` that already exists, and it survives in RAM beside
state the log does reconstruct. `Control`'s identity is "an append-only log with a full
in-RAM image" (D40), and what makes it auditable is that its memory is exactly its log
replayed. A 50 MB table that is deliberately *never* logged (D42) breaks that
correspondence — it would be the one part of the control plane a replay cannot rebuild.
Idempotency is request-path state, and the service layer is where request-path state lives.

**Structure: a fixed ring of records, plus an open-addressed index into it.**

The eviction rule D42 locked is "records closest to expiry are dropped first". Every record
gets the same 24-hour window measured from its own insertion, so **expiry order is
insertion order** — and dropping the closest to expiry is dropping the oldest. That turns
what sounds like a priority queue into a write cursor that wraps: O(1), no heap, no scan,
no ordering to maintain. When the cursor lands on a live record, that record's index entry
is removed and the slot is reused.

Memory, stated honestly rather than reusing the old estimate: 1M × 48 B for the ring plus a
2M-slot `u32` index at 8 MB is **~56 MB**, not the ≤ 50 MB `04-storage.md` carried. The
figure there was an estimate made before the record had a layout; it is corrected rather
than met by shrinking the cap, because the cap is the published 24-hour window's real
constraint and 6 MB is not worth trading it for.

**Concurrency.** The check-and-reserve is memory-only, so it happens on the event loop
where the rest of validation does (D57) — which also means two requests carrying one key
cannot both pass the check, because a single loop serialises them by construction. The
completion, which records the location and the status, happens on the I/O worker once the
write is durable. The table therefore has its own mutex, because two threads touch it.

That split is what makes `409 idempotency_in_progress` reachable at all: the reservation
exists precisely for the window between the loop admitting the request and the worker
finishing it.

**A reservation is always resolved.** If the write fails, the reservation is removed rather
than left in place — an in-progress marker with no request behind it is the orphan D42
refused to inherit from a durable table, and it would be no better for being in RAM.

---

## D63 — The binary is a composition root, and it ships in M2 · locked

`src/` holds five library modules and no entry point. `build.zig` produces four
executables and every one of them is a harness: `m1`, `crashchild`, `transport` and
`dataplane`. There is no `doot`.

That was correct while M2 was building the layers. It stopped being correct once they were
finished, because three locked decisions now have no production caller at all:

- **D45** locked one maintenance thread. Nothing spawns one. `Store.maintain()` is called
  only from `tools/m1.zig`, and `Control.maintain()` only from tests.
- **D24** locked environment variables as the only configuration mechanism. Nothing in
  `src/` reads an environment variable.
- **D41** depends on a clean shutdown to make credit balances exact. Nothing calls
  `Control.close()` outside tests and harnesses.

The first is not paperwork. `maintain()` is the only production path to `snapshot()`, so a
deployed Doot with no maintenance thread never snapshots — and recovery then replays the
log from the beginning, which is exactly what **D38** says recovery is *not* bounded by. It
also never sweeps expired index slots, never `unlink()`s reclaimable segments, and never
rebuilds dead-heavy shards. M1's fourth exit condition — zero compactions, 51 segments
reclaimed by `unlink` — is a property of maintenance running, and the harness runs it by
hand. On a real box, disk and index would both grow without bound and the ten-second
recovery target would fail on the first long-lived store.

So the binary is not deferred work. It is the missing half of decisions already locked.

**Milestone: M2.**

M5 owns *operations* — the `systemd` unit, boot-time validation as an operator concern, the
restore drill, threshold alerting. It does not own the process those things operate. M2's
edge half has to stand up Origin TLS behind a real Cloudflare zone and run
`ops/sseprobe.py` against `doot.run` until it exits zero, and a milestone cannot verify an
origin it has no way to run. D45 is an M2 decision, so M2 is where it gets implemented
rather than left inert across two more milestones.

**Scope: composition, and nothing else.**

`src/main.zig` reads configuration, opens `Control` and `Store`, allocates the idempotency
table, constructs `Service`, spawns the maintenance thread, arms the `Loop` and runs it,
then shuts down in the reverse order. The `Loop` already owns the I/O worker pool (D57), so
the binary does not wire that.

The rule is that **the binary contains no logic that is not already a library call.**
Anything it would otherwise decide belongs in a module that has tests. This is what keeps
D58's split worth having — the transport's tests still run without a store, a control log
or an account existing — and it keeps the one file that cannot be unit-tested small enough
that not testing it is honest rather than convenient. Behaviour appearing in `main.zig` is
a signal that a module is missing, not that the binary needs a test.

**Configuration: every variable the process uses, and only those.**

D24 is unchanged. But `05-architecture.md` lists the whole eventual set, including R2,
GitHub, ZeptoMail and the admin token, and it also says the binary "refuses to start if any
secret is missing". Requiring all of them in M2 would mean refusing to start over
subsystems that do not exist yet.

So the rule is per-variable rather than per-list: **a variable is required by the milestone
that gains the code which reads it, and nothing is defaulted where a default would be a
hazard.** For M2 that is `DOOT_LISTEN_ADDR`, `DOOT_DATA_DIR`, `DOOT_MAX_INDEX_BYTES`
(required, not defaulted — D43) and `DOOT_HMAC_SECRET`. The storage-shape variables keep
the defaults `04-storage.md` documents. TLS paths become required with the TLS listener; M3
and M5 add theirs alongside the code that reads them.

`DOOT_HMAC_SECRET` is required rather than defaulted for D43's reason in a weaker form. A
cursor signing secret is genuinely rotatable (D46), so a missing one is not data loss — but
a *defaulted* one is a secret no operator ever sets, and pagination cursors would then be
forgeable with a value published in our own source. A fallback here is the same class of
mistake `DOOT_INDEX_HASH_SECRET` was, minus the permanence.

**The maintenance thread, exactly as D45 specified it.**

One thread, and the event loop's one-second tick signals it. The thread wakes, checks
whether sixty seconds have elapsed, and runs `Store.maintain()` when they have.
`Control.maintain()` runs on the same thread: it is a log-rewrite check that costs a
comparison when there is nothing to do and blocks on disk when there is — the same shape,
and the same reason for being off the request path. A second thread for it would be cost
without a benefit. SSE heartbeats join this thread when SSE does.

Signalling rather than sleeping is what D45 already chose, and it has a second payoff here:
a thread waiting to be woken can be woken by shutdown too, so stopping does not wait out a
sleep.

**Graceful shutdown, because a restart is not a crash.**

D41 accepted that a crash can only ever under-charge, and that is a sound trade for a
crash. It is not a sound trade for `systemctl restart`. `Control.close()` writes a credits
checkpoint and `fsync`s it; `abandon()` does not. With no signal handling, every deploy
would rewind every account to its last checkpoint — turning an accepted crash behaviour
into routine leakage on an ordinary operation.

So `SIGTERM` and `SIGINT` stop accepting, drain what is in flight, join the maintenance
thread, then `Store.close()` and `Control.close()`. A response already promised is finished
before the process exits.

Mechanism: a `signalfd` whose read is posted on the ring, so a signal arrives as a
completion alongside every other event rather than through a handler that may do almost
nothing safely. That is the shape D57 already uses for the worker pool's `eventfd`, for the
same reason.

Rejected: **the binary belongs to M5, with the `systemd` unit.** Costed above — M2's own
exit condition needs a running origin, and M5 would inherit two milestones' worth of inert
locked decisions.

Rejected: **promoting `tools/dataplane.zig` to the server.** It hardcodes five API keys,
creates fixture accounts for them, and prints them to stdout. It is a fixture, and shipping
it would ship the credentials every check script authenticates with. The harnesses stay
harnesses.

Rejected: **requiring the full `05-architecture.md` variable list at boot.** It would make
the binary unstartable until M5, which is not failing loudly — it is failing loudly about
the wrong thing.

Rejected: **a plain signal handler that sets a flag.** A handler cannot safely `fsync`, and
a flag the loop polls is what the `signalfd` read already is, without the window between
the flag being set and the loop noticing it.

Rejected: **a configuration file.** D24 settled this and nothing here reopens it.

**Accepted consequence: a shutdown can hang on a stuck `fsync`** past `systemd`'s
`TimeoutStopSec`, at which point the process is `SIGKILL`ed mid-close. That degrades to
exactly the crash shape D41 already accepted and documented, so the worst case is one
already reasoned about rather than a new one.

**M2 amendment — the process layer is a module, `src/boot.zig`.** D63 requires that
`main.zig` hold no logic, and that requirement needs somewhere for the logic to go. The two
existing `config.zig` files are constant *mirrors* (working rule 2) and must stay that way —
neither reads an environment nor makes a policy choice. So a new top-level module, a sibling
of `service`, named for the layer it is: what turns an environment and a signal into a
running, stoppable Doot. It owns environment parsing and validation, the maintenance thread,
signal installation, and the shutdown order — and it is in `zig build test` like every other
module, which is the whole point of it not being in `main.zig`.

**M2 amendment — shutdown uses `sigaction` and `Loop.stop()`, not a `signalfd` on the
ring.** D63 chose `signalfd` by analogy with D57's `eventfd`, and reading the transport
afterwards showed the analogy was wrong. `Loop.stop()` already exists, is one atomic store,
and is documented "safe from another thread or a signal handler"; `Loop.iterate()` already
treats `error.SignalInterrupt` from `submit_and_wait` as benign and returns, so a signal
breaks the wait immediately and `run()`'s next predicate check exits. A handler that calls
`stop()` therefore needs no new mechanism and does the least a handler can do.

`signalfd` would mean a new `Op` variant, a posted read, and a completion branch **inside
the loop** — new logic in the transport, for a process-lifecycle concern the transport is
specified not to know about (D58), to replace a path that already works. The `eventfd` in
D57 earned its place because there was no other way for a worker thread to wake the ring.
Here there is.

**M2 amendment — `SIGTERM` and `SIGINT` are blocked in every thread but the one that runs
the loop.** This is a durability point, not tidiness. Signal disposition is per-process but
*delivery* is per-thread, so an unblocked `SIGTERM` can land on an I/O worker and return
`EINTR` from the `fsync` it was in the middle of. The mask is therefore set before
`Loop.init` starts the worker pool and before the maintenance thread is spawned — both
inherit it — and unblocked in the main thread only once everything is running. Only the
thread that can act on the signal can receive it.

**M2 amendment — "drain what is in flight" was too strong, and is corrected.** There is no
quiesce mode in the transport and this decision does not add one. What is actually
guaranteed, and it is the part that matters: `Loop.deinit` stops the worker pool first, and a
pool worker only exits once the queue is empty, so **every storage operation already handed
to the pool runs to completion before anything is closed or freed.** No `fsync` is cut
short, and the store is closed after the last one returns.

What is *not* preserved is the reply on the socket: connections still open are force-closed.
That is the "brief connection reset" `05-architecture.md` already accepts on a beta-labelled
single-box service, and it is safe for a different reason worth stating — a write whose
response was lost is still durable, and idempotency (D20) is exactly the mechanism that
makes the client's retry free and unambiguous. Promising a drain we do not implement would
be worse than documenting the reset we do.

**M2 amendment — two environment formats, settled rather than left to the code.**
`DOOT_MAX_TTL` takes the same grammar as `X-Doot-TTL` (D47) — digits with an optional
single `s`/`m`/`h`/`d` suffix — parsed by the same `api.parse.ttl`. Two lifetime grammars in
one product is a trap, and the operator-facing one should be the one already documented.
D47 deliberately performs no range check, so `boot` applies the policy: below
`storage.config.min_ttl_s` is refused at boot rather than at the first write. No upper bound
is imposed, because the storage layout derives from this figure (D10) and `01-product.md` is
explicit that the ceiling moves with observed usage.

`DOOT_HMAC_SECRET` is **exactly 64 lowercase hex characters**, decoded to the 32 bytes
`api.cursor` signs with. Fixed-length and one encoding, so a truncated paste is refused
instead of silently becoming a shorter secret — the failure a variable-length or
"whatever bytes you typed" reading would hide.

**M2 amendment — a maintenance failure is logged and never fatal.** `Store.maintain()` and
`Control.maintain()` both return errors, and the tempting reading is that a process which
cannot maintain itself should die. It is the wrong reading. Expiry is authoritative at the
index and evaluated lazily on every read (`03-data-model.md`), so a failed sweep is a
deferred sweep and no caller can observe it. A failed snapshot lengthens the next recovery,
which D38 already frames as a bounded and observable quantity rather than a correctness
property. Exiting would convert a recoverable, invisible condition into a total outage. The
thread logs each failure and counts it, and the count is what M5's `/admin/stats` surfaces.

**M2 amendment — logging scope.** D63 ships boot and lifecycle diagnostics on stderr and
nothing more. The structured per-request JSON log `05-architecture.md` describes stays with
M5's observability work, because it carries a redaction contract — no bodies, names, API
keys or codes — that deserves its own pass rather than riding along inside a lifecycle
decision.

**Accepted consequence: a freshly deployed Doot has no accounts, so it answers `401` to
everything.** The binary deliberately gains no account-creation path: M3 owns signup, and
inventing an operator subcommand here would be scaffolding built to be replaced. The
consequence is real, though — M2's edge slice needs at least one account to point `curl` and
`ops/sseprobe.py` at, so *how the first account comes into being* is an open question owned
by whichever of the edge slice or M3 arrives first. It is recorded here rather than answered,
because answering it now would mean guessing at M3's shape.

---

## Deferred

| item | trigger to reopen |
|---|---|
| Multi-tag intersection on list | users asking for it with concrete cases. Cheap to add — walk one chain, filter on the rest — but every query-shaped feature erodes D1 and it should cost a real conversation |
| `ETag` / `If-None-Match` on read | measurable read bandwidth cost. Needs a stored content hash |
| Conditional writes / compare-and-swap | a genuine lock-contention use case. Would be `If-Match` on `PUT`, not a new endpoint |
| Public unauthenticated read links | demand for sharing. Currently all reads require a key so they stay attributable |
| Automated payments | trial-to-paid conversion volume making manual handling the bottleneck (D9) |
| Teams and shared accounts | paid single-user retention proving out first |
| In-house TLS 1.3 server | vendored library becoming a maintenance problem, or wanting the dependency count at zero (D13, D29) |
| HTTP/2 at the origin | only if the edge stops being the sole client (D13) |
| Removing the toolchain patch | upstream fixing the 0.16.x `std.Io.Uring` error sets, or a 0.16.1 release (D26) |
| Power-loss durability testing | a deployment target where `dm-flakey` or a VM power cut is available. Until then the gap in D36 stands stated |
| Parallelising the write path | measurement showing the single write lock is a bottleneck. At 0.03% of request cost this is far off (D35) |
| A user-space staging buffer for appends | measurement showing syscall count on the write path matters (D34) |
| Implementing the segment compactor | a segment actually meeting the escape-hatch trigger in production. Over a 24 h soak none did (D10) |
| Widening the index slot to carry `seq` | a need to arbitrate replay order without the class merge. Would cost 8 B/entry, a 40% memory increase (D38) |
| Revisiting `std.Io` as the concurrency layer | a Zig release where the io_uring backend implements networking. Would be a large rewrite of the event loop for no measured gain, so it needs a reason beyond tidiness (D27) |
| Long-polling instead of SSE for the live view | only if `sseprobe.py` fails against the real Cloudflare zone after the D31 configuration is applied |
| One ring per core via `SO_REUSEPORT` | measured single-ring throughput becoming a constraint. At 2.9M req/s on one thread this is far off (D27) |
| Chunked request bodies | a real caller unable to send `Content-Length` |
| 90-day retention | usage behaviour justifying it, **and** a proven restore drill (D16). Retention is a config value, not a code change |
| Read-side soft caps | the pooled rate limit (D6) proving insufficient against a heavy read pattern |
| Capping `SO_SNDBUF` on accepted sockets | **M5, on the deployed link.** A parked response holds up to 260 KiB of kernel socket memory that no accounting of ours sees (D54). Capping bounds it and makes the partial-write path ordinary, but it disables send-buffer autotuning, and whether that is free or a throughput ceiling depends on the edge-to-origin bandwidth-delay product. Not answerable over loopback |
| Flushing credit deductions on the entry's own group commit | credits becoming a real revenue mechanism rather than a beta trial grant. Would make the balance exact across a crash, at the cost of a fifth append stream through measured M1 code (D41) |
| Durable idempotency state | evidence that retries straddling a restart actually happen. Costs an `fsync` on the common write path and reintroduces orphaned in-progress keys (D42) |
| Monotonic ULIDs | a caller depending on the ordering of two entries created in the same millisecond. Nothing in the product observes it today (D47) |
| Compound `X-Doot-TTL` forms such as `1h30m` | callers actually asking. Each extension invites the next, and four suffixes cover what a shell script needs (D47) |
