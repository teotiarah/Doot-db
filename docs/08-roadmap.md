# Roadmap to first public deploy

Ordered by **risk retired per unit of work**, not by how the product reads on a page.
The unknowns that could invalidate the design come first; the parts that are merely
laborious come last.

Each milestone has an exit condition that is a demonstrable fact, not a feeling.

---

## M0 — Retire the unknowns · **COMPLETE**

Throwaway spikes, deleted at M1 exactly as intended (D49) and recoverable from git history
at `4547b32`. Findings are D26–D31 in `07-decisions.md`, with amendments on D3, D13, D14
and D18.

| spike | question | outcome |
|---|---|---|
| io_uring throughput and idle cost | requests/sec, and RSS at 10k idle keep-alive connections | **2.9–3.2M req/s** single-threaded; **8.11 KB/conn** naive, **0.63–4.14 KB/conn** pooled. D14's estimate was accurate to 1.4% — but the mechanism changed (D27, D28) |
| Origin TLS | does a vendored pure-Zig TLS 1.3 server work, including Authenticated Origin Pulls? | **Yes, fully.** Verified against OpenSSL 3.5.7, EC and RSA chains, mTLS correct in both directions, 7.3 MB static binary with no OpenSSL. Runs on the raw ring (D29) |
| SSE through Cloudflare | does the edge stream `text/event-stream` without buffering? | **Our side correct and cheap** (4.33 KB/subscriber at 5,000). Found and fixed a frame-corruption bug (D30). **Cloudflare remains unverified and is a real risk with a documented fix** (D31) |

It earned its place. Three things would have gone undetected into later milestones:
`std.Io` cannot do networking on the pinned toolchain at all; a shared io_uring send
buffer silently corrupts frames above ~50 concurrent subscribers; and Cloudflare
buffering SSE is a known, recurring failure that needs specific zone configuration.

**Not closed:** the Cloudflare half of the SSE question needs the live zone. The probe
that answers it (`ops/sseprobe.py`) is written and must be run against `doot.run` before
M4 builds the dashboard on the assumption it streams.

---

## M1 — Storage engine, standalone · **COMPLETE**

No HTTP. A library plus a test harness, because this is the part that is expensive to get
wrong and impossible to fix casually later.

Implemented in `src/storage/`; harness in `tools/`. Findings are D32–D39 in
`07-decisions.md`, four of which corrected the specification. Reading the engine as its
first caller during M2's decision pass turned up two more defects and a measurement caveat:
D48 and D51.

- Record format, CRC32C verification, packed locations
- Four lifetime-class append streams, 64 MiB segments, sealing
- Sharded index (20-byte slots, keyed hash, name verification on read)
- Tag chains: per-tag back-pointers, in-RAM heads, bounded validated traversal
- Group commit with `fsync`, global `seq`
- Shard-at-a-time snapshots; recovery from snapshot + tail replay
- Wholesale segment reclamation on expiry; class-0 tombstones
- Capacity ceiling and admission control

**Exit conditions — all met.** Reproduce with
`zig build verify && ./zig-out/bin/m1 all <workdir>`, and note that `<workdir>` should be on
tmpfs (D48). CI runs exactly this on every push (D50).

**One caveat on the recovery row.** `m1 all` runs the recovery check at its 300,000-record
default — about 30 seconds of tail, not the five minutes the condition names. It reproduces
the replay *rate* (measured again at 349 MiB/s) but not the *scale*, so the 3,000,000-record
figure below comes from asking for it explicitly:
`./zig-out/bin/m1 recovery <workdir> 3000000`. Since recovery time is bounded by the
snapshot interval rather than the dataset (D38), the rate is the load-bearing number and the
scale is the condition's wording — whether CI should run the full scale is grouped with M2's
outstanding exit-condition work rather than settled here.

| condition | target | measured |
|---|---|---|
| crash at every `fsync` boundary loses nothing acknowledged, resurrects nothing | all boundaries | **41/41 boundaries**, all killed mid-run, all recovered |
| recovery with 5 minutes of tail at 10k writes/s | < 10 s | **9.5 s** for 3,000,000 records / 3,147 MiB (332 MiB/s), on tmpfs |
| index RAM per live entry | 28.57 B ± 10% | **29.40 B** at 972k entries, occupancy 0.680 |
| compaction events in a 24 h mixed-lifetime soak | 0 | **0**, and 0 segments even met the trigger; 51 reclaimed by unlink |
| tag traversal across overwrite, delete, expiry, class change | correct | **3 live of 9 hops**; stale, deleted and expired all excluded |

111 unit tests alongside the harness at the time M1 closed. The engine module carries **140**
now, having gained the `STORE` identity file and the change feed ring as M2 prerequisites.

**What the crash sweep does and does not prove.** It proves recovery is correct at every
flush boundary — torn tails, half-written snapshots, rotation in flight. It cannot prove
`fsync` was called, because `SIGKILL` kills a process while dirty page cache survives it.
That gap was found by mutation testing and closed with white-box durability assertions at
the moment of acknowledgement; true power-loss testing needs a block layer that discards
un-flushed writes. Full reasoning in D36.

**Recovery margin is 5%**, which makes the relationship more useful than the number:
recovery time is bounded by the snapshot interval, not by how much data is stored. See
D38 for the formula and the operational lever.

**The recovery figure is a warm-page-cache number and the harness's write phase is not a
throughput measurement.** Both were measured on tmpfs; the same harness on a persistent
volume writes ~200/s against ~41,000/s, because a single-threaded workload gives every write
its own flush leader with nobody to piggyback. That is D34 behaving correctly, not a
regression — but it means M5 has to re-measure recovery on the deployed volume from a cold
cache. Full reasoning in D48.

Four bugs worth noting, all found by tests rather than by review, and all of the kind
that only appear on a second run: a directory iterator that left its file descriptor at
EOF so the *second* startup discovered no segments and silently recovered an empty store;
a stream holding a slice into a freed list; a self-referential pointer invalidated by a
struct copy; and `record.decode` leaving a tag slice aimed at the caller's stack frame.

---

## M2 — Data plane · **IN PROGRESS**

The seven endpoints. Product-visible for the first time, on top of the M1 engine.

**Where it stands:** the endpoints are built and verified over HTTP. What remains is the
origin binary that runs them (D63), the SSE consumer for the D44 ring, the edge, and two
exit conditions that the code can already be measured against.

### Pass 1 — decisions · **COMPLETE**

D40–D51 in `07-decisions.md`, with amendments on D11, D18, D20 and D38. Nothing about the
data plane was left for an implementation diff to decide. The substantial ones:

| decision | what it settled |
|---|---|
| D40 | where accounts, API keys, sessions and credits live — an append-only `CONTROL` log with a full in-RAM image, because nothing in the entry store can outlive its own expiry |
| D41 | credit balances are authoritative in RAM and checkpointed, and a crash can only ever under-charge |
| D42 | idempotency state is RAM-only and does not survive a restart, stated in the published docs rather than implied away |
| **D43** | the index hash key is generated once into a `STORE` file, not configured. As an environment variable it was a silent, unrecoverable data-loss path |
| D44 | the change feed ring ships here, not in M4, because the write path is what publishes to it |
| D45 | `Store.maintain()` runs on a maintenance thread, not the event-loop tick |
| D46 | the pagination cursor's signed wire format, byte for byte |
| D47 | the `X-Doot-TTL` grammar, `X-Doot-Tags` parsing order, name percent-decoding, and non-monotonic ULIDs |

Twelve further decisions (D52–D63) were forced by writing the code, each settled in its own
pass before the code it governs, per sequencing rule 2.

### Pass 2 — engine prerequisites · **COMPLETE**

Small, and they came first because they change a file format and a threading contract:

- `STORE` identity file, read before the index is constructed (D43)
- `src/storage/feed.zig` — the change feed ring, published under the write lock (D44)
- `Store.delete`'s 257 KiB stack buffer, and `Store.get`'s buffer contract (D51)
- `Store.maintain()`'s doc comment corrected to match where it actually runs (D45). **The
  comment was corrected; the thread it describes was not created.** That gap is D63's, and
  it matters more than a comment: `maintain()` is the only production path to `snapshot()`

### Pass 2 — the data plane · **COMPLETE**

Verified by 404 unit tests, 44 `curl` transport checks and 145 `curl` data-plane checks,
all in CI.

- HTTP/1.1 with keep-alive, `TCP_NODELAY`, single-`writev` responses,
  `Expect: 100-continue`, early `413`, bounded header sizes — verified against `curl` as
  well as against our own client
- The I/O worker pool every storage call goes through, and the `eventfd` its completions
  come back on (D57). It came before the endpoints because it is the thing they are built
  on, and because it is what makes leader commit batch at all
- Plan limits as a table, so the rate limit, `whoami` and `ttl_too_long` all read the same
  numbers (D56)
- Router, API key authentication, per-account pooled token bucket
- The `CONTROL` log and its in-RAM image (D40, D41)
- All seven endpoints per `02-api.md`
- Validation in the order given in `03-data-model.md`, with the parsing rules in D47
- Idempotency: 24-hour window, free replays, `409` on conflict (D42, D61, D62)
- Credit accounting: deduct, refund on failure, `402` on exhaustion
- Error catalogue with stable codes; HMAC-signed pagination cursors (D46)

### Pass 2 — the origin binary · **COMPLETE**

Decided in D63. Nothing here was new design; it was the missing caller for decisions already
locked, and it is what turns a set of libraries into something that can be deployed.
Verified by 23 unit tests over the process layer and 30 `curl`-and-signal checks against the
running binary (`tools/boot-check.sh`), both in CI.

- `src/main.zig` as a composition root: configuration, `Control`, `Store`, the idempotency
  table, `Service`, the maintenance thread, the `Loop`. No logic that is not already a
  library call
- `src/boot.zig` — the process layer, and where that logic lives instead: environment
  parsing, the maintenance thread, signals, and the shutdown order. Tested like every other
  module
- Environment-variable configuration (D24) — the first code in the tree to read one.
  Required in M2: `DOOT_LISTEN_ADDR`, `DOOT_DATA_DIR`, `DOOT_MAX_INDEX_BYTES`,
  `DOOT_HMAC_SECRET`
- **The maintenance thread (D45).** Without it nothing sweeps expired slots, reclaims
  segments, rebuilds dead-heavy shards or snapshots — and with no snapshots, recovery
  replays the whole log and D38's bound does not hold
- Graceful shutdown on `SIGTERM` via `Loop.stop()`, so `Control.close()` checkpoints credits
  instead of every deploy rewinding them (D41). Signals are blocked in every thread but the
  one running the loop, so a `SIGTERM` cannot land on a worker mid-`fsync`
- `server.Tick`, the seam the loop's tick wakes the maintenance thread through. D45 and
  `server/config.zig` both described the tick as doing this; until now there was nothing for
  that to be true through

**Measured on the running binary rather than asserted:** a `SIGTERM` restart preserves a
credit balance exactly, a `SIGKILL` restart rewinds it to the last checkpoint — which is
D41's accepted crash shape, and the contrast is what shows the shutdown path is load-bearing
rather than decorative.

### Pass 2 — the live feed · **COMPLETE**

Decisions D84–D87, with amendments on D68, D86 and D87 — two of which corrected a shape that
could not have worked. Built:

- a third `Disposition`, a parked connection state, and a head with no `Content-Length`; the
  request slot goes back to the pool as soon as that head is written, because a 260 KiB slot per
  viewer would turn D28's fixed ceiling into a per-viewer slope (D84)
- a 100 ms feed timer armed **only while someone is subscribed**, so a deployment with no
  dashboard open pays nothing
- frames as change notifications rather than changes, which is what keeps disk off the loop
  entirely (D85)
- subscribers costing **no additional memory**: a parked stream builds frames in the idle read
  buffer it was never going to read into (D86)
- both framings on one path, chosen by `Accept`, with the fallback stateless and immediate (D87)

Verified by 132 transport tests and 21 `curl` checks, including `ops/sseprobe.py` — the artifact
D31 named — run against the real endpoint over loopback.

### Pass 2 — the edge

This is the first milestone with something deployable, so it is where the edge gets stood
up and the last open M0 question gets closed:

- Origin TLS with a real Cloudflare Origin CA certificate, `Full (strict)`,
  Authenticated Origin Pulls, firewall restricted to Cloudflare ranges
- The full zone configuration in D31, applied as code rather than console clicks, in `ops/`
- An SSE endpoint behind the real zone streaming from the D44 ring — real events rather than
  synthetic ones, which makes the probe measure the production shape — and
  **`ops/sseprobe.py` run against `doot.run` until it exits zero**

**This half needs infrastructure that does not exist yet**: a domain, a Cloudflare zone, an
Origin CA certificate and a reachable box. The code can be written and tested without them;
the verification cannot, and D31's entire point is that unverified is the failure mode. So
the edge work gates on that infrastructure being real, and everything above it does not.

**The verification run is rescheduled to the end of M5 (D68).** The zone exists and
`doot.run` is live, but no reachable origin does — so the probe was run through a tunnel
against a synthetic origin instead, which answered the buffering question and cannot answer
the production-shape one. What it found:

| stream | result |
|---|---|
| local, no proxy — the control | **PASS.** Clean 250 ms inter-event gaps |
| through the edge at ~160 B/s | headers in 189 ms, then **zero body frames in 90 s** |
| through the edge at ~200 KB/s | **eight events all at +945 ms**, one ~8 KB chunk |

So the edge buffers by byte threshold, not by timer, and at Doot's real event rate the live
view would lag by minutes to hours without the D31 Configuration Rule. A tunnel cannot
exercise `Full (strict)`, Authenticated Origin Pulls or the origin firewall — with a tunnel
none of the three exist — so this is recorded as a partial result rather than the condition
met.

**Exit:** every row of the error table reproducible by a `curl` invocation, held in a
script that runs in CI. Credits and rate limits verified to be exact under concurrent
load, not approximately right. **And the SSE probe passes through Cloudflare** — if it
cannot be made to pass, the live view falls back to long-polling (D31) and that is
decided here, not during M4.

**Status of each, measured rather than assumed:**

| condition | state |
|---|---|
| every error row reproducible by `curl` in CI | **met — all 25 codes.** D65 settled how each of the last five is reached; `invalid_content_type` is the twenty-fifth, added by D64 |
| credits and rate limits exact under concurrent load | **met.** Exact partitions under real concurrency, with the rate limit asserted against a stopped clock so no token can refill mid-burst (D66) |
| SSE probe passes through Cloudflare | **the endpoint is built and passes the probe locally** — `ops/sseprobe.py` judges it streaming at a 269 ms mean gap against a 250 ms emit interval. The run *through the zone* is **rescheduled to the end of M5 (D68)**, where the deployed box and the zone both exist. The buffering question itself is no longer open: measured through a real edge, Cloudflare withholds `text/event-stream` and flushes it in ~8 KB batches, so D31's fix is load-bearing rather than precautionary |

The first two are closed by `tools/exactness-check.sh` (28 checks) plus strengthened
assertions in the two existing scripts, and cost more than expected: reaching them turned up
**two defects and a specification gap**.

- **D64.** A `Content-Type` carrying a `NUL` or a `CR` was accepted, stored and charged for,
  and then failed on every read — the entry appeared in its tag listing and no `GET` of it
  could ever succeed. `03-data-model.md` promised the field was echoed into a header while
  constraining nothing about its bytes, and the validation-order table did not mention it at
  all. Now `400 invalid_content_type`, and the order table has the step it was missing.
- **D67.** An idempotent replay re-read its record into the request slot's *tail*, which is
  only big enough while the body is under 3,311 bytes. Above that every replay silently
  re-executed, charged a credit and overwrote the entry — against the published promise that
  replays are free. Measured at ten body sizes before and after.
- **D66's amendment.** The intended way to test the rate limit's refill over the wire was a
  harness handler wrapping the real one. It cannot work: a deferred job is handed the
  *registered* handler's context, so a decorating handler breaks every deferred reply. The
  seam is not composable, and now says so.

One limit is stated rather than papered over: **`internal_error` has no client-reachable
cause.** Every remaining `500` site is a defensive branch on a state a request cannot
produce, and the one exception was D64. It is reproduced against the transport harness's
deliberate fault path, which proves the `500`'s wire shape and deliberately not that any
request can provoke one. A row whose cause is a bug cannot have a script that causes it.

---

## M3 — Accounts · **COMPLETE**

This is where D63's one recorded open question gets answered: **how the first account comes
into being.** Signup does it, and nothing else needs to.

### Pass 1 — decisions · **COMPLETE**

D68–D78 in `07-decisions.md`, with an amendment on D58. Nothing about the control plane is
left for an implementation diff to decide. Two came from measurement rather than reading:

| decision | what it settled |
|---|---|
| **D68** | the Cloudflare SSE verification moves to the end of M5, and M4's gate becomes a transport seam with two implementations instead of a wait. Backed by a measurement: the edge buffers SSE in ~8 KB batches |
| **D69** | `std.http.Client` does work on the pinned toolchain, over `std.Io.Threaded`. D27 rejected that `Io` for the *server*, and the mechanism it rejected is absent on an outbound client — so the architecture's stdlib-only outbound story stands |
| D70 | where each of M3's seven kinds of state lives, and the permanent event numbers 5–12. Sessions resolve *opposite* to credits: a crash may only ever shorten a credential |
| D71 | Argon2id parameters, chosen by the memory budget rather than the timing target, and the rule that password hashing runs on the I/O worker pool and never on the loop |
| D72 | an email address has a delivery form and an anchor form, and normalising the wrong one misdelivers mail |
| D73 | the control plane lives in the service layer behind one `Handler`; surface separation is enforced by the credential check and asserted by tests, not by a module boundary |
| D74 | control-plane rate limiting, including the per-address bucket — and the fact that it depends on an origin firewall that does not exist yet, so a global ceiling carries the surface until it does |
| D75 | enumeration resistance needs equalised *work*, not just equal responses: an unknown address pays a full Argon2id verification against a generated dummy hash |
| D76 | API key plaintext generation, by rejection sampling, and the single moment the plaintext exists |
| **D77** | account deletion cannot delete entries eagerly, because the index holds no names (D11). Deletion makes data permanently inaccessible at once and the bytes go with their expiry — which only works because lifetime is mandatory |
| D78 | M3's five environment variables, all required and none defaulted, and the mail queue thread two of them configure |

### Pass 2 — implementation · **MOSTLY COMPLETE**

Built and covered by unit tests: the control log's eight new event types and the state they
rebuild, Argon2id passwords on the I/O worker pool, credential generation, the two forms of an
email address, `__Host-` cookies, the derived synchroniser token, the unauthenticated rate
limiter, RAM-only OTP and OAuth-state storage, the routing table and plane split, the client
address, the mail queue and its thread, M3's five environment variables, and every handler the
router routes.

Findings are D79–D82, with amendments on D70, D72 and D74. Two of those amendments corrected
rules that could not have worked: D70's session-expiry comparison could never fire, and D74's
peer capture would have cost a syscall per connection for a fallback the production shape never
reaches.

GitHub OAuth is built: the authorize redirect with its `state` binding, and the token exchange
on an I/O worker. `tools/app-check.sh` drives the whole surface with `curl` — 60 checks.

- GitHub OAuth with `state` binding
- Email + password, Argon2id, OTP verification, queued outbound mail via ZeptoMail
- Sessions, opaque tokens, `__Host-` cookie, synchroniser token on state-changing routes
- API key management, 5 per account, immediate revocation
- Trial grant with dual identity anchors
- Password reset, account deletion
- Separate control-plane rate-limit bucket

**Exit — met.** Reproduce with `tools/app-check.sh`.

| condition | state |
|---|---|
| both signup paths reach an issued API key | **met.** Both end in a session and the key comes from `POST /app/keys` (D83) — one shape, because a top-level OAuth redirect cannot carry a credential |
| revocation takes effect on the next request | **met**, asserted with no interval and nothing to expire between the revoke and the next `/v1` call |
| enumeration probes return identical responses | **met**, and the *timing* with it: measured over the wire at **179 ms known against 178 ms unknown** (D75) |

The timing row is the one that needed a harness. An unknown address pays for a full Argon2id
verification against a generated dummy hash, and the first run of the script proved why it has
to be measured from outside: a 5 ms "unknown" turned out to be a `429`, not a fast path.

---

## M4 — Dashboard

The adoption driver. Plain HTML/CSS/JS, `@embedFile`d.

**Gate, restated by D68: the live view is written against a transport seam with two
implementations behind it — SSE and long-polling on the same path — and both are built and
tested locally.** The original gate was the probe passing through the real zone, which has
moved to the end of M5; waiting for it would have put M4 after M5, and dropping it would have
reintroduced exactly the risk D31 named. A seam protects against that risk by making the
choice reversible at configuration time instead of by waiting.

This is no longer a hedge against something unlikely. The edge's *default* behaviour is
measured and it breaks SSE (D68), so the fallback sits on the likely branch until the
Configuration Rule is applied and verified.

- Signup and login
- **First-run screen: the API key beside a paste-ready `curl` command.** This screen is
  the conversion moment and gets disproportionate attention
- Entry explorer: list by tag, read one entry, content-type-aware rendering
- Live view over SSE
- Credit counter with the mail-us-for-credits button
- API key management

**Exit:** a new user goes from landing page to a written entry visible in the live view in
**under 60 seconds**, timed, on a cold browser. This is the product thesis and it is a
pass/fail test.

---

## M5 — Durability and operations

Deliberately before launch, not after. Launching without a proven restore means the
best-effort promise is unbacked.

- R2 uploader: `STORE` once, sealed segments once, snapshots and tails every 5 minutes,
  `CONTROL` every 5 minutes, SigV4
- Expired object cleanup in R2
- **Restore drill: rebuild from R2 alone onto a clean box, verify entry-for-entry.** `STORE`
  comes first — without its index hash key nothing written before the restore is
  addressable (D43)
- `/admin/stats`, structured JSON logs with no bodies, names, keys or codes
- `systemd` unit, boot-time secret validation
- Threshold alerting on index utilisation, disk, backup lag, recovery time

**And M2's last exit condition is closed here (D68): `ops/sseprobe.py` run against
`doot.run` through the real Cloudflare zone until it exits zero.** It lands in M5 because
this is the milestone that produces a deployed, publicly reachable origin — which is the one
thing the probe needs and the one thing M2 could not supply. The D31 zone configuration is
applied as code first, and if the probe still cannot be made to pass, M4's transport seam
switches to long-polling and that is the decision taken rather than discovered.

The Cloudflare-facing half of `05-architecture.md` is verified in the same pass, because a
tunnel could not: `Full (strict)`, Authenticated Origin Pulls, and the firewall restricted to
Cloudflare ranges. D74's per-address rate limit is only trustworthy once those three exist,
so this is where it stops depending on a header an attacker could set.

**Exit:** a full restore from R2 onto a clean machine, entry-for-entry verified, timed and
written down. Recovery point measured against the claim published in `01-product.md`.

**And recovery time re-measured on the deployed filesystem from a cold page cache** (D48).
M1's 332 MiB/s was measured on tmpfs, replaying bytes that were already resident, so it is
an optimistic bound rather than the operational one — and D38 turns that figure into an
operator-facing lever. This is where the honest number gets established.

**Also on the deployed link: whether to cap `SO_SNDBUF`** (D54). A response parked against
a slow reader sits in kernel socket memory — up to 260 KiB per connection, outside both the
65 MB body budget and anything `/admin/stats` can see. Capping bounds it, and disables send
buffer autotuning in exchange; whether that is free or a throughput ceiling depends on the
edge-to-origin bandwidth-delay product, which loopback cannot tell us. Same reason as D48:
the measurement has to happen on the real path.

---

## M6 — Beta launch

- Public docs from `02-api.md`, including the client guidance section
- Landing page with the 30-second `curl` example above the fold
- Beta labelling and the plainly-worded durability statement
- Error reference pages behind the `docs` links in error bodies
- **Collapse `docs/` into a single root `REFERENCE.md` and delete the working set**
  (`docs/README.md`)
- Support inbox and a written manual credit-application procedure

**Exit:** an external user, unaided, signs up and writes an entry. Their first message is
about their use case, not about how to use Doot.

---

## Sequencing rules

1. **M0 completes before M1 begins.** Its whole purpose is preventing rework, which is
   forfeited by running it in parallel. *(Done. Three decisions amended before any
   product code existed, which is exactly the intended outcome.)*
2. **Decisions before code, always.** A question surfacing mid-milestone goes to
   `07-decisions.md` first. No design question is settled inside an implementation diff.
   *(M2 ran this as an explicit, separate pass. It earned its keep: D43 caught a silent,
   unrecoverable data-loss path while it was still a line in an environment variable list
   rather than a deployed configuration.)*
3. **M1's exit conditions are non-negotiable.** Storage bugs found after launch are
   data-loss bugs, and this is the one area where "fix it later" means "lose someone's
   data first". *(Met. And the sweep that checks them was itself validated by mutation
   testing, because a durability test that cannot fail is worse than none — D36.)*
4. **M5 precedes M6.** No public launch without a drilled restore.

## Explicitly not in v1

Everything in the Deferred table of `07-decisions.md`, plus: automated payments, teams,
client SDKs, multi-tag queries, public read links, and any second machine.
