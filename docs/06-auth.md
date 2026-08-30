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
parameters tuned to roughly 100 ms on the production box and recorded alongside each
hash so they can be raised later without invalidating existing passwords.

### Linking

An email-signup account whose address matches a verified GitHub email may later
authenticate via GitHub, and the identities link. **This does not grant a second trial
allocation** — see below.

## Trial credit anti-farming

The 10,000 credit grant is one-time and there is no recurring free tier, so a second
grant is the thing worth attacking.

The grant is recorded against **both** identity anchors:

- normalised verified email address (lowercased, plus-addressing stripped for
  matching, `@gmail.com` dot-normalised)
- GitHub numeric user id, when present

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

~190 bits of entropy. The `doot_live_` prefix makes keys greppable in leaked code and
allows a future `doot_test_` variant without ambiguity.

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
| shown in dashboard | label, `key_<id>`, first 4 chars after prefix, created-at, last-used-at |

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
| control plane overall | separate rate-limit bucket, tighter than the data plane |

No account lockout on password failures — escalating delay instead. Lockout converts a
guessing attack into a denial-of-service against the real owner.

## Account deletion

Self-service, from the dashboard, no support ticket.

1. Confirm by typing the account email.
2. All API keys revoked immediately.
3. All entries deleted immediately (tombstoned; bytes reclaimed with their segments).
4. Sessions invalidated.
5. Account row deleted; **identity anchors are retained as hashes** so the trial grant
   cannot be re-farmed by delete-and-resignup.
6. Unspent credits are forfeit, stated plainly on the confirmation screen.

Retaining anti-farming hashes after deletion is the one place deletion is not total. It
is disclosed in the privacy statement rather than done quietly.
