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

## Deferred

| item | trigger to reopen |
|---|---|
| Multi-tag intersection on list | users asking for it with concrete cases. Cheap to add — walk one chain, filter on the rest — but every query-shaped feature erodes D1 and it should cost a real conversation |
| `ETag` / `If-None-Match` on read | measurable read bandwidth cost. Needs a stored content hash |
| Conditional writes / compare-and-swap | a genuine lock-contention use case. Would be `If-Match` on `PUT`, not a new endpoint |
| Public unauthenticated read links | demand for sharing. Currently all reads require a key so they stay attributable |
| Automated payments | trial-to-paid conversion volume making manual handling the bottleneck (D9) |
| Teams and shared accounts | paid single-user retention proving out first |
| In-house TLS 1.3 server | vendored library becoming a maintenance problem, or wanting the dependency count at zero (D13) |
| HTTP/2 at the origin | only if the edge stops being the sole client (D13) |
| Chunked request bodies | a real caller unable to send `Content-Length` |
| 90-day retention | usage behaviour justifying it, **and** a proven restore drill (D16). Retention is a config value, not a code change |
| Read-side soft caps | the pooled rate limit (D6) proving insufficient against a heavy read pattern |
