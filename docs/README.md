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

`07-decisions.md` is grouped by the milestone that produced each decision:

| section | decisions | what produced them |
|---|---|---|
| initial | D1–D25 | settling the project's shape, before any code |
| **M0 findings** | D26–D31 | what the validation spikes measured, including three places where a spike contradicted an earlier decision |
| **M1 findings** | D32–D39 | what building the storage engine forced, four of which corrected the specification |
| **M2 decisions** | D40–D51 | settled before any data-plane code, per the two-pass rule below |
| **M2 findings** | D52–D58 | what building the data plane forced, each settled in its own pass before the code it governs |

Earlier decisions carry **amendments pointing forward** rather than being silently
rewritten — D11, D18, D20 and D38 each gained one during M2's decision pass, and D28
gained one when the transport made its per-connection figure obsolete. The reasoning that
turned out to be wrong is more useful than a clean record.

## Working rules

1. **No implementation while a decision is open.** Decisions land in `07-decisions.md`
   first, code second. A design question is never settled inside an implementation
   diff.
2. **Constants live in one place.** Every limit, size and interval is defined in
   `01-product.md` (user-visible), `04-storage.md` (storage-internal) or
   `05-architecture.md` (process model and transport). Other docs reference, never
   restate. In code the mirrors are `src/storage/config.zig` and `src/server/config.zig`;
   nothing else may hardcode a limit.
3. **Vocabulary is enforced.** See `00-vision.md`. The words "key" and "value" do not
   appear in code identifiers, endpoints, error messages, docs or UI copy.
