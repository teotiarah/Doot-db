#!/usr/bin/env python3
"""Decide whether an SSE endpoint genuinely streams or is being buffered.

Buffering is invisible to a naive client: the events all arrive, just late and
in one burst. So this timestamps every frame as it arrives and judges on the
timing, not the content.

Works against a local origin or through a proxy/CDN, so the same command is the
verification procedure once doot.run is live:

    sseprobe.py http://127.0.0.1:9600/stream --expect-interval 250
    sseprobe.py https://doot.run/app/stream --expect-interval 250 --header "Cookie: ..."

Exit code 0 = streaming, 1 = buffered or broken.
"""

import argparse
import socket
import ssl
import sys
import time
from urllib.parse import urlparse

ap = argparse.ArgumentParser()
ap.add_argument("url")
ap.add_argument("--expect-interval", type=float, default=250.0,
                help="ms between events the server claims to emit")
ap.add_argument("--events", type=int, default=6, help="how many data frames to collect")
ap.add_argument("--timeout", type=float, default=30.0)
ap.add_argument("--header", action="append", default=[], help="extra request header")
ap.add_argument("--ca", help="CA bundle for https")
args = ap.parse_args()

u = urlparse(args.url)
host = u.hostname
port = u.port or (443 if u.scheme == "https" else 80)
path = u.path or "/"
if u.query:
    path += "?" + u.query

req = [f"GET {path} HTTP/1.1", f"Host: {host}", "Accept: text/event-stream",
       "Cache-Control: no-cache", "Connection: keep-alive"]
req += args.header
head = ("\r\n".join(req) + "\r\n\r\n").encode()

print(f"probing {args.url}")
raw = socket.create_connection((host, port), timeout=args.timeout)
if u.scheme == "https":
    ctx = ssl.create_default_context(cafile=args.ca)
    sock = ctx.wrap_socket(raw, server_hostname=host)
    print(f"  tls: {sock.version()}")
else:
    sock = raw
sock.settimeout(args.timeout)

t0 = time.monotonic()
sock.sendall(head)

buf = b""
header_done_at = None
resp_headers = b""
arrivals = []          # (elapsed_ms, kind, first_line)

deadline = t0 + args.timeout
while time.monotonic() < deadline:
    try:
        chunk = sock.recv(4096)
    except socket.timeout:
        break
    if not chunk:
        break
    now_ms = (time.monotonic() - t0) * 1000
    buf += chunk

    if header_done_at is None and b"\r\n\r\n" in buf:
        resp_headers, _, buf = buf.partition(b"\r\n\r\n")
        header_done_at = now_ms

    if header_done_at is None:
        continue

    # SSE frames are separated by a blank line.
    while b"\n\n" in buf:
        frame, _, buf = buf.partition(b"\n\n")
        text = frame.decode(errors="replace").strip()
        if not text:
            continue
        kind = "comment" if text.startswith(":") else "event"
        arrivals.append((now_ms, kind, text.splitlines()[0][:60]))

    if sum(1 for a in arrivals if a[1] == "event") >= args.events:
        break

sock.close()

status = resp_headers.split(b"\r\n")[0].decode(errors="replace") if resp_headers else "(none)"
hdrs = {}
for line in resp_headers.split(b"\r\n")[1:]:
    if b":" in line:
        k, _, v = line.partition(b":")
        hdrs[k.decode().strip().lower()] = v.decode().strip()

print(f"  status: {status}")
print(f"  time to headers: {header_done_at:.0f} ms" if header_done_at else "  NO HEADERS")
for k in ("content-type", "cache-control", "transfer-encoding", "content-encoding",
          "content-length", "connection", "cf-cache-status", "server", "via"):
    if k in hdrs:
        print(f"  {k}: {hdrs[k]}")

print(f"  frames: {len(arrivals)} ({sum(1 for a in arrivals if a[1]=='event')} events, "
      f"{sum(1 for a in arrivals if a[1]=='comment')} comments)")
for ms, kind, line in arrivals[:12]:
    print(f"    +{ms:7.0f} ms  {kind:8} {line}")

# ---- verdict -------------------------------------------------------------
events = [a for a in arrivals if a[1] == "event"]
problems = []

if not status.endswith("200 OK"):
    problems.append(f"status was {status!r}, not 200")
if hdrs.get("content-type", "").split(";")[0] != "text/event-stream":
    problems.append(f"content-type is {hdrs.get('content-type')!r}")
if "content-length" in hdrs:
    problems.append("Content-Length present: the response is not open-ended")
if hdrs.get("content-encoding"):
    problems.append(f"content-encoding {hdrs['content-encoding']!r} may force buffering")
if len(events) < 2:
    problems.append(f"only {len(events)} event(s) arrived; cannot judge streaming")

if len(events) >= 2:
    spread = events[-1][0] - events[0][0]
    gaps = [events[i + 1][0] - events[i][0] for i in range(len(events) - 1)]
    mean_gap = sum(gaps) / len(gaps)
    print(f"  first event at +{events[0][0]:.0f} ms, last at +{events[-1][0]:.0f} ms")
    print(f"  mean inter-event gap: {mean_gap:.0f} ms (server emits every {args.expect_interval:.0f} ms)")

    # A buffering proxy collapses the gaps: everything lands at once.
    if spread < args.expect_interval:
        problems.append(
            f"all {len(events)} events arrived within {spread:.0f} ms "
            f"(< one {args.expect_interval:.0f} ms interval) — this is BUFFERED")
    # Or it delays the whole stream while it accumulates.
    if events[0][0] > args.expect_interval * 4:
        problems.append(
            f"first event took {events[0][0]:.0f} ms, more than 4 intervals — "
            f"suggests upstream accumulation")
    if mean_gap < args.expect_interval * 0.4:
        problems.append(f"mean gap {mean_gap:.0f} ms far below emit interval — batched delivery")

print()
if problems:
    print("VERDICT: FAIL")
    for p in problems:
        print(f"  - {p}")
    sys.exit(1)

print("VERDICT: PASS — response is open-ended and events arrive incrementally")
sys.exit(0)
