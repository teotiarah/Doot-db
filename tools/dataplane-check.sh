#!/usr/bin/env bash
# Data-plane checks against a client we did not write (M2 Pass 2, slice 2).
#
# Covers the five free endpoints, authentication, the pooled rate limit, and account
# isolation. The write endpoints are the next slice and are expected to answer `405` with
# an `Allow` that does not mention them, which is asserted here rather than assumed.
#
# Fixture entries are seeded through the engine by the harness, because nothing can be
# written over HTTP yet — which is the point: read, list and delete are verified in full
# before the write path exists.
#
# Usage: tools/dataplane-check.sh [path-to-dataplane-binary]
set -uo pipefail

BIN="${1:-./zig-out/bin/dataplane}"
WORK="$(mktemp -d)"
DATA="$WORK/data"
PASS=0
FAIL=0

cleanup() {
  [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null
  wait "${SERVER_PID:-}" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
fail() {
  FAIL=$((FAIL + 1))
  printf '  FAIL  %s\n' "$1"
  [ $# -gt 1 ] && printf '        expected: %s\n' "$2"
  [ $# -gt 2 ] && printf '        actual:   %s\n' "$3"
  return 0
}
has()    { if printf '%s' "$3" | grep -qF -- "$2"; then pass "$1"; else fail "$1" "to contain: $2" "$(printf '%s' "$3" | head -c 400)"; fi; }
lacks()  { if printf '%s' "$3" | grep -qF -- "$2"; then fail "$1" "not to contain: $2" "$(printf '%s' "$3" | head -c 300)"; else pass "$1"; fi; }
equals() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "$2" "$3"; fi; }
hdr()    { printf '\n=== %s ===\n' "$1"; }
digest() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

if [ ! -x "$BIN" ]; then
  echo "dataplane-check: $BIN not found. Run 'zig build verify' first." >&2
  exit 1
fi

# ---------------------------------------------------------------------------

mkdir -p "$DATA"
"$BIN" 127.0.0.1:0 "$DATA" >"$WORK/out.log" 2>&1 &
SERVER_PID=$!

PORT=""
for _ in $(seq 1 200); do
  PORT="$(sed -n 's/.*listening 127\.0\.0\.1:\([0-9]*\).*/\1/p' "$WORK/out.log" 2>/dev/null | head -1)"
  [ -n "$PORT" ] && break
  sleep 0.05
done
if [ -z "$PORT" ]; then
  echo "dataplane-check: harness never reported a port" >&2
  cat "$WORK/out.log" >&2
  exit 1
fi

TRIAL="$(sed -n 's/.*trial_key \(.*\)/\1/p' "$WORK/out.log" | head -1)"
OTHER="$(sed -n 's/.*other_key \(.*\)/\1/p' "$WORK/out.log" | head -1)"
RATE="$(sed -n 's/.*rate_key \(.*\)/\1/p' "$WORK/out.log" | head -1)"
BASE="http://127.0.0.1:$PORT"
CURL="curl -sS --max-time 10"
AUTH=(-H "Authorization: Bearer $TRIAL")

echo "dataplane-check: harness on $BASE (pid $SERVER_PID)"

# ---------------------------------------------------------------------------

hdr "GET /healthz — unauthenticated and unmetered"

RESP="$($CURL -i "$BASE/healthz")"
has "healthz is 200 without a key" "HTTP/1.1 200 OK" "$RESP"
has "healthz reports ok" '"status":"ok"' "$RESP"
has "healthz reports a sequence number" '"seq":' "$RESP"
# Unmetered: it is the one endpoint outside the bucket, so it must not claim otherwise.
lacks "healthz carries no rate-limit headers" "RateLimit-Limit" "$RESP"
has "healthz is JSON" "Content-Type: application/json" "$RESP"

RESP="$($CURL -i -X DELETE "$BASE/healthz")"
has "healthz refuses other methods" "405 Method Not Allowed" "$RESP"
has "healthz says which method it allows" "Allow: GET" "$RESP"

# ---------------------------------------------------------------------------

hdr "authentication"

RESP="$($CURL -i "$BASE/v1/whoami")"
has "no Authorization is 401" "HTTP/1.1 401 Unauthorized" "$RESP"
has "no Authorization names the code" '"code":"missing_credentials"' "$RESP"

RESP="$($CURL -i -H "Authorization: Bearer doot_live_nonexistent" "$BASE/v1/whoami")"
has "an unknown key is 401" "HTTP/1.1 401 Unauthorized" "$RESP"
has "an unknown key names the code" '"code":"invalid_credentials"' "$RESP"

RESP="$($CURL -i -H "Authorization: Basic dXNlcjpwYXNz" "$BASE/v1/whoami")"
has "a non-bearer scheme is 401" '"code":"missing_credentials"' "$RESP"

# An unrouted /v1 path with a bad key must be 401, not 404 — otherwise an
# unauthenticated prober can map which paths exist (02-api.md).
RESP="$($CURL -i -H "Authorization: Bearer doot_live_nonexistent" "$BASE/v1/does-not-exist")"
has "auth precedes routing, so a bad key never reveals a path" '"code":"invalid_credentials"' "$RESP"

# ---------------------------------------------------------------------------

hdr "GET /v1/whoami"

RESP="$($CURL -i "${AUTH[@]}" "$BASE/v1/whoami")"
has "whoami is 200" "HTTP/1.1 200 OK" "$RESP"
has "the account id is Crockford base32, padded (D59)" '"account_id":"acct_0000001"' "$RESP"
has "the key id is too" '"id":"key_0000001"' "$RESP"
has "the plan is named" '"plan":"trial"' "$RESP"
has "credits are reported" '"credits":{"remaining":10000,"granted":10000}' "$RESP"
has "the rate limit is the trial's" '"limit":100' "$RESP"
has "the window is stated" '"window":"1m"' "$RESP"
# The effective ceiling, which is the trial's 14 days rather than the engine's 30 (D56).
has "the lifetime ceiling is the plan's, not the engine's" '"max_ttl_seconds":1209600' "$RESP"
has "the body ceiling is published" '"max_body_bytes":262144' "$RESP"
has "the key's creation time is RFC 3339" '"created_at":"20' "$RESP"

has "every /v1 response carries RateLimit-Limit" "RateLimit-Limit: 100" "$RESP"
has "...and RateLimit-Remaining" "RateLimit-Remaining:" "$RESP"
has "...and RateLimit-Reset" "RateLimit-Reset:" "$RESP"

# ---------------------------------------------------------------------------

hdr "GET /v1/entries/{name}"

RESP="$($CURL -i "${AUTH[@]}" "$BASE/v1/entries/ci/last-green-sha")"
has "a read is 200" "HTTP/1.1 200 OK" "$RESP"
has "the stored content type comes back" "Content-Type: text/plain" "$RESP"
has "tags come back" "X-Doot-Tags: ci,main" "$RESP"
has "the canonical name comes back" "X-Doot-Name: ci/last-green-sha" "$RESP"
has "creation time comes back" "X-Doot-Created-At: 20" "$RESP"
has "expiry comes back" "X-Doot-Expires-At: 20" "$RESP"

# The body is the stored bytes, not a wrapper — this is what makes `curl -o` work.
$CURL "${AUTH[@]}" -o "$WORK/read.bin" "$BASE/v1/entries/ci/last-green-sha"
printf 'deadbeefcafe\n' > "$WORK/want.bin"
if [ "$(digest "$WORK/read.bin")" = "$(digest "$WORK/want.bin")" ]; then
  pass "the body is the stored bytes, byte for byte"
else
  fail "the body is the stored bytes, byte for byte" "deadbeefcafe" "$(head -c 40 "$WORK/read.bin")"
fi

equals "a zero-length body is a valid entry" "0" \
  "$($CURL "${AUTH[@]}" -o /dev/null -w '%{size_download}' "$BASE/v1/entries/locks/deploy")"

RESP="$($CURL -i "${AUTH[@]}" "$BASE/v1/entries/untagged")"
lacks "an untagged entry emits no X-Doot-Tags" "X-Doot-Tags" "$RESP"

# Namespacing: slashes in a name are part of the name.
has "a namespaced name reads back" "X-Doot-Name: agent/scratch/step-3" \
  "$($CURL -i "${AUTH[@]}" "$BASE/v1/entries/agent/scratch/step-3")"
# %2F and a literal slash are the same entry (03-data-model.md).
has "a percent-encoded slash addresses the same entry" "X-Doot-Name: agent/scratch/step-3" \
  "$($CURL -i "${AUTH[@]}" "$BASE/v1/entries/agent%2Fscratch%2Fstep-3")"

RESP="$($CURL -i "${AUTH[@]}" "$BASE/v1/entries/definitely-absent")"
has "an absent entry is 404" "HTTP/1.1 404 Not Found" "$RESP"
has "an absent entry names the code" '"code":"not_found"' "$RESP"

RESP="$($CURL -i "${AUTH[@]}" "$BASE/v1/entries/")"
has "an empty name is invalid_name, not a missing path" '"code":"invalid_name"' "$RESP"
RESP="$($CURL -i "${AUTH[@]}" "$BASE/v1/entries/bad%zz")"
has "a malformed escape is invalid_name" '"code":"invalid_name"' "$RESP"

# ---------------------------------------------------------------------------

hdr "account isolation"

# Both accounts hold this name. Each must see only its own.
equals "the other account sees its own entry at the same name" "NOT YOURS" \
  "$($CURL -H "Authorization: Bearer $OTHER" "$BASE/v1/entries/ci/last-green-sha")"
equals "and we see ours" "deadbeefcafe" \
  "$($CURL "${AUTH[@]}" "$BASE/v1/entries/ci/last-green-sha")"
equals "another account's private entry is 404 to us" "404" \
  "$($CURL "${AUTH[@]}" -o /dev/null -w '%{http_code}' "$BASE/v1/entries/secret")"

LIST="$($CURL -H "Authorization: Bearer $OTHER" "$BASE/v1/entries?tag=ci")"
lacks "a tag listing never crosses accounts" "locks/deploy" "$LIST"
has "...and does return that account's own entries" "secret" "$LIST"

# ---------------------------------------------------------------------------

hdr "GET /v1/entries?tag="

LIST="$($CURL "${AUTH[@]}" "$BASE/v1/entries?tag=ci")"
has "a listing returns entries" '"entries":[' "$LIST"
has "with names" '"name":"ci/last-green-sha"' "$LIST"
has "with tags" '"tags":["ci","main"]' "$LIST"
has "with content types" '"content_type":"text/plain"' "$LIST"
has "with sizes" '"size":13' "$LIST"
has "with timestamps" '"created_at":"20' "$LIST"
# Metadata only, so one page can never return megabytes (D23).
lacks "a listing never contains a body" "deadbeefcafe" "$LIST"
# Exhausted result sets carry no cursor, which is what tells a client to stop.
lacks "an exhausted listing carries no cursor" '"cursor"' "$LIST"

# A name containing quotes must be escaped rather than breaking the document.
LIST="$($CURL "${AUTH[@]}" "$BASE/v1/entries?tag=odd")"
has "a name with quotes is JSON-escaped" 'odd/name\"with' "$LIST"
if printf '%s' "$LIST" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
  pass "the listing is parseable JSON despite the name"
else
  fail "the listing is parseable JSON despite the name" "valid JSON" "$LIST"
fi

RESP="$($CURL -i "${AUTH[@]}" "$BASE/v1/entries")"
has "a listing without a tag is missing_tag" '"code":"missing_tag"' "$RESP"
for bad in 0 101 abc ""; do
  equals "limit=$bad is invalid_limit" "400" \
    "$($CURL "${AUTH[@]}" -o /dev/null -w '%{http_code}' "$BASE/v1/entries?tag=ci&limit=$bad")"
done
has "a malformed cursor is invalid_cursor" '"code":"invalid_cursor"' \
  "$($CURL -i "${AUTH[@]}" "$BASE/v1/entries?tag=ci&cursor=notacursor")"

# ---------------------------------------------------------------------------

hdr "pagination"

TOTAL=0
CURSOR=""
PAGES=0
while [ "$PAGES" -lt 10 ]; do
  if [ -z "$CURSOR" ]; then
    PAGE="$($CURL "${AUTH[@]}" "$BASE/v1/entries?tag=paged&limit=5")"
  else
    PAGE="$($CURL "${AUTH[@]}" "$BASE/v1/entries?tag=paged&limit=5&cursor=$CURSOR")"
  fi
  N="$(printf '%s' "$PAGE" | grep -o '"name"' | wc -l | tr -d ' ')"
  TOTAL=$((TOTAL + N))
  CURSOR="$(printf '%s' "$PAGE" | sed -n 's/.*"cursor":"\([^"]*\)".*/\1/p')"
  PAGES=$((PAGES + 1))
  [ -z "$CURSOR" ] && break
done
# Paginate until the cursor is absent, not until a page is short (02-api.md).
equals "following the cursor returns every entry exactly once" "12" "$TOTAL"
equals "and terminates" "3" "$PAGES"

FIRST="$($CURL "${AUTH[@]}" "$BASE/v1/entries?tag=paged&limit=5")"
CURSOR="$(printf '%s' "$FIRST" | sed -n 's/.*"cursor":"\([^"]*\)".*/\1/p')"
# Cursors are bound to the issuing account (D46).
has "a cursor issued to another account is refused" '"code":"invalid_cursor"' \
  "$($CURL -i -H "Authorization: Bearer $OTHER" "$BASE/v1/entries?tag=paged&limit=5&cursor=$CURSOR")"
# A single flipped character must not verify.
MANGLED="$(printf '%s' "$CURSOR" | sed 's/^./Z/')"
has "a tampered cursor is refused" '"code":"invalid_cursor"' \
  "$($CURL -i "${AUTH[@]}" "$BASE/v1/entries?tag=paged&limit=5&cursor=$MANGLED")"

# ---------------------------------------------------------------------------

hdr "DELETE /v1/entries/{name}"

RESP="$($CURL -i -X DELETE "${AUTH[@]}" "$BASE/v1/entries/doomed")"
has "a delete is 204" "HTTP/1.1 204 No Content" "$RESP"
# A 204 cannot carry a body, so it does not describe one.
lacks "a 204 declares no length" "Content-Length" "$RESP"
equals "a 204 sends no body" "0" \
  "$($CURL -X DELETE "${AUTH[@]}" -o /dev/null -w '%{size_download}' "$BASE/v1/entries/locks/deploy")"

has "deleting again is 404" '"code":"not_found"' \
  "$($CURL -i -X DELETE "${AUTH[@]}" "$BASE/v1/entries/doomed")"
equals "the deleted entry is gone from reads" "404" \
  "$($CURL "${AUTH[@]}" -o /dev/null -w '%{http_code}' "$BASE/v1/entries/doomed")"
lacks "and gone from listings" '"name":"doomed"' \
  "$($CURL "${AUTH[@]}" "$BASE/v1/entries?tag=ci")"

# ---------------------------------------------------------------------------

hdr "the write endpoints, which are the next slice"

RESP="$($CURL -i -X PUT "${AUTH[@]}" --data-binary 'x' "$BASE/v1/entries/new-name")"
has "PUT is 405 rather than a 500" "405 Method Not Allowed" "$RESP"
has "and its Allow does not claim PUT works" "Allow: GET, DELETE" "$RESP"
RESP="$($CURL -i -X POST "${AUTH[@]}" --data-binary '' "$BASE/v1/entries")"
has "POST is 405" "405 Method Not Allowed" "$RESP"
has "and its Allow is accurate too" "Allow: GET" "$RESP"

# A write with no Content-Length never reaches routing: the transport refuses it first,
# because that header is what lets an oversized upload be rejected before it is read.
has "a write without Content-Length is 411 at the transport" '"code":"length_required"' \
  "$($CURL -i -X PUT "${AUTH[@]}" "$BASE/v1/entries/new-name")"

# ---------------------------------------------------------------------------

hdr "unrouted paths"

for path in /nosuch /v1 /v1/ /v1/whoami/extra /app/account; do
  equals "$path is 404" "404" \
    "$($CURL "${AUTH[@]}" -o /dev/null -w '%{http_code}' "$BASE$path")"
done
has "an unrouted path uses the same code as a missing entry" '"code":"not_found"' \
  "$($CURL -i "${AUTH[@]}" "$BASE/nosuch")"

# ---------------------------------------------------------------------------

hdr "the pooled rate limit"

# On a dedicated account, so the bucket starts full and nothing above has spent from it.
# Trial is 100/minute with a burst of 100 (01-product.md).
OA=(-H "Authorization: Bearer $RATE")
CODES="$(for _ in $(seq 1 140); do
  $CURL "${OA[@]}" -o /dev/null -w '%{http_code}\n' "$BASE/v1/whoami"
done)"
OK_COUNT="$(printf '%s' "$CODES" | grep -c '^200$')"
LIMITED="$(printf '%s' "$CODES" | grep -c '^429$')"

# The burst, plus whatever refilled while the loop ran — 100/60 per second, so a couple of
# seconds of requests accrues a handful. Bounded rather than exact, because asserting an
# exact number would be asserting how fast this machine runs curl.
if [ "$OK_COUNT" -ge 100 ] && [ "$OK_COUNT" -le 125 ]; then
  pass "the burst is spendable and bounded ($OK_COUNT allowed of 140)"
else
  fail "the burst is spendable and bounded" "between 100 and 125 allowed" "$OK_COUNT"
fi
if [ "$LIMITED" -gt 0 ]; then
  pass "the excess is refused ($LIMITED rate limited)"
else
  fail "the excess is refused" "at least one 429" "none"
fi

RESP="$($CURL -i "${OA[@]}" "$BASE/v1/whoami")"
has "a 429 names the code" '"code":"rate_limited"' "$RESP"
has "a 429 carries Retry-After" "Retry-After:" "$RESP"
has "a 429 still carries the rate-limit headers" "RateLimit-Remaining: 0" "$RESP"

# The bucket is per account, so the others are untouched by that burn (D6).
equals "another account is unaffected" "200" \
  "$($CURL "${AUTH[@]}" -o /dev/null -w '%{http_code}' "$BASE/v1/whoami")"
# And reads keep working for the throttled account once tokens accrue.
sleep 1.2
equals "the bucket refills" "200" \
  "$($CURL "${OA[@]}" -o /dev/null -w '%{http_code}' "$BASE/v1/whoami")"

# ---------------------------------------------------------------------------

hdr "summary"

if ! kill -0 "$SERVER_PID" 2>/dev/null; then
  fail "the harness survived every check" "still running" "exited"
  echo "--- harness output ---"
  cat "$WORK/out.log"
else
  pass "the harness survived every check"
fi

printf '\n%s: %d passed, %d failed\n' \
  "$([ "$FAIL" -eq 0 ] && echo 'DATA-PLANE CHECKS PASSED' || echo 'DATA-PLANE CHECKS FAILED')" \
  "$PASS" "$FAIL"

[ "$FAIL" -eq 0 ]
