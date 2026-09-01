# API

Base URL: `https://doot.run/v1`

## Design rule: the body is opaque, metadata lives in headers

The single most consequential API decision. All metadata — tags, lifetime,
idempotency — travels in headers. The request body is nothing but the bytes to
store.

This is what makes the product's core promise true:

```bash
curl -X PUT https://doot.run/v1/entries/build/artifact-hash \
  -H "Authorization: Bearer $DOOT_KEY" \
  -H "X-Doot-Tags: build,ci" \
  -H "X-Doot-TTL: 24h" \
  --data-binary @hash.txt
```

No JSON envelope, no `jq`, no base64, no escaping. A JSON envelope would force every
caller to wrap their payload and would force us to decide whether bodies must be
valid JSON. Opaque bodies avoid both, and `Content-Type` passthrough is what lets
the dashboard render intelligently without the server ever parsing anything.

## Surface

Seven endpoints. This is the complete data plane.

| method | path | billed | description |
|---|---|---|---|
| `PUT` | `/v1/entries/{name}` | **1 credit** | write or overwrite at a chosen name |
| `POST` | `/v1/entries` | **1 credit** | write at a server-assigned name |
| `GET` | `/v1/entries/{name}` | free | read one entry |
| `GET` | `/v1/entries?tag=…` | free | list entry metadata by tag |
| `DELETE` | `/v1/entries/{name}` | free | delete one entry |
| `GET` | `/v1/whoami` | free | account state, quota, limits |
| `GET` | `/healthz` | free | liveness, unauthenticated, unmetered |

All six `/v1` endpoints draw from the pooled rate limit. `/healthz` does not.

The dashboard's control plane (`/app/*`) is a separate surface with separate
session-cookie authentication and a separate rate-limit bucket. It is not part of
the public API and is not versioned. See `06-auth.md`.

## Authentication

```
Authorization: Bearer doot_live_<random>
```

Missing, malformed, revoked or unknown keys → `401`. There is no other
authentication mechanism for the data plane: no query-parameter keys (they leak into
logs and browser history), no cookies, no basic auth.

Reads require a key too. Free is not the same as anonymous — attribution is what
makes rate limiting and abuse response possible.

## Names in the path

`{name}` is the remainder of the path after `/v1/entries/`, so it may contain `/`:

```
/v1/entries/tenant/42/session-state   →  name = "tenant/42/session-state"
```

Slashes are permitted precisely so callers can namespace naturally. Names are
percent-decoded once. Rules and character set in `03-data-model.md`.

Decoding happens once, before validation, and the 1–256 byte limit applies to the decoded
bytes. A `%` not followed by two hexadecimal digits is `400 invalid_name`, as is any decoded
byte outside printable ASCII.

One consequence worth knowing: **`%2F` and a literal `/` address the same entry.** Names are
byte strings compared after decoding, and `/` is a permitted byte, so `a%2Fb` and `a/b` are
one entry rather than two. Treating an escaped slash as distinct would make "is this the
same entry" depend on how the caller spelled it.

---

## `PUT /v1/entries/{name}`

Create or overwrite. **Consumes one credit on success.**

**Request headers**

| header | required | notes |
|---|---|---|
| `Authorization` | yes | `Bearer <key>` |
| `Content-Type` | no | stored verbatim, echoed on read; defaults to `application/octet-stream` |
| `X-Doot-Tags` | no | comma-separated, max 5, e.g. `ci,main,run-42` |
| `X-Doot-TTL` | no | lifetime; defaults to 7 days |
| `Idempotency-Key` | no | see Idempotency below |

`X-Doot-TTL` accepts a bare integer meaning seconds, or a suffixed duration:
`90s`, `15m`, `24h`, `14d`. Both `3600` and `1h` are valid and identical. Suffix
forms exist because shell scripts are written by humans.

**Grammar, exactly:** one or more ASCII digits, optionally followed by exactly one
lowercase suffix from `s`, `m`, `h`, `d`. Nothing else is accepted — no compound forms
(`1h30m`), no fractions (`1.5h`), no sign, no internal or surrounding whitespace, no
uppercase. A value too large to represent is a parse failure rather than a wraparound.

Unparseable is `400 invalid_ttl`. Parseable but outside the plan's range is
`400 ttl_too_short` or `400 ttl_too_long`, which keeps "I typed it wrong" distinct from "my
plan won't allow it". `0` and `0s` parse and then fail as `ttl_too_short`.

Compound forms are refused because they are the beginning of a duration language, and each
extension invites the next. Four suffixes cover what a shell script needs.

**`X-Doot-Tags` parsing**, in this order: split on `,`; trim leading and trailing spaces and
tabs from each element; drop empty elements; lowercase; de-duplicate keeping first-occurrence
order; then enforce the maximum of 5 and validate each against the character set in
`03-data-model.md`. An absent or empty header means zero tags, which is valid.

A trailing comma is a shell artefact rather than a caller bug, so `ci,main,` is two tags and
not an error. Note that the count is enforced **after** de-duplication, so
`ci,ci,ci,ci,ci,ci` is one tag, not `too_many_tags`.

**Responses**

- `201 Created` — new entry
- `200 OK` — existing entry replaced
- `400` invalid name, tags, or lifetime
- `401` bad key · `402` no credits · `413` body too large · `429` rate limited
- `409` idempotency conflict · `503` origin at capacity

Body is the [metadata document](#metadata-shape). Response headers include
`X-Doot-Credits-Remaining`.

**Overwrite semantics.** `PUT` replaces the entry *completely* — body, content type,
tags, and lifetime. Omitting `X-Doot-TTL` on an overwrite applies the 7-day default;
it does not preserve the previous lifetime. There is no partial update and there
will not be one.

```bash
curl -X PUT https://doot.run/v1/entries/agent/scratch/step-3 \
  -H "Authorization: Bearer $DOOT_KEY" \
  -H "Content-Type: application/json" \
  -H "X-Doot-Tags: agent,run-8f21,scratch" \
  -H "X-Doot-TTL: 2h" \
  -H "Idempotency-Key: 8f21-step-3" \
  -d '{"observation":"tool returned 404","next":"retry with fallback"}'
```

---

## `POST /v1/entries`

Write at a server-assigned name. **Consumes one credit on success.**

Same headers as `PUT`. Exists for the append case — webhook dumps, trace events,
log lines — where the caller has no natural name and generating a unique one in
bash is miserable.

The assigned name is a **ULID**: 26 characters, Crockford base32, lexicographically
sortable by creation time. Returned in the response body and in the `Location`
header.

- `201 Created`, `Location: /v1/entries/01JBQ2K9XW4V7N8M3PZR6TYAC5`

Body is the [metadata document](#metadata-shape), carrying the assigned name. Always
`201`: a server-assigned name cannot collide with an existing entry, so there is no
overwrite case and no `200`.

```bash
curl -X POST https://doot.run/v1/entries \
  -H "Authorization: Bearer $DOOT_KEY" \
  -H "Content-Type: application/json" \
  -H "X-Doot-Tags: webhook,stripe,unprocessed" \
  -H "X-Doot-TTL: 3d" \
  --data-binary @payload.json
```

---

## Metadata shape

One entry, described. Returned as the body of a write, and once per entry in a listing.

```json
{
  "name": "ci/last-green-sha",
  "tags": ["ci", "main"],
  "content_type": "text/plain",
  "size": 13,
  "created_at": "2026-08-30T20:41:07Z",
  "expires_at": "2026-09-06T20:41:07Z"
}
```

| field | notes |
|---|---|
| `name` | the canonical name — percent-decoded, exactly as it is stored |
| `tags` | normalised: lowercased, de-duplicated, in the order supplied. `[]` when there are none |
| `content_type` | as supplied on write, verbatim. `application/octet-stream` when omitted |
| `size` | body length in bytes |
| `created_at` | RFC 3339, seconds precision, always `Z`. On an overwrite this is the **new** write's time, because `PUT` replaces the entry completely |
| `expires_at` | RFC 3339. Always present; every entry has a lifetime |

Timestamps are to the second because lifetimes are stored to the second
(`03-data-model.md`). There is no `seq` field: sequence numbers are an internal ordering
detail and appear only in `GET /healthz` (`07-decisions.md` D60).

## `GET /v1/entries/{name}`

Read one entry. Free.

**Returns the stored bytes as the response body**, not a JSON wrapper. Metadata comes
back in headers so the body remains byte-identical to what was written — which is
what makes `curl ... -o file` and shell pipelines work.

**Response headers**

| header | example |
|---|---|
| `Content-Type` | `application/json` — exactly as supplied on write |
| `Content-Length` | `184` |
| `X-Doot-Tags` | `agent,run-8f21,scratch` |
| `X-Doot-Created-At` | `2026-08-30T20:41:07Z` |
| `X-Doot-Expires-At` | `2026-08-30T22:41:07Z` |
| `X-Doot-Name` | the canonical name |

- `200 OK` · `401` · `404` not found or expired · `429`

**Expired entries are indistinguishable from absent ones.** Both are `404`. Reading
does **not** extend lifetime — there is no touch-on-read. Overwriting is the only way
to extend an entry's life.

---

## `GET /v1/entries?tag={tag}`

List entry metadata for a tag, newest first. Free.

**Query parameters**

| param | default | notes |
|---|---|---|
| `tag` | required | exactly one tag per request |
| `limit` | 50 | maximum 100 |
| `cursor` | — | opaque, from a previous response |

**Metadata only. Bodies are never returned by this endpoint.** That bound is what
makes a free, rate-limited list operation safe: one call can never return megabytes.
To read bodies, follow up with `GET /v1/entries/{name}`.

Each element of `entries` is the [metadata document](#metadata-shape) — the same shape a
write returns, so an entry is described identically wherever it appears.

Exactly one tag per request in v1. Multi-tag intersection is deliberately deferred —
see `07-decisions.md`.

```json
{
  "entries": [
    {
      "name": "agent/scratch/step-3",
      "tags": ["agent", "run-8f21", "scratch"],
      "content_type": "application/json",
      "size": 184,
      "created_at": "2026-08-30T20:41:07Z",
      "expires_at": "2026-08-30T22:41:07Z"
    }
  ],
  "cursor": "eyJ2IjoxLCJhIjo0MiwicyI6..."
}
```

`cursor` is absent when the result set is exhausted. Cursors are opaque,
HMAC-signed, bound to the issuing account, and valid for 1 hour. Do not construct
or parse them.

A page may occasionally contain fewer than `limit` entries while still returning a
cursor — a consequence of how tag traversal skips superseded entries
(`04-storage.md`). **Clients must paginate until `cursor` is absent, not until a
short page appears.** This is stated in the published docs.

---

## `DELETE /v1/entries/{name}`

Delete one entry. Free.

- `204 No Content` · `404` if absent or already expired · `401` · `429`

Deletion is free because charging for cleanup punishes the behaviour we want.

---

## `GET /v1/whoami`

Account state. Free. Intended for scripts and CI to check standing before a run,
and for humans to sanity-check a key.

```json
{
  "account_id": "acct_0000001",
  "email": "someone@example.com",
  "plan": "trial",
  "credits": { "remaining": 9187, "granted": 10000 },
  "rate_limit": { "limit": 100, "window": "1m", "remaining": 96 },
  "limits": {
    "max_body_bytes": 262144,
    "max_tags": 5,
    "max_name_bytes": 256,
    "default_ttl_seconds": 604800,
    "max_ttl_seconds": 1209600
  },
  "key": { "id": "key_0000003", "created_at": "2026-08-30T19:02:44Z" }
}
```

---

## `GET /healthz`

Unauthenticated, unmetered, never rate limited. `200 OK` with
`{"status":"ok","seq":<current sequence>}` when the write path is accepting
traffic; `503` when it is not.

---

## Idempotency

Named as a core primitive from the outset, because retries are unavoidable in the
environments Doot targets — CI runners, webhook senders, automation platforms with
their own retry logic.

- Supply `Idempotency-Key` on `PUT` or `POST`. Any string, 1–255 bytes. A UUID or
  ULID is the obvious choice.
- Scope is **per account**, window is **24 hours**.
- First request executes normally; outcome (status and metadata) is recorded against
  the key.
- A repeat within the window with the **same key and same body** replays the
  recorded outcome, adds `Idempotency-Replayed: true`, and **consumes no credit**.
- A repeat with the **same key and a different body** returns
  `409 Conflict`, code `idempotency_key_reused`. It does not overwrite anything.
- A request still in flight for the same key returns `409`, code
  `idempotency_in_progress`. Retry after a moment.
- Keys are stored as a hash of `(account_id, key)` alongside a hash of the body.
  The body itself is not retained for comparison.

Replays being free is a deliberate product decision, not an implementation detail:
a misconfigured automation retrying in a loop should not generate a bill.

**Idempotency state does not survive a restart of the service, and the window can shorten
under extreme volume.** Both are stated here rather than left to be discovered, because a
published 24-hour guarantee with quiet exceptions is worse than a smaller honest one.

- A retry arriving after a restart re-executes. For `PUT` the result is identical — same
  name, same bytes — and it consumes a credit. For `POST` it creates a second entry under a
  new name.
- The table holds up to 1,000,000 records. Past that, the records closest to expiry are
  dropped first, which shortens the effective window.
- A full table never causes a write to fail. Losing a record degrades to re-execution,
  which is exactly what omitting the header does.

Restarts are brief and infrequent — a connection reset plus under ten seconds of recovery —
so the exposed window is narrow. Reasoning in `07-decisions.md` D42.

## Headers on every response

`Date`, as an IMF-fixdate. RFC 9110 requires it of an origin server with a clock, and it
is documented here rather than in the per-endpoint tables above because it is not part of
Doot's surface — nothing in the product reads it or depends on it. It belongs to HTTP.

The one exception is the `503 capacity_exhausted` returned when the origin is shedding
load, which is served from a pre-rendered constant and carries no `Date`. That response
exists for the moment when nothing can be allocated to build one, which is exactly when a
formatted timestamp is unavailable (`07-decisions.md` D55).

## Rate limit headers

On every `/v1` response:

```
RateLimit-Limit: 100
RateLimit-Remaining: 96
RateLimit-Reset: 34
```

`RateLimit-Reset` is seconds until the bucket is full again. On `429`, `Retry-After`
is also present in seconds.

Credits appear on write responses only, since reads don't affect them:

```
X-Doot-Credits-Remaining: 9187
```

## Errors

Uniform JSON body on every non-2xx response:

```json
{
  "error": {
    "code": "ttl_too_long",
    "message": "X-Doot-TTL of 30d exceeds the 14d maximum for the trial plan.",
    "docs": "https://doot.run/docs/errors#ttl_too_long"
  }
}
```

`code` is a stable machine-readable identifier and never changes once published.
`message` is human-facing and may be reworded.

| status | code | meaning |
|---|---|---|
| 400 | `invalid_name` | name empty, too long, or has forbidden characters |
| 400 | `invalid_tag` | tag too long or has forbidden characters |
| 400 | `too_many_tags` | more than 5 |
| 400 | `invalid_ttl` | unparseable `X-Doot-TTL` |
| 400 | `ttl_too_long` | exceeds the plan maximum |
| 400 | `ttl_too_short` | below 60 seconds |
| 400 | `invalid_cursor` | malformed, expired, or issued to another account |
| 400 | `content_type_too_long` | `Content-Type` over 128 bytes |
| 400 | `invalid_request` | malformed request line or headers |
| 400 | `invalid_limit` | outside 1–100 |
| 400 | `missing_tag` | list called without `tag` |
| 401 | `missing_credentials` | no `Authorization` header |
| 401 | `invalid_credentials` | unknown or revoked key |
| 402 | `credits_exhausted` | write credits spent |
| 404 | `not_found` | absent or expired |
| 409 | `idempotency_key_reused` | same key, different body |
| 409 | `idempotency_in_progress` | concurrent request, same key |
| 405 | `method_not_allowed` | known path, unsupported method. Carries an `Allow` header |
| 411 | `length_required` | a write without `Content-Length` |
| 413 | `body_too_large` | over 256 KB |
| 429 | `rate_limited` | bucket empty |
| 431 | `headers_too_large` | request line and headers exceed 8 KB in total |
| 500 | `internal_error` | an unexpected server-side failure. Carries no detail, by design |
| 503 | `capacity_exhausted` | origin cannot accept new entries |

Two notes on codes that exist but are easy to mis-expect:

- **An unrouted path is `404 not_found`**, the same code a missing entry gets. A
  distinct code would tell an unauthenticated prober which paths exist, for no
  benefit. In practice the two never collide, because authentication happens first
  (`03-data-model.md`): an unknown `/v1` path with a bad key is `401` and never
  reaches routing.
- **`400 invalid_request`** covers a malformed request line or header block, as
  distinct from a validation failure on a field that was parsed successfully.

`413` is returned from `Content-Length` **before the body is read**. Oversized
uploads are rejected, not drained.

## Client behaviour worth documenting publicly

- **Reuse connections.** Connection setup dominates request latency (see
  `05-architecture.md`). `curl` reuses within one invocation; long-lived clients
  should keep connections alive.
- **Retry `429` and `503`** with backoff, honouring `Retry-After`.
- **Do not retry `4xx`** other than `429`. They are deterministic.
- **Use `Idempotency-Key` on anything automated.** It is free, it prevents duplicate
  writes, and replays are not billed.
- **Paginate until `cursor` is absent.**
