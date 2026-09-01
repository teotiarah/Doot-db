# Data model

## The entry

An entry is the only unit of storage. It consists of:

| field | source | notes |
|---|---|---|
| **name** | caller (`PUT`) or server (`POST`) | unique within an account |
| **body** | request body | opaque bytes, ≤ 256 KB |
| **content type** | `Content-Type` header | stored verbatim, never interpreted |
| **tags** | `X-Doot-Tags` header | 0–5, normalised |
| **created at** | server clock | unix seconds |
| **expires at** | `X-Doot-TTL` + server clock | mandatory, always set |
| **account** | derived from API key | isolation boundary |

There is nothing else. No version counter, no revision history, no user-defined
metadata map, no schema. Additions here are the beginning of a database, and Doot is
not one.

## Names

Addressing token. Unique per account.

| rule | value |
|---|---|
| length | 1–256 bytes after percent-decoding |
| allowed | printable ASCII `0x21`–`0x7E` |
| forbidden | control characters, space, non-ASCII |
| case | preserved and significant |
| `/` | **allowed** — enables natural namespacing |
| `.` and `..` as full segments | rejected, to avoid path-traversal ambiguity |
| leading or trailing `/` | rejected |
| consecutive `//` | rejected |

Names are byte strings, compared byte-wise. `Order/42` and `order/42` are different
entries. Non-ASCII is rejected rather than normalised, because Unicode equivalence
would make "is this the same entry" a question with more than one defensible answer.

Names are percent-decoded exactly once before validation, so the length limit and character
rules apply to the decoded bytes. A `%` not followed by two hexadecimal digits is rejected.

Because `/` is a permitted byte and comparison is byte-wise after decoding, **`a%2Fb` and
`a/b` are the same entry.** Treating an escaped slash as distinct would make identity depend
on spelling.

Server-assigned names (`POST`) are **ULIDs** — 26 characters, Crockford base32, a
48-bit millisecond timestamp followed by 80 bits of randomness. Chosen over UUIDv4
because ULIDs sort lexicographically by creation time, so a caller listing dumped
webhooks gets chronological order for free.

The **non-monotonic** form is used: 80 bits straight from the CSPRNG, with no per-millisecond
counter. Sort order is therefore chronological to the millisecond, and two entries created
inside the same millisecond sort arbitrarily against each other. Nothing in the product
observes that ordering — list-by-tag orders by write sequence, not by name — and a monotonic
counter would put shared mutable state on the write path to fix it.

## Tags

The entire grouping mechanism. Deliberately weak.

| rule | value |
|---|---|
| count | 0–5 per entry |
| length | 1–64 bytes each |
| allowed | `a`–`z`, `0`–`9`, `.`, `_`, `-`, `:` |
| normalisation | lowercased on write |
| duplicates | collapsed, not an error |
| ordering | preserved as supplied, after de-duplication |

`:` is permitted because `run:8f21` and `env:prod` are a natural convention, and
allowing it costs nothing while pre-empting a feature request for structured tags.

Tags are lowercased on write, so `X-Doot-Tags: CI,Main` stores `ci,main` and
`?tag=CI` matches. This is the one place normalisation is applied, because tags are
labels a human types, whereas names are identifiers a program constructs.

The header is parsed before any of these rules are checked — split, trimmed, emptied
elements dropped, lowercased, de-duplicated — and the maximum of 5 is enforced **after**
de-duplication, so six copies of one tag is one tag rather than an error. Exact parsing order
in `02-api.md`.

**Tags support exactly one operation: list entries carrying this tag, newest first.**
No intersection, union, negation, prefix match, wildcard, or counting. The retrieval
mechanism is described in `04-storage.md`; the reason single-tag-only is the v1
boundary is in `07-decisions.md`.

## Bodies

- Maximum 256 KB (262,144 bytes), rejected from `Content-Length` before reading.
- Zero-length bodies are valid. An entry with an empty body and a lifetime is a
  perfectly good lock or flag.
- Bytes are stored and returned unmodified. No transcoding, no normalisation, no
  compression at rest, no JSON validation even when `Content-Type` says JSON.
- `Content-Type` is stored as supplied, up to 128 bytes, and echoed on read. The
  server never acts on it. The dashboard uses it purely to choose a renderer.
- **Because it is echoed into a response header, it must be printable US-ASCII**
  (`0x20`–`0x7E`); anything else is `400 invalid_content_type`. This is the one constraint
  on an otherwise verbatim field, and it exists because the alternative is a value that can
  be stored but never read back — a control byte here is refused by the response writer, so
  without this rule a write could succeed and every later read of it fail (D64). A media
  type cannot legitimately contain such a byte, so nothing real is excluded.

Opacity is a contract. The moment Doot parses bodies, it acquires opinions about
their shape, and every one of those opinions becomes a compatibility obligation.

## Lifetime

The defining constraint of the product.

| rule | value |
|---|---|
| always present | every entry has an expiry; there is no unlimited option |
| default when omitted | 7 days |
| minimum | 60 seconds |
| maximum | tier-dependent — `01-product.md` |
| granularity | seconds on input, stored to the second |
| clock | server wall clock, UTC |

**Semantics, stated explicitly because callers will assume otherwise:**

- **Reads do not extend lifetime.** No touch-on-read, no sliding window. Deliberately
  unlike Redis session semantics.
- **Overwrite resets lifetime entirely.** `PUT` computes a fresh expiry from the
  supplied `X-Doot-TTL`, or the 7-day default if omitted. It never inherits the
  previous entry's expiry. Overwriting is the only way to extend an entry's life.
- **Expired is indistinguishable from absent.** Both are `404`. No tombstone is
  observable, no "expired" state is exposed.
- **Expiry is observable in advance** via `X-Doot-Expires-At` on read and in list
  metadata, so a caller can decide to refresh.
- **Expiry is authoritative at the index, not on disk.** An entry is unreadable the
  instant its expiry passes, regardless of when its bytes are physically reclaimed.
  Lazy checks on read plus background reclamation; see `04-storage.md`.
- **Lowering the plan maximum never resurrects or truncates existing entries.**
  Entries already written keep the expiry they were given. The maximum applies at
  write time only. This matters because the paid maximum is explicitly expected to
  move.

## Account isolation

The isolation boundary is the account. "No teams" means no shared ownership; it does
not weaken separation.

- Names are scoped per account. Two accounts may hold the same name with no
  interaction.
- Index lookups are keyed on a hash of `(account_id, name)`, so cross-account
  addressing is not merely forbidden but unrepresentable — there is no way to phrase
  a lookup that reaches another account's data.
- Tag traversal chains are per `(account_id, tag)`.
- Pagination cursors embed the issuing account and are HMAC-signed. A cursor
  presented by a different account is rejected as `invalid_cursor`.
- All five API keys on an account address the same data. Keys are credentials, not
  namespaces.

## Validation summary

Applied in this order, so that the cheapest rejections happen first and an oversized
or malformed request is never allowed to consume resources:

| order | check | failure |
|---|---|---|
| 1 | `Authorization` present and valid | `401` |
| 2 | rate limit token available | `429` |
| 3 | `Content-Length` ≤ 256 KB | `413` |
| 4 | name well-formed | `400 invalid_name` |
| 5 | tags well-formed, ≤ 5 | `400 invalid_tag` / `too_many_tags` |
| 6 | `X-Doot-TTL` parseable and within plan bounds | `400 invalid_ttl` / `ttl_too_long` / `ttl_too_short` |
| 7 | `Content-Type` within 128 bytes and printable ASCII | `400 content_type_too_long` / `invalid_content_type` |
| 8 | idempotency key checked | `409` or replay |
| 9 | write credit available | `402` |
| 10 | origin has capacity | `503` |
| 11 | body read and appended | `200` / `201` |

Credit is deducted at step 9 and refunded if step 11 fails, so a failed write never
costs anything.

The same guarantee holds across a crash, and in one direction only: **a deduction is never
durable unless the write it paid for is also durable.** Balances are authoritative in memory
and checkpointed periodically, so an unclean restart can rewind a balance and grant a few
writes for free, but can never charge for a write that did not land (`07-decisions.md` D41).
