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
  │  change feed → SSE                            │
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

Zig **0.16**, pinned. `std.Io` with the io_uring backend on Linux.

- `SO_REUSEPORT`, N worker threads (N = core count), each with its own io_uring and
  its own accept queue. No shared accept lock, no thundering herd.
- Connections are pinned to the worker that accepted them.
- Index shards (64) are lock-protected, so any worker can serve any request. Storage
  appends go through per-class staging buffers with a dedicated commit thread.
- Background threads: commit, snapshot, segment reclamation, backup uploader, outbound
  mail. All off the request path.

The io_uring model is chosen for idle connection cost, not raw throughput.
Thread-per-connection at 8 MB of stack makes ten thousand idle keep-alive connections
impossible; io_uring with small per-connection state makes it routine. Since keep-alive
is the single highest-leverage latency optimisation available, the concurrency model
has to make idle connections cheap.

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
- **Buffers pooled per in-flight request, not per connection.** 256 concurrent × 256 KB
  = 64 MB of body buffers total, independent of idle connection count. Idle connections
  hold ~8 KB each. At around 5M entries idle connections would otherwise outweigh the
  index (`04-storage.md`).
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

**Verify early: Cloudflare's buffering behaviour on SSE.** This is the one edge
behaviour that could quietly break the feature the product is betting adoption on. It
is milestone M0 in `08-roadmap.md`, not a launch-week discovery. Responses are sent
with `Content-Type: text/event-stream`, `Cache-Control: no-cache`,
`X-Accel-Buffering: no`, and periodic heartbeat comments to keep intermediaries from
idling the stream out.

Caching is **bypassed for all of `/v1`**. Stale reads would break the state-storage
use case outright, which is a large fraction of why anyone would adopt Doot.

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
DOOT_MAX_INDEX_BYTES        DOOT_COMMIT_INTERVAL_MS   DOOT_SNAPSHOT_INTERVAL_S
DOOT_BACKUP_INTERVAL_S      DOOT_R2_ENDPOINT          DOOT_R2_BUCKET
DOOT_R2_ACCESS_KEY_ID       DOOT_R2_SECRET_ACCESS_KEY
DOOT_GITHUB_CLIENT_ID       DOOT_GITHUB_CLIENT_SECRET
DOOT_ZEPTOMAIL_TOKEN        DOOT_SUPPORT_EMAIL
DOOT_HMAC_SECRET            DOOT_INDEX_HASH_SECRET
DOOT_ADMIN_TOKEN
```

The binary refuses to start if any secret is missing or a path is unwritable. Failing
loudly at boot beats discovering it during the first write.

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
