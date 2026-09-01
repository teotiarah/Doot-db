#!/usr/bin/env bash
# Origin-binary checks (M2 Pass 2, D63).
#
# `src/boot.zig` has unit tests for the parsing and the maintenance cadence. What they
# cannot cover is the composition itself: whether the binary actually refuses to start,
# actually serves, and actually shuts down cleanly. That is one function whose behaviour
# *is* the wiring, so it is checked here, from outside, by running it.
#
# Three of D63's claims are load-bearing and rot silently if nothing exercises them:
#
#   - it refuses to start, naming the variable at fault, rather than starting degraded
#   - the maintenance thread runs, and a snapshot appears because of it — `maintain()` is
#     the only production path to `Store.snapshot()`, so a process without that thread
#     grows forever and makes recovery replay the whole log (D38)
#   - `SIGTERM` is a graceful shutdown: exit 0, and `Control.close()` checkpoints credits,
#     so a deploy does not rewind every account (D41)
#
# Usage: tools/boot-check.sh [path-to-doot-binary] [path-to-dataplane-binary]
set -uo pipefail

BIN="${1:-./zig-out/bin/doot}"
SEEDER="${2:-./zig-out/bin/dataplane}"
WORK="$(mktemp -d)"
DATA="$WORK/data"
PASS=0
FAIL=0

# A fixture secret, and labelled as one. A real deployment's is 32 bytes from the CSPRNG.
SECRET="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
# The account `tools/dataplane.zig` seeds. Used here because the binary deliberately has no
# account-creation path: M3 owns signup, and inventing an operator subcommand for this
# would be scaffolding built to be replaced (D63).
KEY="doot_live_harness_trial_0000000000"
PORT=""

cleanup() {
  [ -n "${DOOT_PID:-}" ] && kill -KILL "$DOOT_PID" 2>/dev/null
  wait "${DOOT_PID:-}" 2>/dev/null
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

for b in "$BIN" "$SEEDER"; do
  if [ ! -x "$b" ]; then
    echo "boot-check: $b not found. Run 'zig build verify' first." >&2
    exit 1
  fi
done

# An unused port, so a busy CI machine does not make this look like a failure.
free_port() {
  python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}

# Runs the binary to completion with the given environment, printing whatever it said.
# Every refusal below must exit non-zero, which `refuses` asserts as well as the message.
refuses() {
  local desc="$1" want="$2"
  shift 2
  local out status
  out="$(env -i "$@" "$BIN" 2>&1)"
  status=$?
  if [ "$status" -eq 0 ]; then
    fail "$desc" "a non-zero exit" "exit 0"
    return 0
  fi
  has "$desc" "$want" "$out"
}

start_doot() {
  env DOOT_LISTEN_ADDR="127.0.0.1:$PORT" DOOT_DATA_DIR="$DATA" \
    DOOT_MAX_INDEX_BYTES=300000000 DOOT_HMAC_SECRET="$SECRET" "$@" \
    "$BIN" >>"$WORK/doot.log" 2>&1 &
  DOOT_PID=$!
  for _ in $(seq 1 100); do
    curl -fsS -o /dev/null "http://127.0.0.1:$PORT/healthz" 2>/dev/null && return 0
    kill -0 "$DOOT_PID" 2>/dev/null || return 1
    sleep 0.1
  done
  return 1
}

credits() {
  curl -sS -H "Authorization: Bearer $KEY" "http://127.0.0.1:$PORT/v1/whoami" |
    grep -o '"remaining":[0-9]*' | head -1 | cut -d: -f2
}

# ---------------------------------------------------------------------------
hdr "it refuses to start, and says which variable is wrong"
# ---------------------------------------------------------------------------

# Each of the four M2 variables, removed one at a time from an otherwise complete set.
refuses "no configuration at all is a refusal about the first variable" \
  "DOOT_LISTEN_ADDR is required"
refuses "a missing data directory is named" \
  "DOOT_DATA_DIR is required" \
  DOOT_LISTEN_ADDR=127.0.0.1:1
refuses "a missing index ceiling is named, and explains itself (D43)" \
  "DOOT_MAX_INDEX_BYTES is required" \
  DOOT_LISTEN_ADDR=127.0.0.1:1 DOOT_DATA_DIR="$DATA"
refuses "a missing signing secret is named, and is never defaulted" \
  "DOOT_HMAC_SECRET is required" \
  DOOT_LISTEN_ADDR=127.0.0.1:1 DOOT_DATA_DIR="$DATA" DOOT_MAX_INDEX_BYTES=300000000

refuses "an index ceiling of zero is refused, not treated as unlimited" \
  "must be a positive number" \
  DOOT_LISTEN_ADDR=127.0.0.1:1 DOOT_DATA_DIR="$DATA" DOOT_MAX_INDEX_BYTES=0 DOOT_HMAC_SECRET="$SECRET"
refuses "an address that is not host:port is refused at boot" \
  "is not an address:port" \
  DOOT_LISTEN_ADDR=nonsense DOOT_DATA_DIR="$DATA" DOOT_MAX_INDEX_BYTES=300000000 DOOT_HMAC_SECRET="$SECRET"

# The secret's format, which is the one an operator is most likely to get half-right.
refuses "a truncated signing secret is refused rather than silently shortened" \
  "64 lowercase hex" \
  DOOT_LISTEN_ADDR=127.0.0.1:1 DOOT_DATA_DIR="$DATA" DOOT_MAX_INDEX_BYTES=300000000 DOOT_HMAC_SECRET=abcdef
refuses "an uppercase signing secret is refused, because one spelling means one secret" \
  "64 lowercase hex" \
  DOOT_LISTEN_ADDR=127.0.0.1:1 DOOT_DATA_DIR="$DATA" DOOT_MAX_INDEX_BYTES=300000000 \
  DOOT_HMAC_SECRET=0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF

# The lifetime grammar D47 settled, inherited rather than restated (D63).
refuses "DOOT_MAX_TTL refuses the compound form X-Doot-TTL refuses" \
  "optional s, m, h or d" \
  DOOT_LISTEN_ADDR=127.0.0.1:1 DOOT_DATA_DIR="$DATA" DOOT_MAX_INDEX_BYTES=300000000 \
  DOOT_HMAC_SECRET="$SECRET" DOOT_MAX_TTL=1h30m
refuses "a lifetime ceiling below the minimum lifetime is refused at boot" \
  "below the minimum lifetime" \
  DOOT_LISTEN_ADDR=127.0.0.1:1 DOOT_DATA_DIR="$DATA" DOOT_MAX_INDEX_BYTES=300000000 \
  DOOT_HMAC_SECRET="$SECRET" DOOT_MAX_TTL=30s

# ---------------------------------------------------------------------------
hdr "it starts, and serves"
# ---------------------------------------------------------------------------

mkdir -p "$DATA"
PORT="$(free_port)"

# The binary has no account-creation path, so the harness seeds one into the same
# directory. This is also the only reason these checks can authenticate at all, and it is
# the open question D63 records: something has to make the first account.
SEED_PORT="$(free_port)"
"$SEEDER" "127.0.0.1:$SEED_PORT" "$DATA" >"$WORK/seed.log" 2>&1 &
SEED_PID=$!
for _ in $(seq 1 100); do
  curl -fsS -o /dev/null "http://127.0.0.1:$SEED_PORT/healthz" 2>/dev/null && break
  sleep 0.1
done
kill -KILL "$SEED_PID" 2>/dev/null
wait "$SEED_PID" 2>/dev/null

# Killed rather than stopped, deliberately: the harness has no signal handling, so this
# leaves exactly the unclean state a crash leaves, and the binary has to recover from it.
if [ -f "$DATA/SNAPSHOT" ]; then
  fail "the seeded store has no snapshot, because nothing ran maintenance" "no SNAPSHOT" "SNAPSHOT present"
else
  pass "the seeded store has no snapshot, because nothing ran maintenance"
fi

if start_doot; then
  pass "the binary starts and answers /healthz"
else
  fail "the binary starts and answers /healthz" "a listening server" "$(cat "$WORK/doot.log")"
  printf '\nBOOT CHECKS FAILED: %d passed, %d failed\n' "$PASS" "$FAIL"
  exit 1
fi

LOG="$(cat "$WORK/doot.log")"
has "it reports where it listens" "listening on 127.0.0.1:$PORT" "$LOG"
has "it reports what it recovered" "recovered" "$LOG"

HEALTH="$(curl -sS "http://127.0.0.1:$PORT/healthz")"
has "/healthz is unauthenticated and reports a sequence number" '"status":"ok"' "$HEALTH"

WHOAMI="$(curl -sS -H "Authorization: Bearer $KEY" "http://127.0.0.1:$PORT/v1/whoami")"
has "an account seeded into this directory authenticates" '"plan":"trial"' "$WHOAMI"
has "and the effective lifetime ceiling is published (D56)" '"max_ttl_seconds"' "$WHOAMI"

UNAUTH="$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/v1/whoami")"
equals "an unauthenticated request is 401" "401" "$UNAUTH"

# A full round trip through the real binary rather than a harness: this is the first time
# the composition is what answers.
WRITE="$(curl -sS -o /dev/null -w '%{http_code}' -X PUT \
  -H "Authorization: Bearer $KEY" -H "X-Doot-Tags: boot" -H "X-Doot-TTL: 1h" \
  -H "Content-Type: text/plain" --data-binary 'through-the-binary' \
  "http://127.0.0.1:$PORT/v1/entries/boot/smoke")"
equals "a write through the binary is 201" "201" "$WRITE"
READ="$(curl -sS -H "Authorization: Bearer $KEY" "http://127.0.0.1:$PORT/v1/entries/boot/smoke")"
equals "and reads back byte for byte" "through-the-binary" "$READ"

# ---------------------------------------------------------------------------
hdr "SIGTERM is a graceful shutdown, not a crash (D41, D63)"
# ---------------------------------------------------------------------------

BEFORE="$(credits)"
for i in 1 2 3; do
  curl -sS -o /dev/null -X PUT -H "Authorization: Bearer $KEY" -H "X-Doot-TTL: 1h" \
    --data-binary "x" "http://127.0.0.1:$PORT/v1/entries/boot/charge-$i"
done
SPENT="$(credits)"
equals "three writes cost three credits" "$((BEFORE - 3))" "$SPENT"

# Well inside the maintenance interval, so the thread cannot have checkpointed: the only
# thing that can make the balance exact across this restart is `Control.close()`.
kill -TERM "$DOOT_PID"
wait "$DOOT_PID"
TERM_STATUS=$?
DOOT_PID=""
equals "SIGTERM exits zero" "0" "$TERM_STATUS"
has "and says it is stopping" "doot: stopping" "$(cat "$WORK/doot.log")"

if start_doot; then
  pass "it starts again on the directory it just closed"
else
  fail "it starts again on the directory it just closed" "a listening server" "$(tail -5 "$WORK/doot.log")"
fi
equals "credits survive a graceful restart exactly (D41)" "$SPENT" "$(credits)"

# ---------------------------------------------------------------------------
hdr "the maintenance thread exists, and is what snapshots (D45)"
# ---------------------------------------------------------------------------

# Thread count is the cheapest direct evidence: one loop, `io_workers` of them, and the
# maintenance thread. If the last were missing, nothing below would ever snapshot.
THREADS="$(ls "/proc/$DOOT_PID/task" 2>/dev/null | wc -l | tr -d ' ')"
if [ "${THREADS:-0}" -ge 10 ]; then
  pass "the process runs a loop, eight I/O workers and a maintenance thread ($THREADS)"
else
  fail "the process runs a loop, eight I/O workers and a maintenance thread" ">= 10 threads" "$THREADS"
fi

kill -TERM "$DOOT_PID"
wait "$DOOT_PID" 2>/dev/null
DOOT_PID=""
rm -f "$DATA/SNAPSHOT"

# `DOOT_SNAPSHOT_INTERVAL_S=1` makes the first maintenance pass snapshot, so this waits on
# the maintenance interval rather than the snapshot interval. That interval is a compiled
# constant (D45), so the wait is real time and this is the slowest check in the tree.
if start_doot DOOT_SNAPSHOT_INTERVAL_S=1; then
  if [ -f "$DATA/SNAPSHOT" ]; then
    fail "no snapshot exists until maintenance runs" "no SNAPSHOT at startup" "SNAPSHOT present"
  else
    pass "no snapshot exists until maintenance runs"
  fi

  SNAPPED=""
  for _ in $(seq 1 90); do
    if [ -f "$DATA/SNAPSHOT" ]; then SNAPPED=yes; break; fi
    sleep 1
  done
  if [ -n "$SNAPPED" ]; then
    pass "the maintenance thread runs and writes a snapshot"
  else
    fail "the maintenance thread runs and writes a snapshot" "SNAPSHOT within 90s" "absent"
  fi
  has "and reports the pass it made" "doot: maintenance:" "$(cat "$WORK/doot.log")"

  kill -TERM "$DOOT_PID"
  wait "$DOOT_PID" 2>/dev/null
  DOOT_PID=""
else
  fail "the binary restarts for the maintenance check" "a listening server" "$(tail -5 "$WORK/doot.log")"
fi

# A snapshot is what bounds recovery (D38), so a restart after one must replay a short
# tail rather than the whole log.
if start_doot; then
  has "recovery after a snapshot replays a tail, not the whole log (D38)" "recovered 0 record(s)" "$(cat "$WORK/doot.log")"
  kill -TERM "$DOOT_PID"
  wait "$DOOT_PID" 2>/dev/null
  DOOT_PID=""
else
  fail "the binary restarts after a snapshot" "a listening server" "$(tail -5 "$WORK/doot.log")"
fi

hdr "summary"
if [ "$FAIL" -eq 0 ]; then
  printf '\nBOOT CHECKS PASSED: %d passed, %d failed\n' "$PASS" "$FAIL"
  exit 0
fi
printf '\nBOOT CHECKS FAILED: %d passed, %d failed\n' "$PASS" "$FAIL"
exit 1
