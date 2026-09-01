# Doot

**Ephemeral data storage over plain HTTP.** For the large class of storage need that sits
below the floor of every real database — a few kilobytes, needed for hours or days,
written by a shell script or an automation node, then irrelevant.

No client library. No query language. No setup.

```bash
curl -X PUT https://doot.run/v1/entries/ci/last-green-sha \
  -H "Authorization: Bearer $DOOT_KEY" \
  -H "X-Doot-Tags: ci,main" \
  -H "X-Doot-TTL: 14d" \
  --data-binary @sha.txt
```

```bash
curl https://doot.run/v1/entries/ci/last-green-sha \
  -H "Authorization: Bearer $DOOT_KEY"
```

That is the whole learning curve.

## What makes it different

Doot is a specific bundle of four choices. The bundle is the product.

- **Lifetime is mandatory.** Every entry expires; the system assigns a lifetime if you
  don't. Nothing accumulates forever.
- **Tags instead of a query language.** Up to five per entry, retrievable by tag. Enough
  to find things, far too little to build a schema on.
- **Reads are free.** Writes are the billable event. Read volume is governed by a rate
  limit, not a meter.
- **A live data explorer.** Watch your data arrive in the browser in real time.

## Built for

Automation platforms (n8n, Make, Zapier) needing one value to persist between runs · CI
pipelines sharing state across jobs · agent scratchpads and trace dumps someone can
actually look at · edge and serverless functions with no disk · webhook intake that gets
processed later and then expires.

Wherever storage is needed and a real database is either overkill or simply the wrong
shape.

## What it deliberately is not

Not a database, not blob storage, not permanent. No query language, no joins, no
transactions, no teams, no SDKs. 256 KB per entry, hard.

Full reasoning in [`docs/00-vision.md`](docs/00-vision.md).

## Status

**Storage engine, data plane and origin binary built and verified. Not yet public.**

M0 retired the risky assumptions before any product code existed. M1 built the storage
engine: records, lifetime-class segments, the index, on-disk tag chains, group commit, and
snapshot-plus-tail recovery — with all five exit conditions measured. M2 has built the data
plane on top of it: HTTP/1.1 on the io_uring ring, an I/O worker pool every storage call
goes through, the append-only control-plane log, and **all seven endpoints, with credits,
the pooled rate limit, idempotency and signed cursors** — all exercised by `curl` rather
than only by a client of our own.

It runs:

```bash
zig build
DOOT_LISTEN_ADDR=127.0.0.1:8080 \
DOOT_DATA_DIR=/var/lib/doot \
DOOT_MAX_INDEX_BYTES=300000000 \
DOOT_HMAC_SECRET="$(openssl rand -hex 32)" \
  ./zig-out/bin/doot
```

Configuration is environment variables only, and the binary refuses to start rather than
starting degraded — a missing variable is named, not defaulted. What is left of M2 is the
edge:

| | state |
|---|---|
| M0 — retire the unknowns | complete, except the Cloudflare half of the SSE question, which needs a live zone |
| M1 — storage engine | complete, five exit conditions measured |
| M2 — data plane | endpoints, credits, rate limit, idempotency: **complete and verified over HTTP** |
| M2 — origin binary | **complete.** `zig build` produces `doot`: configuration from the environment, the maintenance thread, and a graceful shutdown that keeps credit balances exact across a deploy (D63) |
| M2 — SSE and the edge | **outstanding.** The change feed ring is built and published to; nothing consumes it. Origin TLS and the Cloudflare zone gate on infrastructure that does not exist yet |
| M3–M6 | not started |

**Two of M2's three exit conditions are now met**: every row of the error catalogue is
reproduced by a `curl` invocation in CI, and credits and the rate limit are verified *exactly*
under concurrent load rather than within a tolerance. Only the SSE probe through the real
Cloudflare zone is outstanding, and it needs the zone to exist.

Closing them turned up two defects worth naming, both now fixed and both regression-checked:
a `Content-Type` carrying a control byte was stored and charged for and then failed on every
read (D64), and an idempotent replay of any body over 3.3 KB silently re-executed and charged
a credit, against the published promise that replays are free (D67).

**It has no way to create an account yet.** M3 owns signup, so a fresh deployment answers
`401` to everything — deliberately, rather than growing an operator subcommand built to be
replaced (D63).

| | measured on one 8-core box |
|---|---|
| recovery | 3M records / 3,147 MiB replayed in **9.5 s** (332 MiB/s), on tmpfs |
| index memory | **29.4 bytes** per live entry |
| crash injection | **41/41** `fsync` boundaries, all recovered |
| 24 h soak | **0 compactions**, 51 segments reclaimed by `unlink` |
| request throughput | **2.9–3.2M req/s** on a single-threaded io_uring loop (M0) |
| idle connections | **0.63–4.14 KB** each (M0) |

Recovery is a warm-page-cache figure and says so: it moves with the filesystem, and the
number the operational lever derives from gets re-measured on the deployed volume in M5
(D48).

**440 unit tests plus six harnesses, all run by CI on every push:**

```bash
tools/vocab-check.sh                                    # D2 vocabulary rule
zig build test                                          # 440 unit tests
zig build verify && ./zig-out/bin/m1 all /dev/shm/doot-m1  # 5 M1 exit conditions
tools/transport-check.sh                                # 52 curl checks
tools/dataplane-check.sh                                # 158 curl checks
tools/boot-check.sh                                     # 30 checks against the real binary
tools/exactness-check.sh                                # 28 concurrency and capacity checks
```

`m1 all` runs the recovery check at its 300,000-record default, which measures the replay
rate but is a tenth of the five-minute tail the exit condition names. The 3,000,000-record
figure in the table above comes from asking for that scale explicitly:

```bash
./zig-out/bin/m1 recovery /dev/shm/doot-m1 3000000
```

Whether CI should run the full scale belongs with the other exit-condition work, and is
recorded rather than quietly closed.

**Decisions, and what building the thing changed.** Nine were corrected or added by M1 —
including the discovery that the crash harness, in its first form, could not detect a
missing `fsync` at all (D26–D39). M2 settled twelve before writing any data-plane code
(D40–D51), one of which caught a silent, unrecoverable data-loss path while the index hash
key was still a line in an environment-variable list. Building the data plane then forced
twelve more (D52–D63), each settled in its own pass before the code it governs. See
[`docs/07-decisions.md`](docs/07-decisions.md).

Doot runs on a single machine and makes a best-effort durability promise, not a
guarantee. Data is backed up off-box continuously with a recovery point of a few minutes.
Don't use Doot as the only copy of anything you cannot lose.

## Built with

A single statically linked [Zig](https://ziglang.org) binary. One process, one machine.
Plain HTML, CSS and vanilla JavaScript for the dashboard, embedded into the binary at
compile time — no framework, no bundler, no build step, no separate deployment.

## Documentation

`docs/` holds **transient working documents** used during development. They will be
collapsed into a single `REFERENCE.md` at v1-beta and deleted. Start with
[`docs/README.md`](docs/README.md).

| | |
|---|---|
| [`00-vision.md`](docs/00-vision.md) | what Doot is and what it refuses to be |
| [`01-product.md`](docs/01-product.md) | tiers, limits, credits, rate limits |
| [`02-api.md`](docs/02-api.md) | the seven endpoints |
| [`03-data-model.md`](docs/03-data-model.md) | entries, names, tags, lifetime |
| [`04-storage.md`](docs/04-storage.md) | storage engine internals |
| [`05-architecture.md`](docs/05-architecture.md) | process model, network path, TLS |
| [`06-auth.md`](docs/06-auth.md) | accounts, API keys, sessions |
| [`07-decisions.md`](docs/07-decisions.md) | every locked decision and rejected alternative |
| [`08-roadmap.md`](docs/08-roadmap.md) | milestones to first public deploy |

Three directories outside `docs/` are permanent:

| | |
|---|---|
| [`toolchain/`](toolchain/) | pinned Zig version, hash, and the stdlib patch it requires. `toolchain/setup.sh` builds the environment from scratch |
| [`tools/`](tools/) | the M1 exit-condition harness and its crash subject, the transport and data-plane harnesses with the `curl` check scripts that drive them, the origin binary's boot and shutdown checks, and the vocabulary check |
| [`ops/`](ops/) | deployment artifacts. The SSE verification probe today; the Cloudflare zone configuration in M2 |

`spikes/` held the M0 validation code and was deleted at M1 as always intended. The findings
are D26–D31; the code is in git history at `4547b32`.
