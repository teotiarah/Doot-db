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

**This must pass against the real zone before M4 builds the live view on the assumption
that streaming works.** It is part of M2's exit condition. If it cannot be made to pass
after the D31 configuration is applied, the live view falls back to long-polling — and that
call gets made at M2, not discovered at the end of the most user-visible milestone.

## Arriving in M2

The Cloudflare zone configuration D31 requires as code rather than console clicks: response
body buffering off on the stream path, compression off on the same path, cache bypass on
`/v1/*`, `Full (strict)`, Authenticated Origin Pulls, and an origin firewall restricted to
Cloudflare ranges. It gets written when there is a real zone to write it against.
