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
