# ops — deployment artifacts

Permanent. This directory replaces the one part of `spikes/` worth keeping when that
directory was deleted at M1 (`docs/07-decisions.md` D49).

## `sseprobe.py`

The verification procedure for D31: **does Cloudflare stream `text/event-stream`, or buffer
it?**

It judges streaming on arrival *timing* rather than content, because buffering is otherwise
invisible — a buffering proxy still delivers every event, just late and all at once. It
takes any URL including `https://`, flags a `Content-Length` or `Content-Encoding` that
would indicate buffering, and exits non-zero when buffered.

```bash
python3 ops/sseprobe.py https://doot.run/app/stream --expect-interval 250
```

**It already passes against the origin over loopback**, which is what proves our side is
correct: `tools/app-check.sh` runs exactly this probe against `GET /app/stream` on every push,
and CI would go red if the endpoint ever stopped streaming.

What remains is the run **through the real zone**, which needs a publicly reachable origin and
is scheduled with M5's deployment work (D68). The fallback is no longer a decision that waits on
it: both framings ship on one path and the client chooses (D87), so a buffering intermediary
costs the users behind it latency rather than costing everyone the feature.

## Arriving in M2

The Cloudflare zone configuration D31 requires as code rather than console clicks: response
body buffering off on the stream path, compression off on the same path, cache bypass on
`/v1/*`, `Full (strict)`, Authenticated Origin Pulls, and an origin firewall restricted to
Cloudflare ranges. It gets written when there is a real zone to write it against.
