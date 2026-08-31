# Architecture

## Shape

One statically linked binary, one process, one machine. No sidecars, no reverse proxy
on the box, no separate frontend build, no control-plane/data-plane split, no
container orchestration.

```
  clients (curl, n8n, CI, edge functions, browsers)
        │  HTTPS / HTTP/2 / HTTP/3
        ▼
  Cloudflare edge — TLS termination, anycast, WAF, volumetric shedding
        │  HTTPS (HTTP/1.1), Full (strict), Authenticated Origin Pulls
        ▼
  ┌──────────────────────────────────────────────┐
  │  doot   (single Zig binary)                   │
  │                                               │
  │  TLS 1.3 server (vendored, compiled in)      │
  │  HTTP/1.1 + keep-alive                        │
  │  router → data plane  /v1/*   (API key)       │
  │         → control plane /app/* (session)      │
  │         → dashboard assets (@embedFile)       │
  │  storage engine (04-storage.md)               │
  │  control-plane log + in-RAM image (D40)       │
  │  change feed ring → SSE                       │
  │  backup uploader → R2                         │
  │  outbound HTTPS client → ZeptoMail, GitHub    │
  └──────────────────────────────────────────────┘
        │
   local NVMe                    Cloudflare R2
```

Everything above the storage engine is request handling. There is no internal service
boundary because there is no second machine to put one across.

## The network path is the performance story

Storage is not the bottleneck and optimising it is measuring the wrong thing. A cold
request from Mumbai to an origin in Nuremberg:

| stage | cost |
|---|---|
| TCP handshake | ~130 ms |
| TLS 1.3 handshake | ~130 ms |
| request / response | ~130 ms |
| **storage lookup** | **~0.1 ms** |

Storage is **0.03%** of what the user experiences. Connection establishment is
everything.

### Cloudflare is a latency win, not a tax

| scenario | direct to origin | via Cloudflare |
|---|---|---|
| cold client | ~390 ms | **~175 ms** |
| warm client connection | ~130 ms | ~145 ms |

TLS terminates at the PoP nearest the client (~15 ms), and Cloudflare reuses a warm
pooled connection to the origin — so a cold client pays two fast round trips to the
edge plus one slow hop on an already-open connection, instead of three slow round
trips.

Cloudflare loses slightly on warm connections. It does not matter: Doot's callers are
bash scripts, CI jobs, webhook senders and serverless invocations, which are almost
always cold. **For the actual usage pattern the edge is roughly 2× faster.**

### What the edge lets us not build

- **HTTP/2 and HTTP/3.** Cloudflare speaks HTTP/1.1 to the origin. Clients get h2 and
  h3 at the edge. The origin implements HTTP/1.1 only — two substantial protocol
  stacks we never write.
- **Response compression.** Handled at the edge.
- **TLS session resumption and 0-RTT** for clients. Edge concern.
- **Volumetric abuse shedding.** Edge rules drop it before it reaches the box.

### TLS at the origin

Cloudflare terminating TLS solves the client→edge hop. It does not solve edge→origin.
Running that hop in cleartext (`Flexible` mode) would put bearer tokens on transit
networks unencrypted — unacceptable, and catastrophic to walk back after a disclosure.

Zig's standard library ships a TLS *client* but no TLS *server*
([ziglang/zig#14171](https://github.com/ziglang/zig/issues/14171)). Resolution:

- **Vendor a pure-Zig TLS 1.3 server** ([tls.zig](https://github.com/ianic/tls.zig))
  as source, compiled into the binary. One artifact, one process — the single-binary
  goal is fully intact. Source dependencies are not sidecars.
- Behind a thin internal interface (`tls.Listener`), so the implementation is
  swappable without touching request handling. A seam, not scaffolding.
- **Cloudflare Origin CA certificate** — free, 15-year validity. No ACME client, no
  renewal automation, no expiry surprises.
- **`Full (strict)`** mode, origin firewalled to Cloudflare IP ranges, **Authenticated
  Origin Pulls** enabled so the origin refuses anything that did not come through
  Cloudflare.

The interop surface is exactly one peer, forever. One TLS version, one cipher suite,
no client auth, no resumption. That narrowness is what makes an eventual in-house TLS
1.3 server a bounded piece of work rather than recklessness — `std.crypto` already has
every primitive (`aes_gcm`, `chacha_poly`, `X25519`, `P256`, `hkdf`, `Certificate`
X.509 parsing); only the server handshake state machine is missing. Tracked, not
scheduled.

## Concurrency

Zig **0.16.0**, pinned, with the stdlib patch from `toolchain/`. io_uring driven
**directly** via `std.os.linux.IoUring` — not through `std.Io`, which cannot do it on
this toolchain (D26, D27).

- One event loop per worker thread, each with its own ring and its own `SO_REUSEPORT`
  accept socket. No shared accept lock, no thundering herd.
- `accept_multishot` for the listen socket, so the kernel re-arms accepts rather than
  us re-posting one per connection. Re-post only when `IORING_CQE_F_MORE` is clear.
- **A repeating `timeout` SQE is mandatory.** An otherwise-idle ring blocks forever in
  `copy_cqes` and no housekeeping runs. The same timer drives expiry sweeps, SSE
  heartbeats and stats, so it is not overhead.
- Connections are pinned to the worker that accepted them. Connection state is a plain
  struct we size ourselves, from a pooled slab — not a fiber with a reserved stack.
- Index shards (64) are lock-protected, so any worker can serve any read. **Writes take one
  global lock and reads take none** (D35); shard locks protect structure only and are never
  held across disk I/O.
- **There is no staging buffer and no commit thread** (D34). Records are `pwrite`n on arrival
  and only the `fsync` is batched, by whichever writer needs durability first. Every other
  writer waiting at that moment is covered by the same flush.
- Background threads: **maintenance** (expiry sweep, segment reclamation, index shard
  rebuild, snapshot — D45), backup uploader, outbound mail. All off the request path.
- The event loop's repeating `timeout` SQE fires at **1 s** and does only cheap work:
  connection idle timeouts, stats, and signalling the maintenance thread. `Store.maintain()`
  itself runs on that thread every **60 s**, because it blocks on disk and would otherwise
  stall every connection pinned to the worker.

Driving the ring ourselves is more code than calling `std.Io`, and it is the right
trade: it is the layer Doot most needs control over, and on Zig 0.16.0 the alternative
does not function. `std.Io.Uring` stubs out its entire networking surface, and
`std.Io.Threaded` wedges permanently after `async_limit` keep-alive connections because
each idle one owns a pool thread.

Measured on a single thread, pipelined over loopback with client and server sharing 8
cores — a floor, not a ceiling: **2.9–3.2M req/s**. Roughly a hundred times any
plausible demand, which is the point: the box is never the constraint.

**Ring buffer ownership.** Any buffer handed to the ring belongs to the kernel until its
completion arrives. Reusing one before then corrupts data in flight — measured, not
theoretical (D30). Buffers shared across many sends must either be written once and
never mutated, or refcounted and released on completion.

## HTTP behaviour that actually matters

Each of these is worth more than any storage micro-optimisation.

- **Keep-alive on by default**, idle timeout **75 s** — deliberately longer than
  Cloudflare's origin idle timeout so the edge, not the origin, decides when to close.
  No maximum-requests-per-connection cap.
- **`TCP_NODELAY`.** The Nagle / delayed-ACK interaction is a silent 40 ms tax on small
  responses, which is what Doot almost exclusively returns.
- **Headers and body in a single `writev`.** One syscall per response.
- **Reject oversized bodies from `Content-Length`, before reading.** `413` immediately;
  never drain an upload we intend to refuse.
- **Handle `Expect: 100-continue`.** `curl` sends it for larger bodies and stalls a
  full second if it is ignored — a real, frequently-shipped bug.
- **Buffers pooled per in-flight request, not per connection.** 256 concurrent × 260 KiB
  = 65 MB of body buffers total, independent of idle connection count. The slot is 260 KiB
  and not 256 KB because a read must hold a whole record, which tops out at 262,929 bytes —
  785 more than a 256 KB slot, and 266,240 is the next page multiple (D51). At around 5M
  entries idle connections would otherwise outweigh the index (`04-storage.md`).
  Measured at 10,000 idle keep-alive connections (D28): naive allocation costs
  **8.11 KB/conn (79 MB)**; pooling connection structs into a static array and read
  buffers into one arena drops that to **2.14 KB/conn (21 MB)** at a 2 KB buffer, and
  **0.63 KB/conn (6.3 MB)** at 512 B. Resident cost is pages *touched*, not bytes
  allocated, so the idle read buffer should be small — a request head is capped at 8 KB,
  but an idle connection needs only enough to notice one starting.
- **Bounded request line and header sizes** (8 KB total), rejected early.
- **No chunked request bodies in v1.** `Content-Length` required on writes; that is
  what lets us reject oversized uploads before reading and keeps buffer sizing static.
  `411 Length Required` otherwise.

## Dashboard delivery

Read-only explorer plus account management. Plain HTML, CSS and vanilla JS — no
framework, no bundler, no build step, no separate deployment.

- Assets embedded at compile time with `@embedFile`, served from memory with strong
  `ETag`s derived from the build hash. The binary is genuinely self-contained.
- Session cookie authentication, `HttpOnly; Secure; SameSite=Lax`.
- **Live view over SSE** on the control plane, filtered to the session's account from
  the change feed ring (`04-storage.md`).
- Rendering keys off the stored `Content-Type`: JSON as a collapsible tree, text as
  text, anything else as a hex/size summary. The server never parses bodies.

### SSE, and the Cloudflare hazard

Our side is measured and correct (D18, D30): headers flush immediately with an opening
comment so the client's stream opens before the first event exists, events arrive at
exactly the emit interval, and 5,000 concurrent subscribers cost **4.33 KB each
(21.7 MB)**. Response headers are `Content-Type: text/event-stream`,
`Cache-Control: no-cache, no-store, no-transform`, `X-Accel-Buffering: no`, no
`Content-Length`, plus periodic heartbeat comments.

**Cloudflare is a live risk to this feature, not a hypothetical one.** Buffering of
`text/event-stream` has been reported repeatedly across years, and for most of that
history the only workaround was turning the proxy off. There is now a first-class fix —
a Configuration Rule setting response body buffering to `none`, available on the Free
plan — but it must be applied and then *verified*. Full reasoning, the complete zone
configuration, and the fallback if it fails are in D31.

Two consequences for this document:

- **The heartbeat has a ceiling, not just a purpose.** Cloudflare's proxy read timeout
  on Free and Pro is 100 seconds; an origin that sends nothing in that window gets a
  524. Heartbeat interval is therefore **15 seconds**.
- **Caching is bypassed for all of `/v1` and for the stream path.** A stale read breaks
  the state-storage use case outright, which is a large part of why anyone would adopt
  Doot.

`ops/sseprobe.py` is the verification procedure. It is the one artifact that survived the
deletion of `spikes/` (D49): point it at the live origin and it judges streaming on arrival
timing rather than content, because a buffering proxy still delivers every event — just late
and all at once.

## Outbound calls

Two, both plain HTTPS via `std.http.Client` with `std.crypto.tls` — stdlib only, no
dependency.

| target | purpose |
|---|---|
| ZeptoMail REST API | OTP codes, credit-threshold notifications |
| GitHub | OAuth token exchange, user identity |
| Cloudflare R2 | segment and snapshot backup (S3-compatible, SigV4) |

Outbound calls never block a request: OTP sends are queued to a background worker, and
the request returns as soon as the code is persisted. Retries with backoff, bounded
queue, failures logged and counted.

SigV4 signing for R2 is HMAC-SHA256 — `std.crypto` covers it.

## Configuration

Environment variables only. No config file format, therefore no parser, therefore no
dependency and no ambiguity about precedence.

```
DOOT_LISTEN_ADDR            DOOT_TLS_CERT_PATH        DOOT_TLS_KEY_PATH
DOOT_DATA_DIR               DOOT_MAX_TTL              DOOT_SEGMENT_BYTES
DOOT_MAX_INDEX_BYTES        DOOT_SNAPSHOT_INTERVAL_S  DOOT_BACKUP_INTERVAL_S
DOOT_R2_ENDPOINT            DOOT_R2_BUCKET
DOOT_R2_ACCESS_KEY_ID       DOOT_R2_SECRET_ACCESS_KEY
DOOT_GITHUB_CLIENT_ID       DOOT_GITHUB_CLIENT_SECRET
DOOT_ZEPTOMAIL_TOKEN        DOOT_SUPPORT_EMAIL
DOOT_HMAC_SECRET            DOOT_ADMIN_TOKEN
```

The binary refuses to start if any secret is missing or a path is unwritable. Failing
loudly at boot beats discovering it during the first write. `DOOT_MAX_INDEX_BYTES` is
included in that: without it the index has no ceiling and admission control never engages,
so it is required rather than defaulted (D43).

**Two variables were removed rather than left unimplemented.**

`DOOT_COMMIT_INTERVAL_MS` went with D34 — leader commit has no interval to configure, and
`04-storage.md` records the constant as deliberately absent.

`DOOT_INDEX_HASH_SECRET` went with D43, and that one was a hazard rather than dead weight.
The index hash key is baked into every slot and every hash in `SNAPSHOT`, so it must be
byte-identical on every boot for the lifetime of the data. As an environment variable, a
typo silently made every entry unfindable while the store reported itself healthy. It is now
generated once at initialisation and persisted in `STORE` alongside the data
(`04-storage.md`). It is not configurable, and rotating it is a destructive operation rather
than a security one.

## Deployment

- One `systemd` unit, one binary, one data directory.
- Deploy is: copy binary, `systemctl restart`. Recovery is under 10 seconds
  (`04-storage.md`), which is the entire restart window.
- Restarts are visible as a brief connection reset. Acceptable and documented on a
  beta-labelled single-box service; pretending otherwise would require a second
  machine.
- **Zig toolchain pinned to an exact 0.16.x version and tarball hash**, recorded in
  the repository and enforced in CI. Zig makes breaking changes between minor
  releases; upgrading is a deliberate, reviewed act, never an accident of whatever
  the build machine happened to have.

## Observability

Minimal by necessity — no metrics stack means no dependency.

- **Structured JSON logs to stdout**, captured by the journal. One line per request:
  method, path shape (never the name), status, bytes, duration, account id.
- **Bodies, names, API keys, cookies and OTP codes are never logged.** Names can carry
  user semantics, and there is no reason to hold them in a log.
- `GET /healthz` — public, liveness plus current `seq`.
- `GET /admin/stats` — `DOOT_ADMIN_TOKEN`-authenticated JSON: live entries, index
  utilisation, per-class segment counts, commit latency percentiles, tag traversal hop
  distribution, connection counts, credit and rate-limit rejection counters, backup lag,
  corruption counter.

Four numbers matter most day to day: **index utilisation, disk utilisation, backup lag,
and recovery time at last restart.** Each has a threshold in `04-storage.md` and each
maps to a specific operator action.
