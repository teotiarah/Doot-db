# Roadmap to first public deploy

Ordered by **risk retired per unit of work**, not by how the product reads on a page.
The unknowns that could invalidate the design come first; the parts that are merely
laborious come last.

Each milestone has an exit condition that is a demonstrable fact, not a feeling.

---

## M0 — Retire the unknowns

Throwaway spikes. None of this code survives into the product; the point is to find out
whether three assumptions hold before anything is built on them.

| spike | question | why it is first |
|---|---|---|
| SSE through Cloudflare | does the edge stream `text/event-stream` from the origin without buffering, and hold the connection open? | the live explorer is the adoption driver (`00-vision.md`). If the edge buffers, the dashboard design changes — better to know now than in launch week |
| Origin TLS | does vendored `tls.zig` complete a TLS 1.3 handshake with a Cloudflare Origin CA cert, under `Full (strict)` with Authenticated Origin Pulls? | D13's whole resolution rests on this. Failure means reopening the topology decision |
| io_uring throughput and idle cost | requests/sec on a trivial handler, and RSS at 10k idle keep-alive connections | D14 asserts idle connections are cheap. Measure it before the concurrency model is load-bearing |

**Exit:** all three answered with numbers written into `07-decisions.md`. Any failure
reopens the relevant decision *before* implementation, per the two-pass rule.

---

## M1 — Storage engine, standalone

No HTTP. A library plus a test harness, because this is the part that is expensive to get
wrong and impossible to fix casually later.

- Record format, CRC32C verification, packed locations
- Four lifetime-class append streams, 64 MiB segments, sealing
- Sharded index (20-byte slots, keyed hash, name verification on read)
- Tag chains: per-tag back-pointers, in-RAM heads, bounded validated traversal
- Group commit with `fsync`, global `seq`
- Shard-at-a-time snapshots; recovery from snapshot + tail replay
- Wholesale segment reclamation on expiry; class-0 tombstones
- Capacity ceiling and admission control

**Exit conditions, all measured:**

- Crash injection at every `fsync` boundary — recovery loses nothing acknowledged and
  never resurrects a deleted or expired entry
- Recovery under 10 seconds with 5 minutes of tail at 10k writes/s
- Index RAM within 10% of 29 bytes/entry at 10M entries
- Zero compaction events in a 24-hour mixed-lifetime soak
- Tag traversal correct across overwrite, delete, expiry and class migration

---

## M2 — Data plane

The seven endpoints. Product-visible for the first time.

- HTTP/1.1 with keep-alive, `TCP_NODELAY`, single-`writev` responses,
  `Expect: 100-continue`, early `413`, bounded header sizes
- Router, API key authentication, per-account pooled token bucket
- All seven endpoints per `02-api.md`
- Validation in the order given in `03-data-model.md`
- Idempotency: 24-hour window, free replays, `409` on conflict
- Credit accounting: deduct, refund on failure, `402` on exhaustion
- Error catalogue with stable codes; HMAC-signed pagination cursors

**Exit:** every row of the error table reproducible by a `curl` invocation, held in a
script that runs in CI. Credits and rate limits verified to be exact under concurrent
load, not approximately right.

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
   forfeited by running it in parallel.
2. **Decisions before code, always.** A question surfacing mid-milestone goes to
   `07-decisions.md` first. No design question is settled inside an implementation diff.
3. **M1's exit conditions are non-negotiable.** Storage bugs found after launch are
   data-loss bugs, and this is the one area where "fix it later" means "lose someone's
   data first".
4. **M5 precedes M6.** No public launch without a drilled restore.

## Explicitly not in v1

Everything in the Deferred table of `07-decisions.md`, plus: automated payments, teams,
client SDKs, multi-tag queries, public read links, and any second machine.
