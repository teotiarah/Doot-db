# Product

Canonical source for every user-visible constant. Other documents reference this
file rather than restating values.

## User journey

The whole product thesis is that this takes under a minute.

1. Land on `doot.run`.
2. Sign up — GitHub OAuth, or email + password with OTP verification.
3. An API key is issued immediately on first landing in the dashboard, with a
   ready-to-paste `curl` command beside it.
4. Paste, run, see the entry appear live in the dashboard.

Step 4 is the conversion moment. The write and the dashboard update must be visibly
simultaneous, because that is the demonstration that nothing else in this category
offers.

## Tiers

| | Trial | Paid (beta) |
|---|---|---|
| write credits | 10,000, one-time | purchased in blocks |
| credit refresh | **never** | on purchase |
| max entry lifetime | 14 days | 30 days *(not committed — see below)* |
| rate limit (pooled) | 100 ops/min | 500 ops/min, raisable on request |
| max body size | 256 KB | 256 KB |
| tags per entry | 5 | 5 |
| API keys | 5 | 5 |
| dashboard + live explorer | yes | yes |
| reads | free | free |

There is **no free tier.** The 10,000 trial credits exist to answer one question —
does this fit your use case — and then they are gone. This is deliberate: a
perpetual free tier means paying other people's server bills forever in exchange
for adoption metrics that don't convert.

**The 30-day paid maximum is a starting point, not a commitment.** It moves with
observed usage. Nothing in the storage layer may hardcode it; maximum lifetime is a
configuration value (`DOOT_MAX_TTL`) and the storage layout derives from it. See
`04-storage.md`.

## Credits

- A **write** is any successful (2xx) `PUT` or `POST` to `/v1/entries`. One entry
  written, one credit.
- **An overwrite is a write.** It consumes a credit.
- **Everything else is free:** reads, list-by-tag, delete, `/v1/whoami`, `/healthz`,
  and all dashboard activity.
- **Failed writes are not charged.** Validation failures, rate-limit rejections,
  oversized bodies, auth failures — no credit consumed.
- **Idempotent replays are not charged.** A retried write carrying the same
  `Idempotency-Key` replays the original outcome and costs nothing. This is worth
  stating on the pricing page: retry storms from a flaky automation don't cost
  money.
- The trial grant is **per account**, and is bound to both the verified email
  address and the GitHub account ID, so it cannot be reset by issuing new API keys
  or by re-authenticating through the other signup path.

### Deletes are free, and that is intentional

Charging for deletion punishes users for tidying up, which is the behaviour we most
want. Deletes are free and governed only by the rate limit.

## Rate limits

**One pooled bucket per account.** Every data-plane operation — read, write, list,
delete — draws from the same bucket. No per-endpoint limits, no per-operation-type
carve-outs.

Pooling is what makes "reads are free" safe. Reads cost no credits, but they cannot
be issued without bound, so there is no path to consuming unlimited resource for
free. It is a rate story, not a metering story.

| | sustained | burst capacity |
|---|---|---|
| Trial | 100 ops/min | 100 |
| Paid (beta default) | 500 ops/min | 500 |

Implemented as a token bucket: capacity equals the burst number, refilling at
`sustained / 60` tokens per second. A caller may spend the full burst instantly,
then proceeds at the sustained rate.

**The bucket is per account, not per API key.** Five keys share one bucket.
Per-key buckets would let anyone multiply their limit fivefold by creating keys,
which defeats the mechanism. Consequence, accepted: a runaway script on one key can
starve the others. Visible in the dashboard, and the fix is to revoke that key.

**The dashboard has a separate bucket.** Control-plane requests (session-authenticated)
never draw from the data-plane pool. If exploring your data could exhaust the same
bucket your production script depends on, the explorer would be a liability rather
than the feature the product is betting on.

`/healthz` is unauthenticated and never rate limited.

Every data-plane response carries the current bucket state; see `02-api.md`.

## Limits

| limit | value | rationale |
|---|---|---|
| max body size | 256 KB (262,144 bytes) | above this, users treat it as blob storage |
| max name length | 256 bytes | |
| max tags per entry | 5 | enough to find things, too few to build a schema |
| max tag length | 64 bytes | |
| default lifetime | 7 days | applied when the caller omits one |
| min lifetime | 60 seconds | |
| max lifetime | tier-dependent (see Tiers) | |
| list page size | 50 default, 100 maximum | |
| list response content | **metadata only** | one page can never return megabytes |
| API keys per account | 5 | |
| idempotency window | 24 hours | |

Bodies are **opaque bytes**. Doot does not parse, validate or transform them. The
supplied `Content-Type` is stored verbatim and echoed on read, which is what lets
the dashboard render JSON as a tree and text as text without the server ever
interpreting anything.

## Running out of credits

The failure mode to avoid is a user believing they lost their data. So:

- Writes return **`402 Payment Required`** with a body pointing at the credits page.
- **Reads, lists and deletes keep working.** Existing data stays fully accessible
  and continues to expire normally. Only the ability to add new entries stops.
- Every write response carries remaining credits, so the wall is never a surprise.
- Notification emails at **80%** and **100%** consumption.
- The dashboard shows remaining credits prominently, not buried in settings.

## Buying credits during beta

Automated payments are deliberately not in v1. During beta the flow is manual and
that is intentional — early conversations with paying users are worth more than
checkout automation.

The flow must still be one click:

- A **"Mail us for credits"** button in the dashboard, next to the credit counter.
- It opens a `mailto:` with subject and body pre-filled with the account email and
  account ID, so the reply requires no back-and-forth to identify the account.
- The same address appears in the `402` response body.
- Credits are applied manually to the account by an operator.

Rate-limit increases go through the same channel.

## Beta labelling

Doot is labelled beta everywhere it is plausible a user forms an expectation: the
landing page, the dashboard header, and the docs.

The durability statement is published plainly rather than buried in terms:

> Doot runs on a single machine and makes a best-effort durability promise, not a
> guarantee. Data is backed up off-box continuously, with a recovery point of a few
> minutes. Do not use Doot as the only copy of anything you cannot lose.

Honesty here is a differentiator, not a liability. The category is full of implied
guarantees nobody intends to honour.

## Abuse

| vector | mitigation |
|---|---|
| unlimited free reads | pooled rate limit; reads cannot be issued without bound |
| large list responses | metadata-only responses, page capped at 100 |
| blob storage misuse | 256 KB ceiling, rejected before the body is read |
| multiple signups to farm trial credits | grant bound to verified email **and** GitHub account ID |
| key multiplication to widen rate limit | bucket is per account, not per key |
| unbounded storage growth | mandatory enforced lifetime on every entry |
| credential stuffing on the dashboard | Argon2id, OTP verification, control-plane rate limits |

Cloudflare sits in front of the origin and can shed volumetric abuse at the edge
before it reaches the box.
