#!/usr/bin/env bash
# Transport checks against a client we did not write (M2 Pass 2, slice 1).
#
# `src/server/loop.zig` already drives the loop over a real socket, but with a client
# built alongside it — so both sides can share a misunderstanding and still agree. These
# checks use `curl`, which decides for itself whether a response is well framed, whether
# a connection may be reused, and whether `Expect: 100-continue` was answered.
#
# A few cases are framing-level and `curl` cannot produce them at all: it always sends a
# `Content-Length`, and it will not pipeline. Those use raw sockets through python.
#
# Usage: tools/transport-check.sh [path-to-transport-binary]
set -uo pipefail

BIN="${1:-./zig-out/bin/transport}"
WORK="$(mktemp -d)"
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

# Asserts that $3 contains $2.
has() {
  if printf '%s' "$3" | grep -qF -- "$2"; then pass "$1"; else fail "$1" "to contain: $2" "$(printf '%s' "$3" | head -c 400)"; fi
}
lacks() {
  if printf '%s' "$3" | grep -qF -- "$2"; then fail "$1" "not to contain: $2" "$(printf '%s' "$3" | head -c 400)"; else pass "$1"; fi
}
equals() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "$2" "$3"; fi
}

# Byte-for-byte file comparison. `cmp` and `diff` are absent from some minimal images,
# and `sha256sum` is already required by toolchain/setup.sh.
digest() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }
same_bytes() {
  local desc="$1" a="$2" b="$3"
  local da db
  da="$(digest "$a")"
  db="$(digest "$b")"
  if [ -n "$da" ] && [ "$da" = "$db" ]; then
    pass "$desc"
  else
    fail "$desc" "$(wc -c <"$a" | tr -d ' ') bytes, $da" \
      "$(wc -c <"$b" 2>/dev/null | tr -d ' ' || echo 0) bytes, ${db:-(missing)}"
  fi
}

hdr() { printf '\n=== %s ===\n' "$1"; }

if [ ! -x "$BIN" ]; then
  echo "transport-check: $BIN not found. Run 'zig build verify' first." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Start the harness on an ephemeral port
# ---------------------------------------------------------------------------

"$BIN" 127.0.0.1:0 >"$WORK/out.log" 2>&1 &
SERVER_PID=$!

PORT=""
for _ in $(seq 1 100); do
  PORT="$(sed -n 's/.*listening 127\.0\.0\.1:\([0-9]*\).*/\1/p' "$WORK/out.log" 2>/dev/null | head -1)"
  [ -n "$PORT" ] && break
  sleep 0.05
done

if [ -z "$PORT" ]; then
  echo "transport-check: harness never reported a port" >&2
  cat "$WORK/out.log" >&2
  exit 1
fi

BASE="http://127.0.0.1:$PORT"
echo "transport-check: harness on $BASE (pid $SERVER_PID)"

CURL="curl -sS --max-time 10"

# ---------------------------------------------------------------------------

hdr "framing and the headers the transport owns"

RESP="$($CURL -i "$BASE/fixed")"
has "a 200 status line" "HTTP/1.1 200 OK" "$RESP"
has "Content-Length is present" "Content-Length: 3" "$RESP"
has "keep-alive by default on 1.1" "Connection: keep-alive" "$RESP"
has "the handler's own header survives" "Content-Type: text/plain" "$RESP"
# RFC 9110 requires Date from an origin server with a clock.
if printf '%s' "$RESP" | grep -qE '^Date: [A-Z][a-z]{2}, [0-9]{2} [A-Z][a-z]{2} [0-9]{4} [0-9]{2}:[0-9]{2}:[0-9]{2} GMT'; then
  pass "Date is a well-formed IMF-fixdate"
else
  fail "Date is a well-formed IMF-fixdate" "Date: Www, DD Mmm YYYY HH:MM:SS GMT" "$(printf '%s' "$RESP" | grep -i '^Date:' || echo '(absent)')"
fi

equals "the body is exactly what the handler set" "ok" "$($CURL "$BASE/fixed")"

RESP="$($CURL -i "$BASE/empty")"
has "an empty body still declares its length" "Content-Length: 0" "$RESP"

# ---------------------------------------------------------------------------

hdr "keep-alive, as a real client sees it"

# Two URLs in one invocation. `num_connects` is curl's own count of *new* TCP
# connections, so a 0 on the second request is curl stating that it reused the first —
# a fact rather than a phrase in its verbose output.
CONNECTS="$($CURL -o /dev/null -o /dev/null -w '%{num_connects}\n' "$BASE/fixed" "$BASE/fixed")"
equals "curl opens one connection and reuses it" "1 0" "$(printf '%s' "$CONNECTS" | tr '\n' ' ' | sed 's/ $//')"

# Ten requests down one connection, all answered.
COUNT="$($CURL -o /dev/null -w '%{http_code}\n' \
  "$BASE/fixed" "$BASE/fixed" "$BASE/fixed" "$BASE/fixed" "$BASE/fixed" \
  "$BASE/fixed" "$BASE/fixed" "$BASE/fixed" "$BASE/fixed" "$BASE/fixed" \
  2>/dev/null | grep -c '^200$')"
equals "ten requests on one connection all return 200" "10" "$COUNT"

RESP="$($CURL -i --http1.0 "$BASE/fixed")"
has "an HTTP/1.0 client is told the connection closes" "Connection: close" "$RESP"

RESP="$($CURL -i -H 'Connection: close' "$BASE/fixed")"
has "a client asking to close is obeyed" "Connection: close" "$RESP"

RESP="$($CURL -i "$BASE/goodbye")"
has "the handler can ask to close" "Connection: close" "$RESP"

# ---------------------------------------------------------------------------

hdr "methods, targets and the error catalogue"

equals "the method reaches the handler" "DELETE" "$($CURL -X DELETE "$BASE/method")"
equals "the query string reaches the handler" "tag=ci&limit=10" "$($CURL "$BASE/query?tag=ci&limit=10")"

RESP="$($CURL -i "$BASE/missing")"
has "a handler error is the catalogue status" "HTTP/1.1 404 Not Found" "$RESP"
has "a handler error is JSON" "Content-Type: application/json" "$RESP"
has "a handler error carries a stable code" '"code":"not_found"' "$RESP"
has "a handler error links its docs" '"docs":"https://doot.run/docs/errors#not_found"' "$RESP"
lacks "a handler error does not end the connection" "Connection: close" "$RESP"

RESP="$($CURL -i "$BASE/limited")"
has "429 carries Retry-After" "Retry-After: 34" "$RESP"

RESP="$($CURL -i -X POST --data-binary '' "$BASE/created")"
has "a 201 keeps its own status" "HTTP/1.1 201 Created" "$RESP"
has "a 201 carries Location" "Location: /v1/entries/01JBQ2K9XW4V7N8M3PZR6TYAC5" "$RESP"

# ---------------------------------------------------------------------------

hdr "bodies in both directions"

# 256 KB, the published ceiling, byte for byte.
head -c 262144 /dev/urandom >"$WORK/in.bin"
$CURL -X PUT --data-binary "@$WORK/in.bin" -o "$WORK/out.bin" "$BASE/echo"
same_bytes "a 256 KB body round-trips byte for byte" "$WORK/in.bin" "$WORK/out.bin"

# A response larger than one socket buffer.
$CURL -o "$WORK/big.bin" "$BASE/big?n=200000"
equals "a 200 KB response arrives whole" "200000" "$(wc -c <"$WORK/big.bin" | tr -d ' ')"
equals "a 200 KB response is not corrupted" "ABCDEFGHIJKLMNOPQRSTUVWXYZ" "$(head -c 26 "$WORK/big.bin")"

# Expect: 100-continue. curl sends it for bodies over 1 KB and waits a full second
# when it is ignored, so the timing *is* the assertion.
head -c 4096 /dev/urandom >"$WORK/expect.bin"
ELAPSED="$($CURL -o /dev/null -w '%{time_total}' -X PUT \
  -H 'Expect: 100-continue' --data-binary "@$WORK/expect.bin" "$BASE/echo")"
if awk -v t="$ELAPSED" 'BEGIN { exit !(t < 0.5) }'; then
  pass "Expect: 100-continue is answered (${ELAPSED}s, no 1s stall)"
else
  fail "Expect: 100-continue is answered" "under 0.5s" "${ELAPSED}s — curl waited for an interim response"
fi

# And the body still arrives intact through that path.
$CURL -X PUT -H 'Expect: 100-continue' --data-binary "@$WORK/expect.bin" \
  -o "$WORK/expect.out" "$BASE/echo"
same_bytes "a body sent after 100-continue is intact" "$WORK/expect.bin" "$WORK/expect.out"

# ---------------------------------------------------------------------------

hdr "refusals"

# One byte over the ceiling. The server answers from Content-Length and closes, so curl
# may fail to finish writing — the response is what matters, not curl's exit code.
head -c 262145 /dev/urandom >"$WORK/over.bin"
RESP="$($CURL -i -X PUT --data-binary "@$WORK/over.bin" "$BASE/echo" 2>/dev/null)"
has "an oversized body is 413" "HTTP/1.1 413 Content Too Large" "$RESP"
has "an oversized body names the code" '"code":"body_too_large"' "$RESP"
has "an oversized body ends the connection" "Connection: close" "$RESP"

# A header block past the 8 KB ceiling.
BIG_HEADER="$(head -c 9000 /dev/zero | tr '\0' 'a')"
RESP="$($CURL -i -H "X-Big: $BIG_HEADER" "$BASE/fixed" 2>/dev/null)"
has "an oversized head is 431" "431 Request Header Fields Too Large" "$RESP"

# A head over the inline buffer but under the ceiling is ordinary traffic.
MID_HEADER="$(head -c 2000 /dev/zero | tr '\0' 'p')"
RESP="$($CURL -i -H "X-Pad: $MID_HEADER" "$BASE/fixed" 2>/dev/null)"
has "a head larger than the inline buffer still succeeds" "HTTP/1.1 200 OK" "$RESP"

# ---------------------------------------------------------------------------

hdr "framing cases curl cannot produce"

# curl always sends Content-Length and will not pipeline, so these go over a raw socket.
RAW="$(python3 - "$PORT" <<'PY'
import socket, sys, time

port = int(sys.argv[1])

def talk(payload, read_all=True, wait=0.4):
    s = socket.create_connection(("127.0.0.1", port), timeout=5)
    s.sendall(payload)
    time.sleep(wait)
    chunks = []
    s.settimeout(2)
    try:
        while True:
            b = s.recv(65536)
            if not b:
                break
            chunks.append(b)
            if not read_all:
                break
    except socket.timeout:
        pass
    s.close()
    return b"".join(chunks)

# A write with no Content-Length: 411, because we cannot find where it ends.
r = talk(b"PUT /echo HTTP/1.1\r\nHost: d\r\n\r\n")
print("411:", b"411 Length Required" in r and b"length_required" in r)

# Chunked, which v1 does not implement: also 411.
r = talk(b"PUT /echo HTTP/1.1\r\nHost: d\r\nTransfer-Encoding: chunked\r\n\r\n")
print("chunked411:", b"411 Length Required" in r)

# Three requests in one write, answered in order.
r = talk(
    b"GET /method HTTP/1.1\r\nHost: d\r\n\r\n"
    b"DELETE /method HTTP/1.1\r\nHost: d\r\n\r\n"
    b"GET /query?tag=ci HTTP/1.1\r\nHost: d\r\n\r\n"
)
bodies = [p.split(b"\r\n\r\n", 1)[1] for p in r.split(b"HTTP/1.1 200 OK\r\n")[1:]]
print("pipelined:", r.count(b"HTTP/1.1 200 OK") == 3 and bodies == [b"GET", b"DELETE", b"tag=ci"])

# Both framings at once is the canonical smuggling setup.
r = talk(b"PUT /echo HTTP/1.1\r\nHost: d\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\nhello")
print("smuggle400:", b"400 Bad Request" in r and b"invalid_request" in r)

# Whitespace before the colon, the classic desync trick.
r = talk(b"GET /fixed HTTP/1.1\r\nHost : d\r\n\r\n")
print("spacecolon400:", b"400 Bad Request" in r)

# Missing Host on 1.1.
r = talk(b"GET /fixed HTTP/1.1\r\n\r\n")
print("nohost400:", b"400 Bad Request" in r)

# A version the origin does not speak.
r = talk(b"GET /fixed HTTP/2.0\r\nHost: d\r\n\r\n")
print("badversion400:", b"400 Bad Request" in r)

# One byte at a time is still one request.
s = socket.create_connection(("127.0.0.1", port), timeout=5)
for byte in b"PUT /echo HTTP/1.1\r\nHost: d\r\nContent-Length: 3\r\n\r\nabc":
    s.sendall(bytes([byte]))
    time.sleep(0.001)
time.sleep(0.3)
r = s.recv(65536)
s.close()
print("dribble:", r.endswith(b"abc") and r.count(b"HTTP/1.1") == 1)

# A peer that vanishes mid-head costs the server nothing: it still serves afterwards.
for _ in range(16):
    s = socket.create_connection(("127.0.0.1", port), timeout=5)
    s.sendall(b"PUT /echo HTTP/1.1\r\nHost: d\r\nContent-Len")
    s.close()
time.sleep(0.2)
r = talk(b"GET /fixed HTTP/1.1\r\nHost: d\r\n\r\n")
print("survives_abandon:", b"200 OK" in r)
PY
)"

for case in \
  "411:a write without Content-Length is 411" \
  "chunked411:chunked is refused as 411" \
  "pipelined:pipelined requests are answered in order" \
  "smuggle400:Content-Length with Transfer-Encoding is 400" \
  "spacecolon400:whitespace before a header colon is 400" \
  "nohost400:HTTP/1.1 without Host is 400" \
  "badversion400:an unsupported version is 400" \
  "dribble:a request arriving one byte at a time is one request" \
  "survives_abandon:abandoned connections leak nothing"; do
  key="${case%%:*}"
  desc="${case#*:}"
  if printf '%s' "$RAW" | grep -q "^${key}: True$"; then pass "$desc"; else fail "$desc" "True" "$(printf '%s' "$RAW" | grep "^${key}:" || echo '(no result)')"; fi
done

# ---------------------------------------------------------------------------

hdr "concurrency"

CONC=64
seq 1 "$CONC" | xargs -P "$CONC" -I{} curl -sS --max-time 10 -o /dev/null \
  -w '%{http_code}\n' "$BASE/fixed" >"$WORK/conc.txt" 2>/dev/null
equals "$CONC simultaneous connections all return 200" "$CONC" "$(grep -c '^200$' "$WORK/conc.txt")"

# Still healthy afterwards, which is what proves the pools were handed back.
equals "the server is still serving after the burst" "200" \
  "$($CURL -o /dev/null -w '%{http_code}' "$BASE/fixed")"

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
  "$([ "$FAIL" -eq 0 ] && echo 'TRANSPORT CHECKS PASSED' || echo 'TRANSPORT CHECKS FAILED')" \
  "$PASS" "$FAIL"

[ "$FAIL" -eq 0 ]
