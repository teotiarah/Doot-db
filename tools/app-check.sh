#!/usr/bin/env bash
# M3's control plane, driven by `curl` rather than by a client of our own.
#
# What this asserts that unit tests cannot:
#
#   - both halves of M3's exit condition over the wire: a signup path reaching an issued API
#     key, and revocation taking effect on the very next request;
#   - the credential separation `06-auth.md` requires — a bearer token cannot authenticate
#     /app, and a session cookie cannot authenticate /v1;
#   - the synchroniser token actually gating state-changing routes (D74/06-auth.md);
#   - enumeration resistance as a *timing* property, not only as identical bodies (D75). This
#     is the one that has to be measured from outside the process.
#
# The mail transport is the single substitution: the harness prints what it would have sent,
# because a check script has no inbox. Everything else is production code.
#
# Usage: tools/app-check.sh
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
fail() {
  FAIL=$((FAIL + 1))
  printf '  FAIL  %s\n' "$1" >&2
  [ -n "${2:-}" ] && printf '        %s\n' "$2" >&2
  return 0
}
hdr() { printf '\n=== %s ===\n' "$1"; }

equals() { # label expected actual
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected '$2', got '$3'"; fi
}
contains() { # label needle haystack
  case "$3" in *"$2"*) pass "$1" ;; *) fail "$1" "'$2' not in: $3" ;; esac
}
lacks() { # label needle haystack
  case "$3" in *"$2"*) fail "$1" "'$2' unexpectedly in: $3" ;; *) pass "$1" ;; esac
}

WORK="$(mktemp -d /tmp/doot_appcheck.XXXXXX)"
LOG="$WORK/harness.log"
COOKIES="$WORK/cookies"
HPID=""

cleanup() {
  [ -n "$HPID" ] && kill "$HPID" 2>/dev/null
  wait 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

zig build >/dev/null 2>&1 || { echo "build failed" >&2; exit 1; }

# stderr, because that is where the harness announces itself and its mail.
./zig-out/bin/app 127.0.0.1:0 "$WORK/data" >"$LOG" 2>&1 &
HPID=$!

PORT=""
for _ in $(seq 1 100); do
  PORT="$(grep -oE '^LISTENING [0-9]+' "$LOG" 2>/dev/null | head -1 | cut -d' ' -f2)"
  [ -n "$PORT" ] && break
  kill -0 "$HPID" 2>/dev/null || { echo "harness died:"; cat "$LOG"; exit 1; }
  sleep 0.1
done
[ -n "$PORT" ] || { echo "harness never listened:"; cat "$LOG"; exit 1; }
BASE="http://127.0.0.1:$PORT"

# Waits for the harness to print a code for an address, and returns the newest.
#
# `after` is how many lines for that address already existed, so a *re*-signup waits for its
# own code rather than picking up the previous one -- which is a race the first version of this
# script lost, since the printer thread has a 20 ms tick.
# `grep -c` already prints 0 when it matches nothing, and then exits 1 -- so a `|| echo 0`
# prints a second zero and every arithmetic comparison downstream breaks on "0\n0".
mail_count() { grep -cE "^MAIL $1 " "$LOG" 2>/dev/null | head -1; }

otp_for() { # address [after]
  local after="${2:-0}"
  for _ in $(seq 1 100); do
    if [ "$(mail_count "$1")" -gt "$after" ]; then
      grep -E "^MAIL $1 " "$LOG" | tail -1 | awk '{print $3}'
      return 0
    fi
    sleep 0.1
  done
  return 1
}

# Every request carries an explicit client address.
#
# Two reasons. The per-address bucket is 20/min (D74), so without this the checks would drain
# one another's budget and later sections would fail as 429 for reasons that have nothing to do
# with what they assert — which is exactly what the first run of this script did. And it
# exercises the CF-Connecting-IP path itself, which is how the origin will see a real client
# once it is behind Cloudflare.
#
# The header is trusted here because nothing yet stops it being set; that is D74's stated
# dependency on the origin firewall, and until M5 the global ceiling is what bounds the surface.
CLIENT_IP="203.0.113.1"
status() { curl -sS -o /dev/null -w '%{http_code}' -H "CF-Connecting-IP: $CLIENT_IP" "$@"; }
body() { curl -sS -H "CF-Connecting-IP: $CLIENT_IP" "$@"; }
json_field() { grep -o "\"$1\":\"[^\"]*\"" | head -1 | cut -d'"' -f4; }

# ---------------------------------------------------------------------------
hdr "the surface exists, and unknown paths do not"
# ---------------------------------------------------------------------------

equals "an unrouted control-plane path is 404" 404 "$(status "$BASE/app/nope")"
# `/app` with nothing after it is not the control plane, so it falls to the data plane -- where
# authentication happens *before* routing, so an unknown path is a 401 and never reveals whether
# it existed (D52, 02-api.md). That is the same answer every unknown /v1 path gives.
equals "/app itself falls to the data plane, which authenticates before routing" 401 \
  "$(status "$BASE/app")"
# The live feed is routed now, so it answers like every other session-authenticated route:
# 401 without a session rather than 404. Its own section below drives it properly.
equals "the live feed needs a session" 401 "$(status "$BASE/app/stream")"
# `--data ''` because the transport requires a Content-Length on a write before it routes
# (411, 02-api.md); without it the answer would be about the missing header rather than about
# the method. Read-only is a product boundary, so the answer must be 405 and not 404.
equals "a write to the explorer is 405, not 404" 405 \
  "$(status -X PUT "$BASE/app/entries/whatever" --data '')"
contains "and it says which method is allowed" "GET" \
  "$(curl -sS -D- -o /dev/null -H "CF-Connecting-IP: $CLIENT_IP" -X PUT "$BASE/app/entries/x" --data '' | grep -i '^allow:')"

# ---------------------------------------------------------------------------
hdr "signup validates before it does any work"
# ---------------------------------------------------------------------------

equals "a bad address is invalid_email" 400 \
  "$(status -X POST "$BASE/app/auth/signup" -d 'email=nope&password=averylongpassword')"
contains "and names the code" "invalid_email" \
  "$(body -X POST "$BASE/app/auth/signup" -d 'email=nope&password=averylongpassword')"
equals "a short password is refused" 400 \
  "$(status -X POST "$BASE/app/auth/signup" -d 'email=a@b.co&password=short')"
contains "and names that code too" "password_too_short" \
  "$(body -X POST "$BASE/app/auth/signup" -d 'email=a@b.co&password=short')"

# ---------------------------------------------------------------------------
hdr "the email signup path reaches an issued API key (M3 exit condition)"
# ---------------------------------------------------------------------------

USER="founder@example.com"
PW="correct horse battery staple"

equals "signup is accepted" 202 \
  "$(status -X POST "$BASE/app/auth/signup" --data-urlencode "email=$USER" --data-urlencode "password=$PW")"

CODE="$(otp_for "$USER")" || fail "a verification code was queued" "none printed"
if [ -n "${CODE:-}" ]; then
  pass "a verification code was queued"
  equals "the code is six digits" 6 "${#CODE}"
fi

# Verify establishes a session and issues no key (D83).
VERIFY_HEADERS="$WORK/verify.h"
VERIFY_BODY="$(curl -sS -D "$VERIFY_HEADERS" -c "$COOKIES" -X POST "$BASE/app/auth/verify" \
  --data-urlencode "email=$USER" --data-urlencode "code=$CODE")"
contains "verification sets the session cookie" "__Host-doot_session" "$(cat "$VERIFY_HEADERS")"
contains "the cookie is HttpOnly, Secure and SameSite=Lax" "HttpOnly; Secure; SameSite=Lax" \
  "$(cat "$VERIFY_HEADERS")"
lacks "verification does not hand back an API key (D83)" "doot_live_" "$VERIFY_BODY"
SYNC="$(printf '%s' "$VERIFY_BODY" | json_field synchroniser)"
[ -n "$SYNC" ] && pass "and returns a synchroniser token" || fail "and returns a synchroniser token" "$VERIFY_BODY"

# A used code is single-use.
equals "the same code cannot be used twice" 400 \
  "$(status -X POST "$BASE/app/auth/verify" --data-urlencode "email=$USER" --data-urlencode "code=$CODE")"

# The dashboard's first-run step: the one way a key is ever issued.
KEY_BODY="$(body -b "$COOKIES" -X POST "$BASE/app/keys" --data '' -H "X-Doot-Synchroniser: $SYNC")"
KEY="$(printf '%s' "$KEY_BODY" | json_field api_key)"
KEY_ID="$(printf '%s' "$KEY_BODY" | json_field key_id)"
case "$KEY" in
  doot_live_*) pass "POST /app/keys issues a key with the published prefix" ;;
  *) fail "POST /app/keys issues a key with the published prefix" "$KEY_BODY" ;;
esac
equals "the key is 42 characters (10 prefix + 32 base62)" 42 "${#KEY}"

# And it works on the data plane. This is the exit condition, end to end.
equals "the issued key authenticates a /v1 request" 200 \
  "$(status -H "Authorization: Bearer $KEY" "$BASE/v1/whoami")"
contains "and whoami reports the account's own address" "$USER" \
  "$(body -H "Authorization: Bearer $KEY" "$BASE/v1/whoami")"

# ---------------------------------------------------------------------------
hdr "revocation takes effect on the next request (M3 exit condition)"
# ---------------------------------------------------------------------------

contains "the key is listed while it is live" "$KEY_ID" "$(body -b "$COOKIES" "$BASE/app/keys")"
equals "revoking it is 204" 204 \
  "$(status -b "$COOKIES" -X DELETE "$BASE/app/keys/$KEY_ID" -H "X-Doot-Synchroniser: $SYNC")"
# The next request, with no interval and no cache to expire.
equals "the very next /v1 request with that key is 401" 401 \
  "$(status -H "Authorization: Bearer $KEY" "$BASE/v1/whoami")"
lacks "and it is no longer listed" "$KEY_ID" "$(body -b "$COOKIES" "$BASE/app/keys")"
equals "revoking it again is 404, not an error" 404 \
  "$(status -b "$COOKIES" -X DELETE "$BASE/app/keys/$KEY_ID" -H "X-Doot-Synchroniser: $SYNC")"

# ---------------------------------------------------------------------------
hdr "the two planes never accept each other's credentials"
# ---------------------------------------------------------------------------

FRESH="$(body -b "$COOKIES" -X POST "$BASE/app/keys" --data '' -H "X-Doot-Synchroniser: $SYNC" | json_field api_key)"

# A bearer token is not a session. This is what removes CSRF from /v1 entirely.
equals "a bearer token cannot authenticate /app" 401 \
  "$(status -H "Authorization: Bearer $FRESH" "$BASE/app/account")"
# And a session cookie is not an API key.
equals "a session cookie cannot authenticate /v1" 401 \
  "$(status -b "$COOKIES" "$BASE/v1/whoami")"
equals "no credential at all on /app is 401" 401 "$(status "$BASE/app/account")"

# ---------------------------------------------------------------------------
hdr "the synchroniser token gates state-changing routes"
# ---------------------------------------------------------------------------

# `--data ''` supplies the Content-Length that 02-api.md requires of a write. A browser always
# sends it; curl only sends one when there is a body, so its absence would be an 411 about the
# client rather than a 403 about the token.
equals "a state-changing route without the token is 403" 403 \
  "$(status -b "$COOKIES" -X POST "$BASE/app/keys" --data '')"
contains "and names the code" "invalid_synchroniser" \
  "$(body -b "$COOKIES" -X POST "$BASE/app/keys" --data '')"
equals "a wrong token is also 403" 403 \
  "$(status -b "$COOKIES" -X POST "$BASE/app/keys" --data '' -H "X-Doot-Synchroniser: wrong")"
# A read is not gated: the token defends against a cross-site *write*.
equals "a read needs no token" 200 "$(status -b "$COOKIES" "$BASE/app/account")"
contains "and the account view re-derives one" "synchroniser" "$(body -b "$COOKIES" "$BASE/app/account")"

# ---------------------------------------------------------------------------
hdr "login, and the explorer that reuses the data plane's read path"
CLIENT_IP="203.0.113.10"
# ---------------------------------------------------------------------------

LOGIN_COOKIES="$WORK/login_cookies"
LOGIN_BODY="$(curl -sS -c "$LOGIN_COOKIES" -X POST "$BASE/app/auth/login" \
  --data-urlencode "email=$USER" --data-urlencode "password=$PW")"
contains "login returns the account id" "acct_" "$LOGIN_BODY"
equals "the session it creates works" 200 "$(status -b "$LOGIN_COOKIES" "$BASE/app/account")"
equals "a wrong password is 401" 401 \
  "$(status -X POST "$BASE/app/auth/login" --data-urlencode "email=$USER" --data-urlencode "password=wrongwrongwrong")"

# The address is matched on its anchor, so case and dots find the same account (D72).
equals "an equivalent spelling of the address signs in" 200 \
  "$(status -X POST "$BASE/app/auth/login" --data-urlencode "email=Founder@Example.com" --data-urlencode "password=$PW")"

# Write an entry with the API key, then read it back through the explorer.
curl -sS -X PUT "$BASE/v1/entries/ci/last-green" -H "Authorization: Bearer $FRESH" \
  -H 'X-Doot-Tags: ci' --data-binary 'deadbeef' >/dev/null
contains "the explorer lists by tag" "ci/last-green" \
  "$(body -b "$COOKIES" "$BASE/app/entries?tag=ci")"
equals "the explorer reads one entry" 200 "$(status -b "$COOKIES" "$BASE/app/entries/ci/last-green")"
equals "and returns the stored bytes" "deadbeef" "$(body -b "$COOKIES" "$BASE/app/entries/ci/last-green")"

# ---------------------------------------------------------------------------
hdr "the live feed (D84-D87)"
CLIENT_IP="203.0.113.30"
# ---------------------------------------------------------------------------

# A second account, so cross-account isolation is testable rather than assumed.
OTHER="watcher@example.com"
curl -sS -o /dev/null -H "CF-Connecting-IP: $CLIENT_IP" -X POST "$BASE/app/auth/signup" \
  --data-urlencode "email=$OTHER" --data-urlencode "password=$PW"
OTHER_CODE="$(otp_for "$OTHER")"
OTHER_BODY="$(curl -sS -H "CF-Connecting-IP: $CLIENT_IP" -c "$WORK/other_cookies" \
  -X POST "$BASE/app/auth/verify" --data-urlencode "email=$OTHER" --data-urlencode "code=$OTHER_CODE")"
OTHER_SYNC="$(printf '%s' "$OTHER_BODY" | json_field synchroniser)"
OTHER_KEY="$(body -b "$WORK/other_cookies" -X POST "$BASE/app/keys" --data '' \
  -H "X-Doot-Synchroniser: $OTHER_SYNC" | json_field api_key)"

SESSION_COOKIE="$(grep -o '__Host-doot_session[[:space:]]*[^[:space:]]*' "$COOKIES" | awk '{print $2}')"

# The head, before any event exists. A stream that only opened once it had something to say
# would leave the dashboard unable to tell "connected and quiet" from "not connected".
STREAM_HEAD="$(curl -sS -D- -o /dev/null --max-time 3 \
  -H "CF-Connecting-IP: $CLIENT_IP" \
  -H "Cookie: __Host-doot_session=$SESSION_COOKIE" \
  -H 'Accept: text/event-stream' "$BASE/app/stream" 2>/dev/null || true)"
contains "the stream answers text/event-stream" "text/event-stream" "$STREAM_HEAD"
# The omission is the framing (D84): a body that is not finished has no length to announce.
lacks "and declares no Content-Length" "Content-Length" "$STREAM_HEAD"
lacks "and is not chunked either" "Transfer-Encoding" "$STREAM_HEAD"
contains "and asks intermediaries not to transform it" "no-transform" "$STREAM_HEAD"
contains "and sets X-Accel-Buffering" "X-Accel-Buffering: no" "$STREAM_HEAD"

equals "the stream needs a session, like every other /app route" 401 \
  "$(status -H 'Accept: text/event-stream' "$BASE/app/stream")"
equals "a write to the stream is 405" 405 \
  "$(status -X POST "$BASE/app/stream" --data '')"

# ---- SSE, judged by ops/sseprobe.py: the artifact D31 named as the verification procedure ----
#
# Run against the local origin here. That is D68's "both are built and tested locally" -- the
# run *through Cloudflare* is what moved to the end of M5, and it needs a reachable box.
( for i in $(seq 1 12); do
    sleep 0.25
    curl -sS -o /dev/null -H "Authorization: Bearer $FRESH" \
      -X PUT "$BASE/v1/entries/live/tick-$i" --data-binary "$i" 2>/dev/null || true
  done ) &
WRITER=$!

if python3 ops/sseprobe.py "$BASE/app/stream" \
     --expect-interval 250 --events 4 --timeout 20 \
     --header "Cookie: __Host-doot_session=$SESSION_COOKIE" >"$WORK/probe.out" 2>&1; then
  pass "ops/sseprobe.py judges the local stream as streaming, not buffered"
else
  fail "ops/sseprobe.py judges the local stream as streaming, not buffered" "$(tail -12 "$WORK/probe.out")"
fi
wait "$WRITER" 2>/dev/null || true
sed -n 's/^/        /p' "$WORK/probe.out" | grep -E "mean inter-event|first event|frames:" || true

# ---- the other framing on the same path (D87) ----
#
# Stateless and immediate: the client's cursor goes in the query string and the next one comes
# back in the body. Nothing about the request outlives it, which is what stops the fallback
# spending the data plane's concurrency budget.

POLL_ONE="$(body -b "$COOKIES" -H 'Accept: application/json' "$BASE/app/stream")"
contains "the same path answers JSON when JSON is asked for" '"events"' "$POLL_ONE"
contains "and carries a cursor to ask from next" '"cursor"' "$POLL_ONE"
contains "and reports whether the client was lapped" '"resync"' "$POLL_ONE"
CURSOR="$(printf '%s' "$POLL_ONE" | grep -o '"cursor":[0-9]*' | cut -d: -f2)"
[ -n "$CURSOR" ] && pass "the cursor is a number" || fail "the cursor is a number" "$POLL_ONE"

# It answers at once rather than waiting, which is the whole point of the amendment.
POLL_START=$(date +%s)
_="$(body -b "$COOKIES" -H 'Accept: application/json' "$BASE/app/stream?cursor=$CURSOR")"
POLL_ELAPSED=$(( $(date +%s) - POLL_START ))
if [ "$POLL_ELAPSED" -le 2 ]; then
  pass "an empty poll answers immediately rather than holding the connection"
else
  fail "an empty poll answers immediately rather than holding the connection" "took ${POLL_ELAPSED}s"
fi

# A write after that cursor shows up in the next poll.
curl -sS -o /dev/null -H "CF-Connecting-IP: $CLIENT_IP" -H "Authorization: Bearer $FRESH" \
  -X PUT "$BASE/v1/entries/live/polled" --data-binary 'x'
POLL_TWO="$(body -b "$COOKIES" -H 'Accept: application/json' "$BASE/app/stream?cursor=$CURSOR")"
contains "a write after the cursor appears in the next poll" '"op":"put"' "$POLL_TWO"
# A notification, not the change: no name and no body, because a body can be 256 KB (D85).
lacks "and the batch carries no entry name" "live/polled" "$POLL_TWO"
lacks "and no body" '"body"' "$POLL_TWO"

equals "a malformed cursor is refused" 400 \
  "$(status -b "$COOKIES" -H 'Accept: application/json' "$BASE/app/stream?cursor=abc")"

# ---- cross-account isolation ----

curl -sS -o /dev/null -H "CF-Connecting-IP: $CLIENT_IP" -H "Authorization: Bearer $OTHER_KEY" \
  -X PUT "$BASE/v1/entries/theirs/secret" --data-binary 'x'
# A cursor taken *after* this account's own writes, so the only thing published beyond it is the
# other account's -- which makes an empty array the whole assertion.
ISO_CURSOR="$(body -b "$COOKIES" -H 'Accept: application/json' "$BASE/app/stream" | grep -o '"cursor":[0-9]*' | cut -d: -f2)"
curl -sS -o /dev/null -H "CF-Connecting-IP: $CLIENT_IP" -H "Authorization: Bearer $OTHER_KEY" \
  -X PUT "$BASE/v1/entries/theirs/secret-2" --data-binary 'x'
ISO="$(body -b "$COOKIES" -H 'Accept: application/json' "$BASE/app/stream?cursor=$ISO_CURSOR")"
contains "another account's writes never appear in this account's feed" '"events":[]' "$ISO"
OTHER_FEED="$(body -b "$WORK/other_cookies" -H 'Accept: application/json' "$BASE/app/stream?cursor=$CURSOR")"
contains "and the account that made the write does see it" '"op":"put"' "$OTHER_FEED"

# ---------------------------------------------------------------------------
hdr "enumeration resistance: identical answers"
CLIENT_IP="203.0.113.20"
# ---------------------------------------------------------------------------

equals "signup for an address that already exists is still 202" 202 \
  "$(status -X POST "$BASE/app/auth/signup" --data-urlencode "email=$USER" --data-urlencode "password=$PW")"
equals "reset for a known address is 202" 202 \
  "$(status -X POST "$BASE/app/auth/password/reset" --data-urlencode "email=$USER")"
equals "reset for an unknown address is also 202" 202 \
  "$(status -X POST "$BASE/app/auth/password/reset" --data-urlencode "email=nobody@example.com")"
equals "login for an unknown address is 401, like a wrong password" 401 \
  "$(status -X POST "$BASE/app/auth/login" --data-urlencode "email=nobody@example.com" --data-urlencode "password=$PW")"

RESET_KNOWN="$(body -X POST "$BASE/app/auth/password/reset" --data-urlencode "email=$USER")"
RESET_UNKNOWN="$(body -X POST "$BASE/app/auth/password/reset" --data-urlencode "email=ghost@example.com")"
equals "and the two reset bodies are byte-identical" "$RESET_KNOWN" "$RESET_UNKNOWN"

# ---------------------------------------------------------------------------
hdr "enumeration resistance: identical work (D75)"
# ---------------------------------------------------------------------------

# The half no unit test can assert, because it is only observable from outside the process:
# an unknown address must pay for a full Argon2id verification too. Deliberately a wide band
# — a tight timing assertion on shared CI hardware is D53's flaky-by-construction shape.
# A fresh client address per sample, so no sample can be a 429 -- the first run of this script
# measured 5 ms for an unknown address and that was a refusal, not a fast verification. The
# status is checked, so a rate-limited sample fails loudly instead of scoring as a fast one.
SAMPLE=0
ms_for() { # email
  local start end code
  SAMPLE=$((SAMPLE + 1))
  start=$(date +%s%N)
  code="$(curl -sS -o /dev/null -w '%{http_code}' -H "CF-Connecting-IP: 198.51.100.$SAMPLE" \
    -X POST "$BASE/app/auth/login" \
    --data-urlencode "email=$1" --data-urlencode "password=definitelywrongpassword")"
  end=$(date +%s%N)
  if [ "$code" = "429" ]; then echo "-1"; return; fi
  echo $(((end - start) / 1000000))
}

# Median of five, so one scheduling hiccup does not decide it.
median_ms() { # email
  local xs=()
  for _ in 1 2 3 4 5; do xs+=("$(ms_for "$1")"); done
  printf '%s\n' "${xs[@]}" | sort -n | sed -n '3p'
}

no_429() { # label value
  [ "$2" = "-1" ] && { fail "$1" "a sample was rate limited, so the timing means nothing"; return 1; }
  return 0
}

KNOWN_MS="$(median_ms "$USER")"
UNKNOWN_MS="$(median_ms "nobody@example.com")"
no_429 "the timing samples were not rate limited" "$KNOWN_MS" &&
  no_429 "the timing samples were not rate limited" "$UNKNOWN_MS" &&
  pass "the timing samples were not rate limited"
printf '        known %s ms, unknown %s ms\n' "$KNOWN_MS" "$UNKNOWN_MS"

# Both must be doing real work: a skipped verification would be near-instant.
if [ "$UNKNOWN_MS" -ge 5 ]; then
  pass "an unknown address pays for a verification rather than returning early"
else
  fail "an unknown address pays for a verification rather than returning early" \
    "unknown took ${UNKNOWN_MS}ms, which is too fast to have hashed anything"
fi

# And neither is a multiple of the other. The band is wide on purpose (D53).
if [ "$KNOWN_MS" -gt 0 ] && [ "$UNKNOWN_MS" -gt 0 ]; then
  RATIO=$(((KNOWN_MS * 100) / UNKNOWN_MS))
  if [ "$RATIO" -ge 40 ] && [ "$RATIO" -le 250 ]; then
    pass "known and unknown addresses cost within a factor of ~2 of each other"
  else
    fail "known and unknown addresses cost within a factor of ~2 of each other" \
      "ratio ${RATIO}% (known ${KNOWN_MS}ms, unknown ${UNKNOWN_MS}ms)"
  fi
fi

# ---------------------------------------------------------------------------
hdr "the unauthenticated surface is rate limited (D74)"
CLIENT_IP="203.0.113.99"  # its own address, so the burst cannot spend anyone else's budget
# ---------------------------------------------------------------------------

# The per-address bucket is 20/min, so a burst from one address must hit it.
SAW_429=0
for i in $(seq 1 40); do
  c="$(status -X POST "$BASE/app/auth/password/reset" --data-urlencode "email=burst$i@example.com")"
  [ "$c" = "429" ] && { SAW_429=1; break; }
done
[ "$SAW_429" = "1" ] && pass "a burst on /app/auth is refused with 429" ||
  fail "a burst on /app/auth is refused with 429" "never saw a 429 in 40 attempts"

# The data plane's bucket is untouched by that: separate buckets are a product requirement.
equals "the data plane is unaffected by the control plane's bucket" 200 \
  "$(status -H "Authorization: Bearer $FRESH" "$BASE/v1/whoami")"

# ---------------------------------------------------------------------------
hdr "self-service deletion ends access immediately (D77)"
CLIENT_IP="203.0.113.50"
# ---------------------------------------------------------------------------

DEL_COOKIES="$WORK/del_cookies"
DEL_USER="leaver@example.com"
curl -sS -o /dev/null -X POST "$BASE/app/auth/signup" \
  --data-urlencode "email=$DEL_USER" --data-urlencode "password=$PW"
DEL_CODE="$(otp_for "$DEL_USER")"
DEL_BODY="$(curl -sS -c "$DEL_COOKIES" -X POST "$BASE/app/auth/verify" \
  --data-urlencode "email=$DEL_USER" --data-urlencode "code=$DEL_CODE")"
DEL_SYNC="$(printf '%s' "$DEL_BODY" | json_field synchroniser)"
DEL_KEY="$(body -b "$DEL_COOKIES" -X POST "$BASE/app/keys" --data '' -H "X-Doot-Synchroniser: $DEL_SYNC" | json_field api_key)"

equals "the second account's key works before deletion" 200 \
  "$(status -H "Authorization: Bearer $DEL_KEY" "$BASE/v1/whoami")"
equals "deletion is 204" 204 \
  "$(status -b "$DEL_COOKIES" -X DELETE "$BASE/app/account" -H "X-Doot-Synchroniser: $DEL_SYNC")"
# Access ends at the credential, which is what D77 substitutes for a deletion the index
# cannot perform.
equals "its key stops working at once" 401 "$(status -H "Authorization: Bearer $DEL_KEY" "$BASE/v1/whoami")"
equals "and its session is gone" 401 "$(status -b "$DEL_COOKIES" "$BASE/app/account")"
# The anchor is retained, so the trial grant cannot be re-farmed by delete-and-resignup.
MAILS_BEFORE="$(mail_count "$DEL_USER")"
equals "signing up again is accepted" 202 \
  "$(status -X POST "$BASE/app/auth/signup" --data-urlencode "email=$DEL_USER" --data-urlencode "password=$PW")"
RE_CODE="$(otp_for "$DEL_USER" "$MAILS_BEFORE")"
RE_STATUS="$(curl -sS -o /dev/null -w '%{http_code}' -H "CF-Connecting-IP: $CLIENT_IP" \
  -c "$WORK/re_cookies" -X POST "$BASE/app/auth/verify" \
  --data-urlencode "email=$DEL_USER" --data-urlencode "code=$RE_CODE")"
equals "the re-created account verifies" 201 "$RE_STATUS"
# The anchor survives deletion (06-auth.md, D77), so a re-created account activates with zero
# credits -- which is what stops delete-and-resignup farming the trial grant.
contains "but the re-created account is granted nothing (anchor retained)" '"granted":0' \
  "$(body -b "$WORK/re_cookies" "$BASE/app/account")"

# ---------------------------------------------------------------------------
hdr "logout"
CLIENT_IP="203.0.113.51"
# ---------------------------------------------------------------------------

equals "logout is 204" 204 \
  "$(status -b "$LOGIN_COOKIES" -X POST "$BASE/app/auth/logout" \
    --data '' -H "X-Doot-Synchroniser: $(body -b "$LOGIN_COOKIES" "$BASE/app/account" | json_field synchroniser)")"
equals "and the session no longer resolves" 401 "$(status -b "$LOGIN_COOKIES" "$BASE/app/account")"

# ---------------------------------------------------------------------------
hdr "summary"
# ---------------------------------------------------------------------------

if [ "$FAIL" -eq 0 ]; then
  printf '\nAPP CHECKS PASSED: %d passed, 0 failed\n' "$PASS"
  exit 0
fi
printf '\nAPP CHECKS FAILED: %d passed, %d failed\n' "$PASS" "$FAIL" >&2
exit 1
