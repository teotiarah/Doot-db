# Vision

## The problem

There is a large class of storage need that sits below the floor of every real
database. A few kilobytes. Needed for hours or days. Written by a shell script, a
CI job, an automation node, or an edge function. Read a handful of times. Then
irrelevant.

Nobody was ever going to run Postgres for this. So today it gets solved with:

- a file on a box, until the box is replaced
- a Gist, a Google Sheet, a pastebin
- a Redis instance costing more in attention than the problem was worth
- a hosted database whose minimum monthly cost exceeds the value of the data
- an S3 bucket plus twenty lines of signing code

Each of these is a workaround. The gap is real and it is not addressed by making
databases smaller, because the obstacle was never storage capacity — it was
**setup cost, protocol cost, and ongoing cost**.

## What Doot is

A REST-native store for small, short-lived data. One HTTP call to write, one to
read, nothing to install, nothing to configure, no client library.

```bash
curl -X PUT https://doot.run/v1/entries/ci/last-green-sha \
  -H "Authorization: Bearer $DOOT_KEY" \
  -H "X-Doot-Tags: ci,main" \
  -H "X-Doot-TTL: 14d" \
  --data-binary @sha.txt
```

That is the entire onboarding surface. If a user cannot get from signup to a
successful write in under a minute, the product has failed at its only real job.

## The wedge

Doot is not "the simplest database". That framing invites feature requests it has
no principled way to refuse — first a filter, then a sort, then a join. Doot is a
specific **bundle of four choices**, and the bundle is the product:

1. **Lifetime is mandatory and enforced.** Every entry expires. The system assigns
   a lifetime if the caller doesn't. Nothing accumulates forever. This is what keeps
   a single machine viable and what makes the cost model honest.
2. **Tags instead of a query language.** Up to five per entry, retrievable by tag.
   Enough structure to find things, far too little to build a schema on. Deliberate.
3. **Reads are free.** Writes are the billable event. Read volume is governed by a
   rate limit, not a meter, so nobody has to think about the cost of looking at
   their own data.
4. **A live data explorer.** Users watch their data arrive in a browser in real
   time. This is the adoption driver, and the reason a non-technical operator can
   use Doot at all.

No existing product has all four. Each part is individually unremarkable; together
they describe a tool that doesn't exist yet.

## Prior art, honestly

Directional only — pricing and features move, re-verify before publishing any
comparison.

| | protocol | lifetime | grouping | reads | exploration |
|---|---|---|---|---|---|
| Upstash Redis REST | REST wrapping Redis commands | yes, opt-in | none (SCAN) | metered | minimal console |
| Cloudflare KV | Workers-first, REST secondary | yes, opt-in | none | metered past free tier | basic |
| kvdb.io and similar | REST | yes | none | loose | minimal |
| jsonbin / npoint | REST, JSON-only | no | collections | free tier | basic viewer |
| Postgres / Mongo / Redis | wire protocol + query language | manual | full query language | n/a | external tooling |
| **Doot** | REST, metadata in headers | **mandatory, enforced** | tags (≤5) | free, pooled rate limit | **live explorer** |

The nearest neighbours are Upstash and Cloudflare KV. Both are good products that
require you to adopt a mental model first. Doot requires you to adopt `curl`.

## Who it's for

- **Automation users** (n8n, Make, Zapier, Windmill) who need one value to persist
  between runs and have no good place to put it.
- **CI/CD pipelines** needing cross-job state — last green SHA, a deploy lock, a
  cached fingerprint.
- **Agent and LLM tooling** needing a scratchpad, a trace sink, or an
  observability dump that somebody can actually look at afterwards.
- **Edge and serverless functions** with no local disk and no connection pooling
  story, where a plain HTTPS call is the only sane persistence.
- **Webhook intake** — dump the payload now, process it later, let it expire.

The common thread: the data matters for a short while, the setup must be trivial,
and the alternative is a hack.

## Non-goals

Explicit, and each one is load-bearing. These are refusals, not backlog items.

- **No query language.** No filters, sorts, ranges, aggregates, joins. Tags and
  direct addressing by name, nothing more.
- **No blob storage.** 256 KB hard ceiling. The moment large payloads are viable,
  economics and latency both break.
- **No permanent storage.** Maximum lifetime is bounded by tier. There is no
  "keep forever" option and there will not be one.
- **No transactions**, no multi-entry atomicity, no compare-and-swap in v1.
- **No teams, orgs, or shared accounts.** One account, one owner. (Per-account
  data isolation is of course mandatory — "no teams" is not "no isolation".)
- **No writes from the dashboard.** It explores and it manages the account. Adding
  editing opens a second, divergent write path with its own validation, audit and
  billing surface. Read-only is a boundary, not a shortcut.
- **No SLA and no durability guarantee.** Best effort, stated plainly, backed by
  off-box backups rather than by promises.
- **No client SDKs.** If the API needs an SDK, the API is wrong.
- **No HTTP/2 or HTTP/3 at the origin.** The edge provides both. See
  `05-architecture.md`.

## Vocabulary — enforced

The product is not a key-value store, so the words are not available. This is
enforced in code identifiers, endpoints, error messages, log lines, docs and UI
copy.

| use | never |
|---|---|
| **entry** — the unit of storage | record, object, document, item, blob, pair |
| **name** — how an entry is addressed | key, id, path, slug |
| **body** — the bytes stored | value, payload, content, data |
| **tags** — grouping labels | index, labels, categories, collection |
| **lifetime** / **expiry** | TTL in prose (`X-Doot-TTL` is fine as a wire name) |

Naming discipline here is not cosmetic. The first time a document says "key-value
store", every argument in the Non-goals section above loses its footing.
