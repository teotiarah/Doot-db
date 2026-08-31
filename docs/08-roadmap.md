# Roadmap to first public deploy

Ordered by **risk retired per unit of work**, not by how the product reads on a page.
The unknowns that could invalidate the design come first; the parts that are merely
laborious come last.

Each milestone has an exit condition that is a demonstrable fact, not a feeling.

---

## M0 — Retire the unknowns · **COMPLETE**

Throwaway spikes in `spikes/`; see `spikes/README.md` to reproduce. Findings are D26–D31
in `07-decisions.md`, with amendments on D3, D13, D14 and D18.

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
that answers it (`spikes/sse/sseprobe.py`) is written and must be run against
`doot.run` before M4 builds the dashboard on the assumption it streams.

---

## M1 — Storage engine, standalone · **COMPLETE**

No HTTP. A library plus a test harness, because this is the part that is expensive to get
wrong and impossible to fix casually later.

Implemented in `src/storage/`; harness in `tools/`. Findings are D32–D39 in
`07-decisions.md`, four of which corrected the specification.

- Record format, CRC32C verification, packed locations
- Four lifetime-class append streams, 64 MiB segments, sealing
- Sharded index (20-byte slots, keyed hash, name verification on read)
- Tag chains: per-tag back-pointers, in-RAM heads, bounded validated traversal
- Group commit with `fsync`, global `seq`
- Shard-at-a-time snapshots; recovery from snapshot + tail replay
- Wholesale segment reclamation on expiry; class-0 tombstones
- Capacity ceiling and admission control

**Exit conditions — all met.** Reproduce with `zig build verify && ./zig-out/bin/m1 all`.

| condition | target | measured |
|---|---|---|
| crash at every `fsync` boundary loses nothing acknowledged, resurrects nothing | all boundaries | **39/39 boundaries**, all killed mid-run, all recovered |
| recovery with 5 minutes of tail at 10k writes/s | < 10 s | **9.5 s** for 3,000,000 records / 3,147 MiB (332 MiB/s) |
| index RAM per live entry | 28.57 B ± 10% | **29.40 B** at 972k entries, occupancy 0.680 |
| compaction events in a 24 h mixed-lifetime soak | 0 | **0**, and 0 segments even met the trigger; 51 reclaimed by unlink |
| tag traversal across overwrite, delete, expiry, class change | correct | **3 live of 9 hops**; stale, deleted and expired all excluded |

111 unit tests alongside the harness.

**What the crash sweep does and does not prove.** It proves recovery is correct at every
flush boundary — torn tails, half-written snapshots, rotation in flight. It cannot prove
`fsync` was called, because `SIGKILL` kills a process while dirty page cache survives it.
That gap was found by mutation testing and closed with white-box durability assertions at
the moment of acknowledgement; true power-loss testing needs a block layer that discards
un-flushed writes. Full reasoning in D36.

**Recovery margin is 5%**, which makes the relationship more useful than the number:
recovery time is bounded by the snapshot interval, not by how much data is stored. See
D38 for the formula and the operational lever.

Four bugs worth noting, all found by tests rather than by review, and all of the kind
that only appear on a second run: a directory iterator that left its file descriptor at
EOF so the *second* startup discovered no segments and silently recovered an empty store;
a stream holding a slice into a freed list; a self-referential pointer invalidated by a
struct copy; and `record.decode` leaving a tag slice aimed at the caller's stack frame.

---

## M2 — Data plane

The seven endpoints. Product-visible for the first time, on top of the M1 engine.

- HTTP/1.1 with keep-alive, `TCP_NODELAY`, single-`writev` responses,
  `Expect: 100-continue`, early `413`, bounded header sizes
- Router, API key authentication, per-account pooled token bucket
- All seven endpoints per `02-api.md`
- Validation in the order given in `03-data-model.md`
- Idempotency: 24-hour window, free replays, `409` on conflict
- Credit accounting: deduct, refund on failure, `402` on exhaustion
- Error catalogue with stable codes; HMAC-signed pagination cursors

Also, because this is the first milestone with something deployable, it is where the
edge gets stood up and the last open M0 question gets closed:

- Origin TLS with a real Cloudflare Origin CA certificate, `Full (strict)`,
  Authenticated Origin Pulls, firewall restricted to Cloudflare ranges
- The full zone configuration in D31, applied as code rather than console clicks
- A throwaway SSE endpoint behind the real zone, and
  **`spikes/sse/sseprobe.py` run against `doot.run` until it exits zero**

**Exit:** every row of the error table reproducible by a `curl` invocation, held in a
script that runs in CI. Credits and rate limits verified to be exact under concurrent
load, not approximately right. **And the SSE probe passes through Cloudflare** — if it
cannot be made to pass, the live view falls back to long-polling (D31) and that is
decided here, not during M4.

---

## M3 — Accounts

- GitHub OAuth with `state` binding
- Email + password, Argon2id, OTP verification, queued outbound mail via ZeptoMail
- Sessions, opaque tokens, `__Host-` cookie, synchroniser token on state-changing routes
- API key management, 5 per account, immediate revocation
- Trial grant with dual identity anchors
- Password reset, account deletion
- Separate control-plane rate-limit bucket

**Exit:** both signup paths reach an issued API key. Revocation takes effect on the next
request. Enumeration probes on signup, login and reset return identical responses.

---

## M4 — Dashboard

The adoption driver. Plain HTML/CSS/JS, `@embedFile`d.

**Gate: the SSE probe must already pass through the real Cloudflare zone (M2, D31).**
Building the live view before that is confirmed risks discovering at the end of the
most user-visible milestone that the transport does not work.

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

- R2 uploader: sealed segments once, snapshots and tails every 5 minutes, SigV4
- Expired object cleanup in R2
- **Restore drill: rebuild from R2 alone onto a clean box, verify entry-for-entry**
- `/admin/stats`, structured JSON logs with no bodies, names, keys or codes
- `systemd` unit, boot-time secret validation
- Threshold alerting on index utilisation, disk, backup lag, recovery time

**Exit:** a full restore from R2 onto a clean machine, entry-for-entry verified, timed and
written down. Recovery point measured against the claim published in `01-product.md`.

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
3. **M1's exit conditions are non-negotiable.** Storage bugs found after launch are
   data-loss bugs, and this is the one area where "fix it later" means "lose someone's
   data first". *(Met. And the sweep that checks them was itself validated by mutation
   testing, because a durability test that cannot fail is worse than none — D36.)*
4. **M5 precedes M6.** No public launch without a drilled restore.

## Explicitly not in v1

Everything in the Deferred table of `07-decisions.md`, plus: automated payments, teams,
client SDKs, multi-tag queries, public read links, and any second machine.
