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

**Storage engine built and verified. No HTTP yet.**

M0 retired the risky assumptions before any product code existed. M1 is the storage
engine: records, lifetime-class segments, the index, on-disk tag chains, group commit,
and snapshot-plus-tail recovery — with all five exit conditions measured.

| | measured on one 8-core box |
|---|---|
| recovery | 3M records / 3,147 MiB replayed in **9.5 s** (332 MiB/s), on tmpfs |
| index memory | **29.4 bytes** per live entry |
| crash injection | **39/39** `fsync` boundaries, all recovered |
| 24 h soak | **0 compactions**, 51 segments reclaimed by `unlink` |
| request throughput | **2.9–3.2M req/s** on a single-threaded io_uring loop (M0) |
| idle connections | **0.63–4.14 KB** each (M0) |

Recovery is a warm-page-cache figure and says so: it moves with the filesystem, and the
number the operational lever derives from gets re-measured on the deployed volume in M5
(D48).

111 unit tests plus an exit-condition harness, both run by CI on every push:

```bash
zig build test
zig build verify && ./zig-out/bin/m1 all /dev/shm/doot-m1
```

Nine decisions were corrected or added by actually building the thing — including the
discovery that the crash harness, in its first form, could not detect a missing `fsync`
at all. See [`docs/07-decisions.md`](docs/07-decisions.md) D26–D39.

**M2's decisions are settled and its code is not written.** Twelve more (D40–D51) fix where
control-plane state lives, whether idempotency survives a restart, and one silent data-loss
path in how the index hash key was going to be configured.

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
| [`tools/`](tools/) | the M1 exit-condition harness, its crash subject, and the vocabulary check |
| [`ops/`](ops/) | deployment artifacts. The SSE verification probe today; the Cloudflare zone configuration in M2 |

`spikes/` held the M0 validation code and was deleted at M1 as always intended. The findings
are D26–D31; the code is in git history at `4547b32`.
