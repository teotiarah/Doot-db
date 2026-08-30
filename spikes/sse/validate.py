#!/usr/bin/env python3
"""Open N SSE subscribers and validate every frame byte-for-byte.

Exists to catch a specific io_uring hazard: a buffer handed to send() must stay
unmodified until the completion arrives. A server that broadcasts from one shared
frame buffer and rewrites it on the next tick violates that, and the symptom is
torn frames — visible only under enough concurrent subscribers that sends are
still outstanding when the buffer is reused.

usage: validate.py <port> <subscribers> <seconds>
"""

import re
import select
import socket
import sys

port = int(sys.argv[1])
nsubs = int(sys.argv[2])
secs = float(sys.argv[3])

REQ = (f"GET /stream HTTP/1.1\r\nHost: localhost\r\n"
       f"Accept: text/event-stream\r\n\r\n").encode()

EVENT_RE = re.compile(r"^id: (\d+)\nevent: entry\ndata: \{\"seq\":(\d+),"
                      r"\"name\":\"spike/(\d+)\",\"op\":\"put\"\}$")
COMMENT_RE = re.compile(r"^: (stream open|heartbeat \d+)$")

socks, bufs = [], {}
for _ in range(nsubs):
    try:
        s = socket.create_connection(("127.0.0.1", port), timeout=10)
    except OSError:
        continue
    s.sendall(REQ)
    s.setblocking(False)
    socks.append(s)
    bufs[s.fileno()] = b""

print(f"  subscribers connected: {len(socks)}")

poller = select.poll()
for s in socks:
    poller.register(s, select.POLLIN)

total = torn = events = comments = 0
examples = []
deadline = __import__("time").monotonic() + secs
fd_to_sock = {s.fileno(): s for s in socks}

while __import__("time").monotonic() < deadline:
    for fd, _ev in poller.poll(200):
        s = fd_to_sock.get(fd)
        if s is None:
            continue
        try:
            chunk = s.recv(65536)
        except OSError:
            continue
        if not chunk:
            continue
        bufs[fd] += chunk
        # Strip the HTTP head once.
        if b"\r\n\r\n" in bufs[fd] and not bufs[fd].startswith(b":"):
            _, _, bufs[fd] = bufs[fd].partition(b"\r\n\r\n")
        while b"\n\n" in bufs[fd]:
            frame, _, bufs[fd] = bufs[fd].partition(b"\n\n")
            text = frame.decode(errors="replace")
            if not text:
                continue
            total += 1
            if COMMENT_RE.match(text):
                comments += 1
                continue
            m = EVENT_RE.match(text)
            if m and m.group(1) == m.group(2) == m.group(3):
                events += 1
                continue
            torn += 1
            if len(examples) < 5:
                examples.append(text[:100])

for s in socks:
    s.close()

print(f"  frames validated: {total}  (events={events} comments={comments})")
print(f"  TORN/MALFORMED:   {torn}")
for e in examples:
    print(f"    !! {e!r}")

if torn:
    print("\nVERDICT: FAIL — frames corrupted (shared send buffer reused while in flight)")
    sys.exit(1)
print("\nVERDICT: PASS — every frame well-formed")
sys.exit(0)
