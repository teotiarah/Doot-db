#!/usr/bin/env bash
# The exit conditions that need a harness configured differently (M2, D65 and D66).
#
# `dataplane-check.sh` drives one harness with a real clock and an unbounded index, which is
# the right shape for the endpoints and the wrong shape for four things:
#
#   - **`capacity_exhausted`** needs an index that is already full. Admission control is
#     driven entirely by the index budget, and with no budget it can never engage at any
#     volume — so this row was unreachable through that harness by construction (D43's
#     hazard from the other side).
#   - **credits, exactly.** N concurrent writes against M credits must give exactly M
#     successes and N-M refusals, with the balance landing on zero. No clock involved, so
#     this is exact today and only needed a driver that can count.
#   - **the rate limit, exactly.** Refill is `elapsed * rate` in whole seconds, so with a
#     running clock a burst that straddles a second boundary earns a token and one that does
#     not, does not. That is why `dataplane-check.sh` asserts a range. With the clock stopped
#     no token can accrue and the answer is exactly `burst` (D66).
#   - **`idempotency_in_progress`** exists only for the window between the loop admitting a
#     write and the worker finishing it, so no sequential request can ever see it.
#
# That last one is a scheduling outcome, and D53 governs how this project treats one: assert
# correctness unconditionally, and observe timing by retry with a bounded budget. So the
# partition of responses is checked on **every** attempt — exactly one write wins, and no
# attempt ever produces a `409 idempotency_key_reused` — while the appearance of
# `in_progress` is retried and fails only if the whole budget goes by without one.
#
# Usage: tools/exactness-check.sh [path-to-dataplane-binary]
set -uo pipefail

BIN="${1:-./zig-out/bin/dataplane}"
WORK="$(mktemp -d)"
PASS=0
FAIL=0
HARNESS_PID=""

# The harness's own fixtures. A real key is 190 bits from the CSPRNG (`06-auth.md`).
TRIAL="doot_live_harness_trial_0000000000"
RATE="doot_live_harness_rate_00000000000"
BROKE="doot_live_harness_broke_0000000000"
SCARCE="doot_live_harness_scarce_000000000"
PAID="doot_live_harness_paid_00000000000"

cleanup() {
  [ -n "$HARNESS_PID" ] && kill -KILL "$HARNESS_PID" 2>/dev/null
  wait "$HARNESS_PID" 2>/dev/null
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
has() {
  if printf '%s' "$3" | grep -qF -- "$2"; then pass "$1"; else fail "$1" "to contain: $2" "$(printf '%s' "$3" | head -c 300)"; fi
}
equals() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "$2" "$3"; fi
}
hdr() { printf '\n=== %s ===\n' "$1"; }

if [ ! -x "$BIN" ]; then
  echo "exactness-check: $BIN not found. Run 'zig build verify' first." >&2
  exit 1
fi

free_port() {
  python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}

# Starts a harness with the given flags in its own data directory and waits for it to serve.
# Any previous one is stopped first, so each section gets a clean subject.
start_harness() {
  local tag="$1"
  shift
  if [ -n "$HARNESS_PID" ]; then
    kill -KILL "$HARNESS_PID" 2>/dev/null
    wait "$HARNESS_PID" 2>/dev/null
    HARNESS_PID=""
  fi
  PORT="$(free_port)"
  BASE="http://127.0.0.1:$PORT"
  mkdir -p "$WORK/$tag"
  "$BIN" "127.0.0.1:$PORT" "$WORK/$tag" "$@" >"$WORK/$tag.log" 2>&1 &
  HARNESS_PID=$!
  local i
  for i in $(seq 1 100); do
    # `/healthz` answers 200 or 503 depending on the budget, and both mean "serving".
    if curl -sS -o /dev/null --max-time 2 "$BASE/healthz" 2>/dev/null; then return 0; fi
    kill -0 "$HARNESS_PID" 2>/dev/null || return 1
    sleep 0.1
  done
  return 1
}

# ---------------------------------------------------------------------------
hdr "capacity_exhausted — an index with no room left"
# ---------------------------------------------------------------------------

# 64 shards, a 20-byte slot and a 7/10 load ceiling: 1,280 bytes is one slot per shard, and
# one slot per shard is already over the ceiling. So admission is closed at boot with zero
# entries stored — no volume to generate and no race to lose. `--no-seed` because the
# fixtures are written through `Store.put`, which is exactly what a closed window refuses.
if start_harness cap --index-bytes=1280 --no-seed; then
  pass "a harness with a 1,280-byte index budget starts"
else
  fail "a harness with a 1,280-byte index budget starts" "a serving harness" "$(tail -3 "$WORK/cap.log")"
  printf '\nEXACTNESS CHECKS FAILED: %d passed, %d failed\n' "$PASS" "$FAIL"
  exit 1
fi

HEALTH="$(curl -sS -i --max-time 5 "$BASE/healthz")"
has "healthz reports the origin is full" "503 Service Unavailable" "$HEALTH"
has "and names the code" '"code":"capacity_exhausted"' "$HEALTH"
# The message is a promise to the caller, so it is asserted rather than assumed.
has "and says existing entries are still readable" "remain readable" "$HEALTH"

AUTH=(-H "Authorization: Bearer $TRIAL")
WRITE="$(curl -sS -i --max-time 5 -X PUT "${AUTH[@]}" -H 'X-Doot-TTL: 1h' \
  --data-binary 'x' "$BASE/v1/entries/cap/newname")"
has "a write to a new name is 503" "503 Service Unavailable" "$WRITE"
has "and names the same code" '"code":"capacity_exhausted"' "$WRITE"

# The operator's recovery path, and the reason admission closes on *new names* only: a full
# index must not stop anyone deleting from it.
equals "a read of a name that does not exist is still 404, not 503" "404" \
  "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "${AUTH[@]}" "$BASE/v1/entries/cap/nothing")"
equals "a delete is still served while the index is full" "404" \
  "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 -X DELETE "${AUTH[@]}" "$BASE/v1/entries/cap/nothing")"
equals "a listing is still served" "200" \
  "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "${AUTH[@]}" "$BASE/v1/entries?tag=ci")"
equals "and whoami still answers" "200" \
  "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "${AUTH[@]}" "$BASE/v1/whoami")"

# ---------------------------------------------------------------------------
hdr "credits are exact under concurrent load"
# ---------------------------------------------------------------------------

if start_harness credits --frozen-clock; then
  pass "a harness with a stopped clock starts"
else
  fail "a harness with a stopped clock starts" "a serving harness" "$(tail -3 "$WORK/credits.log")"
fi

# The `broke` fixture has zero credits, so it proves the floor holds under concurrency: not
# one of N simultaneous writes may succeed, and none may take the balance negative.
BROKE_OUT="$(python3 - "$PORT" "$BROKE" <<'PY'
import http.client, sys, threading, collections

port, key = int(sys.argv[1]), sys.argv[2]
codes = collections.Counter()
lock = threading.Lock()


def one(i):
    try:
        c = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
        c.request(
            "PUT", f"/v1/entries/broke/{i}", body=b"x",
            headers={"Authorization": f"Bearer {key}", "X-Doot-TTL": "1h"},
        )
        r = c.getresponse()
        body = r.read()
        with lock:
            codes[r.status] += 1
            if b'"code":"credits_exhausted"' in body:
                codes["named"] += 1
        c.close()
    except Exception as e:
        with lock:
            codes[f"err:{type(e).__name__}"] += 1


ts = [threading.Thread(target=one, args=(i,)) for i in range(24)]
for t in ts:
    t.start()
for t in ts:
    t.join()
print("created", codes[201])
print("refused", codes[402])
print("named", codes["named"])
print("other", sum(v for k, v in codes.items() if k not in (201, 402, "named")))
PY
)"
has "24 concurrent writes on an exhausted account create nothing" "created 0" "$BROKE_OUT"
has "and every one is refused" "refused 24" "$BROKE_OUT"
has "and every refusal names the code" "named 24" "$BROKE_OUT"
has "with no other outcome at all" "other 0" "$BROKE_OUT"

# The exact-partition case: an account whose balance is deliberately small, and more
# concurrent writes than it can pay for. This is the assertion the sequential check could not
# make. The expected numbers are derived from the balance the account reports rather than
# hardcoded, so the fixture's size can change without silently weakening the check.
EXACT="$(python3 - "$PORT" "$SCARCE" <<'PY'
import http.client, json, sys, threading, collections

port, key = int(sys.argv[1]), sys.argv[2]
hdrs = {"Authorization": f"Bearer {key}"}


def whoami():
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    c.request("GET", "/v1/whoami", headers=hdrs)
    d = json.loads(c.getresponse().read())
    c.close()
    return d["credits"]["remaining"]


before = whoami()
# Comfortably more attempts than credits, so the overspend is unambiguous.
attempts = before + 12
codes = collections.Counter()
lock = threading.Lock()


def one(i):
    try:
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=15)
        conn.request("PUT", f"/v1/entries/exact/{i}", body=b"x",
                     headers={**hdrs, "X-Doot-TTL": "1h"})
        r = conn.getresponse()
        r.read()
        with lock:
            codes[r.status] += 1
        conn.close()
    except Exception as e:
        with lock:
            codes[f"err:{type(e).__name__}"] += 1


ts = [threading.Thread(target=one, args=(i,)) for i in range(attempts)]
for t in ts:
    t.start()
for t in ts:
    t.join()

print("balance_before", before)
print("attempts", attempts)
print("created", codes[201])
print("refused", codes[402])
print("expected_created", before)
print("expected_refused", attempts - before)
print("balance_after", whoami())
print("other", sum(v for k, v in codes.items() if k not in (201, 402)))
PY
)"
E_CREATED="$(printf '%s' "$EXACT" | awk '/^expected_created /{print $2}')"
E_REFUSED="$(printf '%s' "$EXACT" | awk '/^expected_refused /{print $2}')"
G_CREATED="$(printf '%s' "$EXACT" | awk '/^created /{print $2}')"
G_REFUSED="$(printf '%s' "$EXACT" | awk '/^refused /{print $2}')"

equals "exactly the affordable writes are created, and no more" "$E_CREATED" "$G_CREATED"
equals "and exactly the unaffordable ones are refused" "$E_REFUSED" "$G_REFUSED"
has "leaving the balance at exactly zero" "balance_after 0" "$EXACT"
has "with no other outcome" "other 0" "$EXACT"
# The two failure modes this rules out, stated plainly: a lost deduction would show up as
# more creations than credits, and a double deduction as fewer.
printf '        %s\n' "$(printf '%s' "$EXACT" | tr '\n' ' ')"

# ---------------------------------------------------------------------------
hdr "the rate limit is exact when the clock cannot refill it"
# ---------------------------------------------------------------------------

# The `rate` fixture is a trial account with a full bucket of its own, so this starts from a
# known state rather than reasoning about what the checks above already spent. With the clock
# stopped, `elapsed` is pinned at zero, no token can accrue, and the answer is exactly the
# burst — the assertion `dataplane-check.sh` has to write as a range.
BURST="$(python3 - "$PORT" "$RATE" <<'PY'
import http.client, json, sys, threading, collections

port, key = int(sys.argv[1]), sys.argv[2]
hdrs = {"Authorization": f"Bearer {key}"}

c = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
c.request("GET", "/v1/whoami", headers=hdrs)
info = json.loads(c.getresponse().read())
c.close()
limit = info["rate_limit"]["limit"]
# whoami itself cost one token, so the bucket now holds limit-1.
remaining = info["rate_limit"]["remaining"]

attempts = limit + 40
codes = collections.Counter()
lock = threading.Lock()


def one(i):
    try:
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=15)
        conn.request("GET", "/v1/whoami", headers=hdrs)
        r = conn.getresponse()
        body = r.read()
        with lock:
            codes[r.status] += 1
            if r.status == 429:
                if r.getheader("Retry-After") is not None:
                    codes["retry_after"] += 1
                if b'"code":"rate_limited"' in body:
                    codes["named"] += 1
        conn.close()
    except Exception as e:
        with lock:
            codes[f"err:{type(e).__name__}"] += 1


ts = [threading.Thread(target=one, args=(i,)) for i in range(attempts)]
for t in ts:
    t.start()
for t in ts:
    t.join()

print("limit", limit)
print("attempts", attempts)
print("allowed", codes[200])
print("limited", codes[429])
print("expected_allowed", remaining)
print("expected_limited", attempts - remaining)
print("retry_after", codes["retry_after"])
print("named", codes["named"])
print("other", sum(v for k, v in codes.items() if k not in (200, 429, "retry_after", "named")))
PY
)"
ALLOWED="$(printf '%s' "$BURST" | awk '/^allowed /{print $2}')"
WANT_ALLOWED="$(printf '%s' "$BURST" | awk '/^expected_allowed /{print $2}')"
LIMITED="$(printf '%s' "$BURST" | awk '/^limited /{print $2}')"
WANT_LIMITED="$(printf '%s' "$BURST" | awk '/^expected_limited /{print $2}')"
LIMITED_NAMED="$(printf '%s' "$BURST" | awk '/^named /{print $2}')"
RETRY_N="$(printf '%s' "$BURST" | awk '/^retry_after /{print $2}')"

equals "exactly the tokens in the bucket are admitted, not a range" "$WANT_ALLOWED" "$ALLOWED"
equals "and exactly the rest are refused" "$WANT_LIMITED" "$LIMITED"
equals "every refusal names the code" "$WANT_LIMITED" "$LIMITED_NAMED"
equals "every refusal carries Retry-After" "$WANT_LIMITED" "$RETRY_N"
has "and nothing else happened" "other 0" "$BURST"

# Nothing accrued while all that was in flight, which is the property that makes the
# assertion above exact rather than lucky.
equals "a stopped clock refills nothing, so the bucket stays empty" "429" \
  "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 -H "Authorization: Bearer $RATE" "$BASE/v1/whoami")"

# ---------------------------------------------------------------------------
hdr "idempotency_in_progress — the window between admission and durability"
# ---------------------------------------------------------------------------

# D53: the correctness half is asserted on every attempt, and only the timing half is
# retried. Each round fires N concurrent writes carrying one Idempotency-Key and one body,
# on separate connections because a single connection is serialised by construction.
#
# Whatever the scheduler does, exactly one request may do the work; the others must be
# replays of it or be told it is still in flight. A `409 idempotency_key_reused` would mean
# the key was matched against a different body, which never happens here — so seeing one is
# a real failure, not a timing artifact.
if start_harness idem --frozen-clock; then
  pass "a harness for the idempotency race starts"
else
  fail "a harness for the idempotency race starts" "a serving harness" "$(tail -3 "$WORK/idem.log")"
fi

RACE="$(python3 - "$PORT" "$PAID" <<'PY'
import socket, sys, threading, collections

port, key = int(sys.argv[1]), sys.argv[2]

# A *small* body, deliberately. The first instinct is a large one, on the theory that a
# bigger write holds the reservation open for longer — but it delays the followers more than
# it delays the leader, because the loop has to read every one of their bodies off a socket
# before it can even call `begin`. By the time follower one is admitted the leader has long
# since finished. A small body gets all N admitted within microseconds of each other, while
# the leader is still waiting on an `fsync` that takes milliseconds.
body = b"z" * 64

# The paid fixture, for its larger bucket: this fires rounds x concurrency requests and the
# trial burst of 100 would start answering 429 partway through, which is a rate-limit
# artifact rather than anything to do with idempotency.
rounds = 8
concurrency = 24
saw_in_progress = False
report = []


def run_round(rnd):
    """Fires `concurrency` identical writes as simultaneously as the OS allows."""
    codes = collections.Counter()
    lock = threading.Lock()
    # Connect first, then release everyone at once. Without this the connect latency alone
    # spreads arrivals far enough to serialise them.
    socks = []
    for _ in range(concurrency):
        s = socket.create_connection(("127.0.0.1", port), timeout=30)
        s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        socks.append(s)

    request = (
        f"PUT /v1/entries/race/{rnd} HTTP/1.1\r\n"
        "Host: d\r\n"
        f"Authorization: Bearer {key}\r\n"
        "X-Doot-TTL: 1h\r\n"
        f"Idempotency-Key: race-{rnd}\r\n"
        "Content-Type: application/octet-stream\r\n"
        f"Content-Length: {len(body)}\r\n\r\n"
    ).encode() + body

    barrier = threading.Barrier(concurrency)

    def one(s):
        try:
            barrier.wait(timeout=20)
            s.sendall(request)
            buf = b""
            while b"\r\n\r\n" not in buf:
                chunk = s.recv(65536)
                if not chunk:
                    break
                buf += chunk
            head, _, rest = buf.partition(b"\r\n\r\n")
            status = int(head.split(b" ")[1]) if b" " in head else 0
            replayed = b"idempotency-replayed: true" in head.lower()
            with lock:
                if status in (200, 201) and replayed:
                    codes["replay"] += 1
                elif status == 201:
                    codes["created"] += 1
                elif b"idempotency_in_progress" in rest:
                    codes["in_progress"] += 1
                elif b"idempotency_key_reused" in rest:
                    codes["reused"] += 1
                else:
                    codes[f"other:{status}"] += 1
        except Exception as e:
            with lock:
                codes[f"err:{type(e).__name__}"] += 1

    ts = [threading.Thread(target=one, args=(s,)) for s in socks]
    for t in ts:
        t.start()
    for t in ts:
        t.join()
    for s in socks:
        try:
            s.close()
        except OSError:
            pass
    return codes


for rnd in range(rounds):
    codes = run_round(rnd)
    accounted = codes["created"] + codes["replay"] + codes["in_progress"]
    others = {k: v for k, v in codes.items() if isinstance(k, str)
              and k.startswith(("other:", "err:"))}
    report.append(
        f"round {rnd}: created={codes['created']} replay={codes['replay']} "
        f"in_progress={codes['in_progress']} reused={codes['reused']} "
        f"accounted={accounted}/{concurrency}"
        + (f" unexpected={others}" if others else "")
    )
    # Correctness, every round, unconditionally (D53). None of these three is allowed to
    # depend on how the scheduler behaved.
    if codes["created"] != 1:
        print("VERDICT created_not_one")
        break
    if codes["reused"] != 0:
        print("VERDICT saw_reused")
        break
    if accounted != concurrency:
        print("VERDICT unaccounted")
        break
    if codes["in_progress"]:
        saw_in_progress = True
        print("VERDICT ok")
        break
else:
    print("VERDICT never_observed")

print("\n".join(report))
PY
)"
VERDICT="$(printf '%s' "$RACE" | awk '/^VERDICT /{print $2}')"
case "$VERDICT" in
  ok)
    pass "exactly one write wins each round, and the rest replay or are told it is in flight"
    pass "409 idempotency_in_progress observed under concurrency"
    ;;
  never_observed)
    pass "exactly one write wins each round, and the rest replay or are told it is in flight"
    fail "409 idempotency_in_progress observed under concurrency" \
      "at least one in_progress across the retry budget" "$RACE"
    ;;
  *)
    fail "exactly one write wins each round, and the rest replay or are told it is in flight" \
      "one 201, no key_reused, every response accounted for" "$RACE"
    ;;
esac
printf '%s\n' "$RACE" | grep '^round ' | sed 's/^/        /'

hdr "summary"
if [ "$FAIL" -eq 0 ]; then
  printf '\nEXACTNESS CHECKS PASSED: %d passed, %d failed\n' "$PASS" "$FAIL"
  exit 0
fi
printf '\nEXACTNESS CHECKS FAILED: %d passed, %d failed\n' "$PASS" "$FAIL"
exit 1
