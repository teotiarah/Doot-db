# Working docs — transient by design

Everything in `docs/` is **development-time working material**. It exists to settle
decisions and keep the build honest against them. It is not the spec of record and
it is not user-facing.

**Lifecycle:** at v1-beta these files are collapsed into a single `REFERENCE.md` at
the repository root and this directory is deleted. Do not link to these files from
anywhere durable.

## Reading order

| file | what it settles |
|---|---|
| `00-vision.md` | what Doot is, who it's for, what it refuses to be |
| `01-product.md` | tiers, limits, credits, rate limits, beta behaviour |
| `02-api.md` | the seven endpoints, in full |
| `03-data-model.md` | entries, names, tags, lifetime semantics |
| `04-storage.md` | the storage engine — segments, index, recovery, backup |
| `05-architecture.md` | process model, network path, TLS, dashboard delivery |
| `06-auth.md` | accounts, API keys, sessions |
| `07-decisions.md` | ADR log — every locked call and every rejected alternative |
| `08-roadmap.md` | milestones to first public deploy |

## Working rules

1. **No implementation while a decision is open.** Decisions land in `07-decisions.md`
   first, code second. A design question is never settled inside an implementation
   diff.
2. **Constants live in one place.** Every limit, size and interval is defined in
   `01-product.md` (user-visible) or `04-storage.md` (internal). Other docs reference,
   never restate.
3. **Vocabulary is enforced.** See `00-vision.md`. The words "key" and "value" do not
   appear in code identifiers, endpoints, error messages, docs or UI copy.
