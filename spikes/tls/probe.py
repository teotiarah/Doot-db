#!/usr/bin/env python3
"""Independent TLS client for the Spike B server, using OpenSSL via python-ssl.

Stands in for Cloudflare: the point is that a mainstream, unrelated TLS
implementation completes the handshake against our Zig origin, verifies the
chain, and exchanges application data.

usage: probe.py <port> <ca.crt> [client.crt client.key]
"""

import socket
import ssl
import sys

port = int(sys.argv[1])
ca = sys.argv[2]
client_cert = sys.argv[3] if len(sys.argv) > 3 else None
client_key = sys.argv[4] if len(sys.argv) > 4 else None

ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
ctx.minimum_version = ssl.TLSVersion.TLSv1_3  # refuse anything below 1.3
ctx.load_verify_locations(cafile=ca)
ctx.check_hostname = True
ctx.verify_mode = ssl.CERT_REQUIRED
if client_cert:
    ctx.load_cert_chain(certfile=client_cert, keyfile=client_key)

with socket.create_connection(("127.0.0.1", port), timeout=15) as raw:
    with ctx.wrap_socket(raw, server_hostname="localhost") as s:
        print(f"  negotiated:   {s.version()}")
        print(f"  cipher:       {s.cipher()[0]}")
        peer = s.getpeercert()
        cn = dict(x[0] for x in peer["subject"])["commonName"]
        san = peer.get("subjectAltName", ())
        print(f"  peer cert CN: {cn}  SAN={san}")
        print("  chain verified against CA: yes (verify_mode=CERT_REQUIRED)")

        s.sendall(b"GET /spike HTTP/1.1\r\nHost: localhost\r\n\r\n")
        data = b""
        while b"\r\n\r\n" not in data:
            chunk = s.recv(4096)
            if not chunk:
                break
            data += chunk
        # Drain the body too.
        try:
            s.settimeout(2)
            while True:
                chunk = s.recv(4096)
                if not chunk:
                    break
                data += chunk
        except (socket.timeout, ssl.SSLError, OSError):
            pass

        head, _, body = data.partition(b"\r\n\r\n")
        status = head.split(b"\r\n")[0].decode()
        print(f"  response:     {status}")
        print(f"  body:         {body.decode(errors='replace').strip()!r}")

        assert s.version() == "TLSv1.3", f"expected TLS 1.3, got {s.version()}"
        assert status.endswith("200 OK"), f"bad status: {status}"
        print("  RESULT: PASS")
