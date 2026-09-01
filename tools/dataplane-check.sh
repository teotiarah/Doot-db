#!/usr/bin/env bash
# Data-plane checks against a client we did not write (M2 Pass 2).
#
# Covers all seven endpoints, authentication, the pooled rate limit, account isolation,
# credits, idempotency and the documented write-validation order.
#
# Fixture entries are seeded through the engine by the harness, which keeps the read, list,
# delete and isolation checks independent of whether the write path is correct.
#
# Covered elsewhere, so that each check lives with the harness configuration it needs:
# `capacity_exhausted`, `idempotency_in_progress`, and credits and the rate limit under
# genuine concurrency are in `tools/exactness-check.sh`, which drives harnesses started with
# a tiny index budget and with a stopped clock. `headers_too_large` and `internal_error` are
# in `tools/transport-check.sh`, where the cases that produce them already live.
#
# The rate-limit block near the end of this file asserts a *range*, on purpose: with a
# running clock a burst that straddles a second boundary earns a refilled token and one that
# does not, does not. The exact assertion is the frozen-clock one in `exactness-check.sh`
# (D66); this one is here to prove the limit engages at all against a real clock.
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
BROKE="$(sed -n 's/.*broke_key \(.*\)/\1/p' "$WORK/out.log" | head -1)"
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
# The code as well as the status (D65). Note this row needs no credentials at all: the
# healthz method check happens before authentication.
has "and names the code" '"code":"method_not_allowed"' "$RESP"

# The other two Allow values, on the authenticated routes, so the whole 405 surface is
# covered rather than just the one path that needs no key.
RESP="$($CURL -i -X DELETE "${AUTH[@]}" "$BASE/v1/entries")"
has "DELETE on the collection is 405" "405 Method Not Allowed" "$RESP"
has "and lists the collection's methods" "Allow: GET, POST" "$RESP"
has "and names the code" '"code":"method_not_allowed"' "$RESP"

RESP="$($CURL -i -X POST "${AUTH[@]}" --data-binary 'x' "$BASE/v1/entries/ci/last-green-sha")"
has "POST on an entry is 405" "405 Method Not Allowed" "$RESP"
has "and lists the entry's methods" "Allow: GET, PUT, DELETE" "$RESP"

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

hdr "PUT /v1/entries/{name}"

# `curl` supplies its own Content-Type unless told otherwise, so it is set explicitly
# wherever the stored value is asserted.
JSON=(-H "Content-Type: application/json")

RESP="$($CURL -i -X PUT "${AUTH[@]}" "${JSON[@]}" -H 'X-Doot-Tags: CI,Main,ci' -H 'X-Doot-TTL: 2h' \
  --data-binary '{"v":1}' "$BASE/v1/entries/w/first")"
has "a new entry is 201" "HTTP/1.1 201 Created" "$RESP"
has "a write reports the balance" "X-Doot-Credits-Remaining:" "$RESP"
has "the body is the metadata document" '"name":"w/first"' "$RESP"
has "the content type is stored as supplied" '"content_type":"application/json"' "$RESP"
has "the size is the body length" '"size":7' "$RESP"
# Lowercased, de-duplicated, first-occurrence order — and counted after de-duplication.
has "tags are normalised" '"tags":["ci","main"]' "$RESP"
has "the document carries both timestamps" '"expires_at":"20' "$RESP"

# Overwriting is a write, and it replaces everything including the lifetime (D19).
RESP="$($CURL -i -X PUT "${AUTH[@]}" -H 'Content-Type: text/plain' --data-binary 'v2' \
  "$BASE/v1/entries/w/first")"
has "an overwrite is 200, not 201" "HTTP/1.1 200 OK" "$RESP"
has "an overwrite replaces the content type" '"content_type":"text/plain"' "$RESP"
lacks "an overwrite drops the previous tags" '"ci"' "$RESP"

equals "the entry reads back as the overwrite left it" "v2" \
  "$($CURL "${AUTH[@]}" "$BASE/v1/entries/w/first")"

hdr "POST /v1/entries"

RESP="$($CURL -i -X POST "${AUTH[@]}" "${JSON[@]}" -H 'X-Doot-Tags: webhook' \
  --data-binary '{"hook":true}' "$BASE/v1/entries")"
has "a server-assigned write is 201" "HTTP/1.1 201 Created" "$RESP"
has "and carries Location" "Location: /v1/entries/" "$RESP"
# 26 characters of Crockford base32, so it sorts by creation time.
if printf '%s' "$RESP" | grep -qE 'Location: /v1/entries/[0-9A-HJKMNP-TV-Z]{26}'; then
  pass "the assigned name is a 26-character ULID"
else
  fail "the assigned name is a 26-character ULID" "26 Crockford characters" \
    "$(printf '%s' "$RESP" | grep -i '^location:')"
fi
ASSIGNED="$(printf '%s' "$RESP" | sed -n 's|^[Ll]ocation: /v1/entries/\([A-Z0-9]*\).*|\1|p' | tr -d '\r')"
equals "the assigned entry reads back at its own name" '{"hook":true}' \
  "$($CURL "${AUTH[@]}" "$BASE/v1/entries/$ASSIGNED")"

hdr "credits"

BEFORE="$($CURL "${AUTH[@]}" "$BASE/v1/whoami" | sed -n 's/.*"credits":{"remaining":\([0-9]*\).*/\1/p')"
$CURL -X PUT "${AUTH[@]}" -o /dev/null --data-binary 'x' "$BASE/v1/entries/w/count-1"
AFTER="$($CURL "${AUTH[@]}" "$BASE/v1/whoami" | sed -n 's/.*"credits":{"remaining":\([0-9]*\).*/\1/p')"
equals "one write costs exactly one credit" "$((BEFORE - 1))" "$AFTER"

# Reads, lists and deletes are free (01-product.md).
$CURL "${AUTH[@]}" -o /dev/null "$BASE/v1/entries/w/count-1"
$CURL "${AUTH[@]}" -o /dev/null "$BASE/v1/entries?tag=ci"
$CURL -X DELETE "${AUTH[@]}" -o /dev/null "$BASE/v1/entries/w/count-1"
FREE="$($CURL "${AUTH[@]}" "$BASE/v1/whoami" | sed -n 's/.*"credits":{"remaining":\([0-9]*\).*/\1/p')"
equals "reads, lists and deletes cost nothing" "$AFTER" "$FREE"

# A validation failure must not be charged either.
$CURL -X PUT "${AUTH[@]}" -o /dev/null -H 'X-Doot-TTL: nonsense' --data-binary 'x' "$BASE/v1/entries/w/bad"
REJECTED="$($CURL "${AUTH[@]}" "$BASE/v1/whoami" | sed -n 's/.*"credits":{"remaining":\([0-9]*\).*/\1/p')"
equals "a rejected write costs nothing" "$FREE" "$REJECTED"

BA=(-H "Authorization: Bearer $BROKE")
RESP="$($CURL -i -X PUT "${BA[@]}" --data-binary 'x' "$BASE/v1/entries/nope")"
has "a write with no credits is 402" "HTTP/1.1 402 Payment Required" "$RESP"
has "and names the code" '"code":"credits_exhausted"' "$RESP"
# The failure mode to avoid is a user believing they lost their data (01-product.md).
equals "an exhausted account can still read" "404" \
  "$($CURL "${BA[@]}" -o /dev/null -w '%{http_code}' "$BASE/v1/entries/anything")"
equals "...and still list" "200" \
  "$($CURL "${BA[@]}" -o /dev/null -w '%{http_code}' "$BASE/v1/entries?tag=ci")"

hdr "idempotency"

FIRST="$($CURL -i -X PUT "${AUTH[@]}" "${JSON[@]}" -H 'Idempotency-Key: check-1' \
  --data-binary '{"n":1}' "$BASE/v1/entries/idem/one")"
has "the first request with a key executes" "HTTP/1.1 201 Created" "$FIRST"
lacks "and is not marked as a replay" "Idempotency-Replayed" "$FIRST"
FIRST_BODY="$(printf '%s' "$FIRST" | sed -n 's/^\({.*\)$/\1/p')"
BEFORE="$($CURL "${AUTH[@]}" "$BASE/v1/whoami" | sed -n 's/.*"credits":{"remaining":\([0-9]*\).*/\1/p')"

REPLAY="$($CURL -i -X PUT "${AUTH[@]}" "${JSON[@]}" -H 'Idempotency-Key: check-1' \
  --data-binary '{"n":1}' "$BASE/v1/entries/idem/one")"
has "a repeat replays the recorded status" "HTTP/1.1 201 Created" "$REPLAY"
has "and says so" "Idempotency-Replayed: true" "$REPLAY"
REPLAY_BODY="$(printf '%s' "$REPLAY" | sed -n 's/^\({.*\)$/\1/p')"
equals "and reproduces the original document exactly" "$FIRST_BODY" "$REPLAY_BODY"

AFTER="$($CURL "${AUTH[@]}" "$BASE/v1/whoami" | sed -n 's/.*"credits":{"remaining":\([0-9]*\).*/\1/p')"
# Free is a product decision, not an implementation detail: a retry storm must not bill.
equals "a replay consumes no credit" "$BEFORE" "$AFTER"

RESP="$($CURL -i -X PUT "${AUTH[@]}" "${JSON[@]}" -H 'Idempotency-Key: check-1' \
  --data-binary '{"n":2}' "$BASE/v1/entries/idem/one")"
has "the same key with a different body is 409" "HTTP/1.1 409 Conflict" "$RESP"
has "and names the code" '"code":"idempotency_key_reused"' "$RESP"
equals "and it overwrote nothing" '{"n":1}' \
  "$($CURL "${AUTH[@]}" "$BASE/v1/entries/idem/one")"

# A POST replay has to return the name the server assigned the first time, which is what
# the recorded location is for (D61).
ONE="$($CURL -i -X POST "${AUTH[@]}" -H 'Idempotency-Key: check-post' --data-binary 'p' "$BASE/v1/entries")"
TWO="$($CURL -i -X POST "${AUTH[@]}" -H 'Idempotency-Key: check-post' --data-binary 'p' "$BASE/v1/entries")"
LOC_ONE="$(printf '%s' "$ONE" | grep -i '^location:' | tr -d '\r')"
LOC_TWO="$(printf '%s' "$TWO" | grep -i '^location:' | tr -d '\r')"
equals "a POST replay returns the originally assigned name" "$LOC_ONE" "$LOC_TWO"
has "and is marked as a replay" "Idempotency-Replayed: true" "$TWO"

# A different key is a different request, however identical the body.
RESP="$($CURL -i -X POST "${AUTH[@]}" -H 'Idempotency-Key: check-post-2' --data-binary 'p' "$BASE/v1/entries")"
LOC_THREE="$(printf '%s' "$RESP" | grep -i '^location:' | tr -d '\r')"
if [ "$LOC_ONE" != "$LOC_THREE" ]; then
  pass "a different key writes a new entry"
else
  fail "a different key writes a new entry" "a different name" "$LOC_THREE"
fi

# "Any string, 1-255 bytes" (02-api.md). Over the ceiling is a malformed request rather
# than a validation failure on an entry field.
equals "an oversized Idempotency-Key is 400" "400" \
  "$($CURL -X PUT "${AUTH[@]}" -H "Idempotency-Key: $(head -c 300 /dev/zero | tr '\0' 'k')" \
     --data-binary 'x' -o /dev/null -w '%{http_code}' "$BASE/v1/entries/idem/bad")"

# An *empty* value needs a raw socket: curl drops a header whose value is empty rather than
# sending it, so through curl this request simply has no key — which is a 201, correctly.
EMPTY_KEY="$(python3 - "$PORT" "$TRIAL" <<'PY'
import socket, sys, time
port, key = int(sys.argv[1]), sys.argv[2]
s = socket.create_connection(("127.0.0.1", port), timeout=5)
s.sendall(
    b"PUT /v1/entries/idem/empty-key HTTP/1.1\r\nHost: d\r\n"
    b"Authorization: Bearer " + key.encode() + b"\r\n"
    b"Idempotency-Key: \r\nContent-Length: 1\r\n\r\nx"
)
time.sleep(0.4)
print(s.recv(400).split(b"\r\n")[0].decode(errors="replace"))
s.close()
PY
)"
has "an empty Idempotency-Key is 400" "400 Bad Request" "$EMPTY_KEY"

hdr "write validation, in the documented order"

equals "a name that will not decode is 400" "400" \
  "$($CURL -X PUT "${AUTH[@]}" --data-binary 'x' -o /dev/null -w '%{http_code}' "$BASE/v1/entries/bad%zz")"

for case in "1:ttl_too_short" "59:ttl_too_short" "0:ttl_too_short" "999d:ttl_too_long" \
            "abc:invalid_ttl" "1h30m:invalid_ttl" "-5:invalid_ttl" "1.5h:invalid_ttl"; do
  ttl="${case%%:*}"
  want="${case#*:}"
  has "X-Doot-TTL '$ttl' is $want" "\"code\":\"$want\"" \
    "$($CURL -i -X PUT "${AUTH[@]}" -H "X-Doot-TTL: $ttl" --data-binary 'x' "$BASE/v1/entries/w/ttl")"
done
# The trial's ceiling is 14 days, so 14d is legal and 15d is not (D56).
equals "14d is within the trial ceiling" "201" \
  "$($CURL -X PUT "${AUTH[@]}" -H 'X-Doot-TTL: 14d' --data-binary 'x' -o /dev/null -w '%{http_code}' "$BASE/v1/entries/w/ttl14")"
has "15d exceeds it" '"code":"ttl_too_long"' \
  "$($CURL -i -X PUT "${AUTH[@]}" -H 'X-Doot-TTL: 15d' --data-binary 'x' "$BASE/v1/entries/w/ttl15")"

has "a tag outside the character set is invalid_tag" '"code":"invalid_tag"' \
  "$($CURL -i -X PUT "${AUTH[@]}" -H 'X-Doot-Tags: not!valid' --data-binary 'x' "$BASE/v1/entries/w/tag")"
has "more than five distinct tags is too_many_tags" '"code":"too_many_tags"' \
  "$($CURL -i -X PUT "${AUTH[@]}" -H 'X-Doot-Tags: a,b,c,d,e,f' --data-binary 'x' "$BASE/v1/entries/w/tags")"
# Counted after de-duplication, so six copies of one tag is one tag (D47).
equals "six copies of one tag is one tag" "201" \
  "$($CURL -X PUT "${AUTH[@]}" -H 'X-Doot-Tags: ci,ci,ci,ci,ci,ci' --data-binary 'x' \
     -o /dev/null -w '%{http_code}' "$BASE/v1/entries/w/dedupe")"
# A trailing comma is a shell artefact rather than a caller bug.
equals "a trailing comma is tolerated" "201" \
  "$($CURL -X PUT "${AUTH[@]}" -H 'X-Doot-Tags: ci,main,' --data-binary 'x' \
     -o /dev/null -w '%{http_code}' "$BASE/v1/entries/w/trailing")"

has "an oversized Content-Type is 400" '"code":"content_type_too_long"' \
  "$($CURL -i -X PUT "${AUTH[@]}" -H "Content-Type: $(head -c 200 /dev/zero | tr '\0' 'x')" \
     --data-binary 'x' "$BASE/v1/entries/w/ct")"

# D64: a control byte in Content-Type used to be stored, charged for, and then fail on every
# read — the entry showed up in its tag listing and no GET of it could ever succeed. It needs
# a raw socket because curl will not put a NUL or a CR in a header value.
#
# The assertion is deliberately in two halves: the write is refused, *and* nothing was
# stored. A check that only asserted the 400 would still pass if the value were rejected on
# the way out instead of on the way in, which is the fix this is not.
POISON="$(python3 - "$PORT" "$TRIAL" <<'PY'
import socket, sys, time

port, key = int(sys.argv[1]), sys.argv[2]


def rt(name: bytes, ctype: bytes, method=b"PUT", body=b"x") -> str:
    s = socket.create_connection(("127.0.0.1", port), timeout=5)
    head = (
        method + b" /v1/entries/" + name + b" HTTP/1.1\r\nHost: d\r\n"
        b"Authorization: Bearer " + key.encode() + b"\r\n"
        b"X-Doot-TTL: 1h\r\n"
    )
    if ctype is not None:
        head += b"Content-Type: " + ctype + b"\r\n"
    if method == b"PUT":
        head += b"Content-Length: " + str(len(body)).encode() + b"\r\n\r\n" + body
    else:
        head += b"\r\n"
    s.sendall(head)
    time.sleep(0.4)
    out = s.recv(700)
    s.close()
    return out.decode("latin1", "replace")


# Written with a NUL, then a CR, then read back to prove neither landed.
print("NUL_PUT", rt(b"poison/nul", b"text/plain\x00evil").split("\r\n")[0])
print("NUL_BODY", "invalid_content_type" in rt(b"poison/nul", b"text/plain\x00evil"))
print("NUL_GET", rt(b"poison/nul", None, method=b"GET").split("\r\n")[0])
print("CR_PUT", rt(b"poison/cr", b"text/plain\revil").split("\r\n")[0])
print("CR_GET", rt(b"poison/cr", None, method=b"GET").split("\r\n")[0])
# A high byte is refused too: the rule is printable ASCII, not "not the three bad ones".
print("HIGH_PUT", rt(b"poison/high", b"text/plain\xc3\xa9").split("\r\n")[0])
# And an ordinary parameterised media type still works, so the rule is not overreaching.
print("OK_PUT", rt(b"poison/fine", b"text/plain; charset=utf-8").split("\r\n")[0])
PY
)"
has "a NUL in Content-Type is refused" "NUL_PUT HTTP/1.1 400 Bad Request" "$POISON"
has "and names the new code" "NUL_BODY True" "$POISON"
has "and the entry was never stored" "NUL_GET HTTP/1.1 404 Not Found" "$POISON"
has "a CR in Content-Type is refused" "CR_PUT HTTP/1.1 400 Bad Request" "$POISON"
has "and that entry was never stored either" "CR_GET HTTP/1.1 404 Not Found" "$POISON"
has "a byte above ASCII is refused" "HIGH_PUT HTTP/1.1 400 Bad Request" "$POISON"
has "a parameterised media type is still accepted" "OK_PUT HTTP/1.1 201 Created" "$POISON"

# A write with no Content-Length never reaches routing: the transport refuses it first,
# because that header is what lets an oversized upload be rejected before it is read.
has "a write without Content-Length is 411 at the transport" '"code":"length_required"' \
  "$($CURL -i -X PUT "${AUTH[@]}" "$BASE/v1/entries/w/nolen")"

hdr "the whole round trip"

# The published ceiling, byte for byte, through the API rather than seeded.
head -c 262144 /dev/urandom > "$WORK/big.bin"
$CURL -X PUT "${AUTH[@]}" -H 'Content-Type: application/octet-stream' \
  --data-binary "@$WORK/big.bin" -o /dev/null "$BASE/v1/entries/w/big"
$CURL "${AUTH[@]}" -o "$WORK/big.out" "$BASE/v1/entries/w/big"
if [ "$(digest "$WORK/big.bin")" = "$(digest "$WORK/big.out")" ]; then
  pass "a 256 KB entry written and read back is byte for byte identical"
else
  fail "a 256 KB entry written and read back is byte for byte identical" \
    "identical" "$(wc -c <"$WORK/big.out" | tr -d ' ') bytes"
fi

# An empty body is a valid entry — a lock or a flag (03-data-model.md).
equals "a zero-length write is 201" "201" \
  "$($CURL -X PUT "${AUTH[@]}" --data-binary '' -o /dev/null -w '%{http_code}' "$BASE/v1/entries/w/empty")"
equals "and reads back empty" "0" \
  "$($CURL "${AUTH[@]}" -o /dev/null -w '%{size_download}' "$BASE/v1/entries/w/empty")"

# A written entry appears in its tag's listing, in the same shape the write returned.
$CURL -X PUT "${AUTH[@]}" -H 'Content-Type: text/plain' -H 'X-Doot-Tags: roundtrip' \
  --data-binary 'listed' -o /dev/null "$BASE/v1/entries/w/listed"
LIST="$($CURL "${AUTH[@]}" "$BASE/v1/entries?tag=roundtrip")"
has "a written entry appears in its tag listing" '"name":"w/listed"' "$LIST"
has "described the same way a write described it" '"content_type":"text/plain"' "$LIST"
has "with the same size" '"size":6' "$LIST"

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
