# Accounts, keys and sessions

## Two planes, two credentials

| | data plane | control plane |
|---|---|---|
| paths | `/v1/*` | `/app/*` |
| credential | API key, `Authorization: Bearer` | session cookie |
| audience | scripts, CI, automation, edge | browser |
| rate limit bucket | pooled per account (`01-product.md`) | **separate** per account |
| versioned | yes | no |
| public API | yes | no |

Strictly separate. An API key can never authenticate a dashboard request, and a session
cookie can never authenticate a data-plane request. This removes CSRF as a concern for
`/v1` entirely (bearer tokens are not sent automatically by browsers) and means a
stolen session cannot be used to script bulk data access.

Separate rate-limit buckets are a product requirement, not a technical nicety: if
browsing the dashboard drained the same bucket a production script depends on, the
explorer would be a liability rather than the feature driving adoption.

## Signup

Two paths, one account model. Both land in the same place: a dashboard with an API key
already issued and a paste-ready `curl` command.

### GitHub OAuth

Standard authorization code flow.

1. `GET /app/auth/github` → redirect to GitHub with a `state` value bound to a
   short-lived, `HttpOnly` pre-session cookie.
2. GitHub redirects back to `/app/auth/github/callback` with `code` and `state`.
3. `state` is verified against the cookie and consumed. Mismatch or absence aborts.
4. Server-side token exchange (outbound HTTPS, `std.http.Client`).
5. Fetch the GitHub numeric user id and primary **verified** email.
6. Match on GitHub user id first, then verified email, else create the account.

Scope requested is `read:user user:email` and nothing more. Doot never needs repository
access and asking for it would cost signups.

**The GitHub numeric user id is the identity anchor**, not the username — usernames can
be changed and reused. An unverified GitHub email is never accepted as an identity match.

### Email + password

1. `POST /app/auth/signup` with email and password. Password requirements: minimum 10
   characters, no composition rules. Length beats character-class theatre.
2. Account created in `pending_verification`. **No API key is issued and no trial
   credits are granted yet.**
3. A 6-digit OTP is emailed via ZeptoMail (queued; the request does not block on
   delivery).
4. `POST /app/auth/verify` with the code. On success the account activates, credits are
   granted, and the first API key is issued.

**OTP rules**

| rule | value |
|---|---|
| length | 6 digits, cryptographically random |
| lifetime | 10 minutes |
| attempts | 5, then the code is invalidated |
| resend | max 3 per hour per email address |
| storage | hash only, never plaintext |
| comparison | constant-time |
| on success | consumed immediately, single use |

Unverified accounts are deleted after 7 days.

**Password storage:** Argon2id via `std.crypto.pwhash.argon2`, per-password random salt,
parameters recorded alongside each hash in PHC string form so they can be raised later
without invalidating existing passwords.

Parameters are `m = 19456` KiB, `t = 2`, `p = 1`, 16-byte salt, 32-byte tag — RFC 9106's
second recommended option (D71). The choice is made by the **memory budget**, not the timing
target: the first recommended option asks for 2 GiB per verification, and eight I/O workers
verifying at once would want 16 GiB on a box whose memory is accounted for to the megabyte in
`04-storage.md`. At 19 MiB the same eight peak at 152 MiB, which fits beside the index and the
transport reservation.

**Hashing and verification run on the I/O worker pool, never on the event loop** (D57, D71).
A deliberately slow hash is a deliberate stall, and login is where an attacker gets to choose
how often it happens.

The ~100 ms target is a property of the deployed CPU and gets measured in M5, alongside the
other figures that only mean something on real hardware (D48). If the parameters land far
from it, the parameters move rather than the promise.

### Linking

An email-signup account whose address matches a verified GitHub email may later
authenticate via GitHub, and the identities link. **This does not grant a second trial
allocation** — see below.

## Trial credit anti-farming

The 10,000 credit grant is one-time and there is no recurring free tier, so a second
grant is the thing worth attacking.

The grant is recorded against **both** identity anchors:

- normalised verified email address (lowercased, plus-addressing stripped for
  matching, `@gmail.com` and `@googlemail.com` dot-normalised)
- GitHub numeric user id, when present

**An address has two forms and they are never interchanged** (D72). The **delivery
address** is exactly what the user typed, byte for byte, and it is what every outbound mail
goes to and what the dashboard and `whoami` display. The **anchor** is the normalised form
above, and it exists for one operation — equality against previous claims — so only its
`SHA-256` is ever stored. Normalising the stored address instead would send mail to an
address the user did not choose, and the local part of an address is case-sensitive under
RFC 5321, so lowercasing it is not even reliably deliverable.

Dot-normalisation applies to those two domains only. At most providers `a.b@` and `ab@` are
different people.

A new account matching either anchor activates with **zero credits**. Reasons are
logged for support to reverse a false positive by hand.

Not attempting anything heavier — no device fingerprinting, no phone verification, no
credit card on signup. Each of those costs real conversions on a product whose entire
pitch is under-a-minute onboarding, and the downside of some leakage is a few thousand
writes.

## API keys

**Format**

```
doot_live_<32 chars, base62>
```

~190 bits of entropy — 32 × log₂(62) is 190.5. The `doot_live_` prefix makes keys greppable
in leaked code and allows a future `doot_test_` variant without ambiguity; that variant is
reserved and unissued, and the prefix is part of the parse so adding it later changes nothing
about how an existing key is recognised.

Characters are drawn from `A–Z a–z 0–9` by **rejection sampling** over a CSPRNG — draw a
byte, discard it if it is ≥ 248, otherwise take it modulo 62 (D76). The obvious
`byte % 62` makes the first eight letters of the alphabet about 1.6% more likely than the
rest, which is not exploitable at this length and is also free to avoid.

Base62 rather than base64url: `-` and `_` survive a double-click selection differently across
terminals and chat clients, and a credential a human copies by hand should be one
alphanumeric token.

**Storage.** Only `SHA-256(key)` is persisted, indexed for lookup. The plaintext key is
shown **once**, at creation, and cannot be retrieved afterwards — the dashboard says so
before revealing it.

SHA-256 rather than Argon2id is correct here and deliberate: keys are 190 bits of
uniform randomness, so there is no dictionary to attack and no benefit to a slow KDF.
Slow hashing on a credential checked on every single request would be a self-inflicted
performance problem. Passwords are low-entropy and human-chosen, which is why they get
Argon2id; keys are neither.

**Lifecycle**

| rule | value |
|---|---|
| maximum per account | 5 |
| creation | any time, up to the maximum |
| revocation | immediate and irreversible |
| rotation | create the new key, deploy, revoke the old |
| label | optional user-supplied, ≤ 64 chars, e.g. "ci-runner" |
| shown in dashboard | label, `key_<id>` (Crockford base32, D59), first 4 chars after the key prefix, created-at, last-used-at |

`last_used_at` is updated at most once per minute per key, to avoid a write on every
request.

**Keys are credentials, not namespaces.** All five address the same data, share one
rate-limit bucket, and draw on the same credits. Per-key buckets would let anyone
multiply their rate limit fivefold by creating keys.

**Revocation is immediate.** The key-hash table is authoritative and in memory; there
is no cached authorisation to expire. This is the primary self-service remedy for a
leaked key and it must never be eventually-consistent.

## Sessions

Opaque random tokens, not JWTs.

| property | value |
|---|---|
| token | 32 bytes random, base64url |
| storage | `SHA-256(token)` server-side, with account id and expiry |
| cookie | `__Host-doot_session`, `HttpOnly; Secure; SameSite=Lax; Path=/` |
| lifetime | 30 days, sliding — refreshed on use if over 24 h old |
| logout | server-side deletion; immediate |
| password change | all sessions for the account invalidated |

Creation and revocation are written to the control log; **the sliding refresh lives in memory
and is checkpointed**, because logging it would mean a log write per dashboard request (D70).
On recovery a session's expiry is the **earlier** of what the log says and what the last
checkpoint says.

That direction is the opposite of the one credits take, and deliberately so. Credits err in
the customer's favour, so a crash can only under-charge. A session is a credential, so a
crash may only ever **shorten** it. The worst case is someone logging in again; the worst case
in the other direction is a session outliving the revocation meant to end it.

Opaque tokens over JWTs because instant server-side revocation matters more than
avoiding a hash lookup, and because a stateless token that cannot be revoked is a
liability on a service holding other people's data. There is no scaling argument for
JWTs on a single box.

`SameSite=Lax` with the `__Host-` prefix, plus a synchroniser token on state-changing
control-plane requests. `/v1` needs no CSRF defence because bearer authentication is
never automatic.

## Control-plane surface

Not public API, not versioned, may change freely.

| path | purpose |
|---|---|
| `POST /app/auth/signup` | email + password registration |
| `POST /app/auth/verify` | OTP verification |
| `POST /app/auth/login` | email + password login |
| `POST /app/auth/logout` | session teardown |
| `GET /app/auth/github` | OAuth entry |
| `GET /app/auth/github/callback` | OAuth callback |
| `POST /app/auth/password/reset` | request reset OTP |
| `POST /app/auth/password/confirm` | complete reset |
| `GET /app/account` | account state, credits, plan |
| `GET /app/keys` · `POST /app/keys` · `DELETE /app/keys/{id}` | key management |
| `GET /app/entries` · `GET /app/entries/{name}` | read-only explorer |
| `GET /app/stream` | SSE live feed |

**The explorer is strictly read-only.** No create, no edit, no delete. This is a product
boundary (`00-vision.md`): a second write path would need its own validation, billing,
idempotency and audit story, and would diverge from `/v1` over time.

Accepted consequence: a user who writes a secret into an entry by accident must delete
it via the API, or ask support. The alternative is a permanent second write path, which
is a worse trade.

## Brute force and enumeration

| surface | defence |
|---|---|
| password login | per-account and per-IP backoff; escalating delay, no lockout |
| OTP verification | 5 attempts per code, 3 resends per hour per address |
| password reset | always responds identically whether or not the address exists |
| signup | identical response for an existing address; no enumeration oracle |
| API key auth | constant-time comparison on the stored hash |
| control plane overall | separate rate-limit buckets, tighter than the data plane (D74) |

**Rate limits on this surface** (D74). Authenticated `/app/*` draws on a per-account bucket
at 300 ops/min. Unauthenticated `/app/auth/*` draws on **both** a per-address bucket — 20
ops/min over a fixed table of 4,096 buckets — and a global ceiling of 600 ops/min across the
whole unauthenticated surface.

The table is fixed-size and lossy: two addresses hashing together share a bucket, which makes
the limit stricter for both and never looser, and cannot be grown without bound by an attacker
rotating addresses.

**The global ceiling exists because the address itself is only trustworthy once the origin
firewall does.** Behind Cloudflare the real client address arrives in `CF-Connecting-IP`, and
that header is worth believing only when nothing but Cloudflare can reach the origin — which
is what `Full (strict)`, Authenticated Origin Pulls and the Cloudflare-ranges firewall
establish, and which lands at the end of M5 (D68). Until then the header is used when present
and the socket peer otherwise, and the ceiling is what actually bounds the surface.

**Identical responses are not enough on their own** (D75). An address that exists has a
password to verify at Argon2id cost; one that does not has nothing, and returning early is an
oracle no matter how identical the body is. So login against an unknown address performs a
full verification against a **dummy hash generated at startup** and discards the result,
signup with an existing address does the same work a new signup does, and reset always
answers the same way. The generated-not-hardcoded part matters for the same reason D63
refused a default signing secret: a constant in our source is a constant an attacker
recognises.

No account lockout on password failures — escalating delay instead. Lockout converts a
guessing attack into a denial-of-service against the real owner.

## Account deletion

Self-service, from the dashboard, no support ticket.

1. Confirm by typing the account email.
2. All API keys revoked immediately.
3. **All entries become permanently inaccessible immediately**, and their bytes are
   reclaimed as they expire — within the plan's maximum lifetime at the outside, so 14 days
   on trial and 30 on paid.
4. Sessions invalidated.
5. Account marked deleted; **identity anchors are retained as hashes** so the trial grant
   cannot be re-farmed by delete-and-resignup.
6. Unspent credits are forfeit, stated plainly on the confirmation screen.

**Step 3 says "inaccessible", not "deleted", and the difference is deliberate** (D77). The
index is keyed on a hash of `(account_id, name)` and stores no names, which is what makes
cross-account addressing unrepresentable — and the same property means there is no operation
that enumerates one account's entries either. So deletion revokes access at the credential,
which takes effect on the very next request through any key, and the bytes leave with the
expiry machinery that already reclaims every other entry.

This is only a complete answer because **lifetime is mandatory**. On a store with unlimited
retention "reclaimed when it expires" would mean "kept indefinitely"; here it is bounded by
the plan maximum, and that bound is the product's central constraint paying for itself.

Two places deletion is not total, both disclosed in the privacy statement rather than done
quietly: the anti-farming anchor hashes, and the window in step 3.
