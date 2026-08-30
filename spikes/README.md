# M0 spikes — disposable

Throwaway code written to retire the three unknowns in `docs/08-roadmap.md` M0.
**None of it survives into the product.** The findings live in
`docs/07-decisions.md`; this directory is the evidence, and it is deleted at M1.

Only sources are tracked. Binaries, run logs and generated key material are
gitignored — regenerate with the commands below.

Requires the pinned toolchain: `toolchain/setup.sh`.

## Results

| spike | question | verdict |
|---|---|---|
| `gate/` | does io_uring work here at all | **pass**, after a stdlib patch (D26) |
| `uring/` | io_uring throughput and idle-connection cost | **pass**, but not via `std.Io` (D27, D28) |
| `tls/` | TLS 1.3 at the origin from a vendored library | **pass** in full (D29) |
| `sse/` | does SSE stream, and is it cheap | **pass** on our side; found a real bug (D30) and a real edge risk (D31) |

## `gate/` — io_uring availability

```bash
cd spikes/gate
zig build-exe gate.zig -O ReleaseFast && ./gate
```

Proves `io_uring_setup` succeeds in the target environment and that the ring
completes real operations. `minimal.zig` is the 8-line reproducer for the Zig
0.16.0 stdlib compile failure described in D26 — it fails to build against an
unpatched toolchain, which is the point.

## `uring/` — throughput and idle-connection memory

```bash
cd spikes/uring
zig build-exe ringserver.zig -O ReleaseFast
zig build-exe idler.zig     -O ReleaseFast
zig build-exe bencher.zig   -O ReleaseFast
zig build-exe server.zig    -O ReleaseFast   # std.Io comparison

# throughput
./ringserver 9810 8192 &
./bencher 9810 8 128 4

# idle-connection cost, naive vs pooled
./ringserver 9811 2048 page &   ; ./idler 9811 10000 12
./ringserver 9812 2048 slab &   ; ./idler 9812 10000 12

# why std.Io.Threaded is unusable: wedges after 7 connections
./server threaded 9805 8192 &   ; ./idler 9805 12 2
```

- `ringserver.zig` — the real one. Multishot accept, per-connection recv/send,
  `TCP_NODELAY`, `SO_REUSEPORT`, repeating timeout SQE. `page`/`slab` modes
  compare naive against pooled allocation.
- `idler.zig` — opens N keep-alive connections sequentially and holds them idle.
  Sequential and blocking on purpose: it measures the *server's* cost of doing
  nothing.
- `bencher.zig` — pipelined throughput. Client and server share the same cores,
  so results are a floor.
- `server.zig` — `std.Io` version, `uring|threaded` backend argument. Retained
  only as the reproducer for D27.
- `client.zig` — `std.Io` load generator. **Does not work**, because
  `std.Io.Uring` has no `netConnectIp`. Retained as evidence for D27.

## `tls/` — origin TLS 1.3

```bash
cd spikes/tls
pip install cryptography && python3 gencert.py    # throwaway CA + server + client certs
zig build -Doptimize=ReleaseFast

# plain TLS 1.3, EC and RSA chains
./zig-out/bin/tlsserver 9443 cert/server_ec.crt cert/server_ec.key &
python3 probe.py 9443 cert/ca_ec.crt

# mTLS (Authenticated Origin Pulls). Second call must FAIL: no client cert.
./zig-out/bin/tlsserver 9445 cert/server_ec.crt cert/server_ec.key cert/ca_ec.crt &
python3 probe.py 9445 cert/ca_ec.crt cert/client_ec.crt cert/client_ec.key
python3 probe.py 9445 cert/ca_ec.crt

# TLS on the raw io_uring loop — the actual production shape
./zig-out/bin/nonblock 9450 cert/server_ec.crt cert/server_ec.key &
python3 probe.py 9450 cert/ca_ec.crt
```

`probe.py` is an independent OpenSSL-backed client that forces TLS 1.3, verifies
the chain and checks the hostname. The point of using it rather than another Zig
program is that it shares no code with the thing under test.

The generated CA stands in for a Cloudflare Origin CA certificate: same shape, a
leaf signed by a CA the peer is configured to trust.

## `sse/` — streaming and its cost

```bash
cd spikes/sse
zig build-exe sseserver.zig -O ReleaseFast
./sseserver 9600 250 15000 &      # port, event interval ms, heartbeat ms

# does it stream, or is something buffering it?
python3 sseprobe.py http://127.0.0.1:9600/stream --expect-interval 250

# frame integrity under concurrency — this is what caught D30
python3 validate.py 9600 2000 4
```

- `sseprobe.py` — judges streaming on **timing**, not content, because buffering
  is invisible otherwise: the events still all arrive, just late and at once.
  Takes any URL including `https://`, so **this is the verification procedure to
  run against `doot.run` once the zone is live** (D31).
- `validate.py` — opens N subscribers and validates every frame byte-for-byte.
  Written specifically to expose the io_uring send-buffer hazard in D30, which is
  invisible below roughly 50 concurrent subscribers.

## Not proven here

Everything about Cloudflare's actual behaviour. The zone, the domain and a
publicly reachable origin are all required, and none exist yet. D31 records what
must be configured and what must be measured; `sseprobe.py` is the measurement.
